//// The controller benchmark's pure core: settings, the admission schedule,
//// per-action timing arithmetic and the JSON rows. Nothing here performs I/O
//// or reads a clock, so the statistics a sample reports are a function of
//// the timestamps and counters the effectful driver in `gantry/bench`
//// collected.
////
//// ## Flow
////
//// `parse` turns environment lookups into validated `Settings`. `due` places
//// each admission on an open-loop schedule, and `repository` interleaves
//// admissions across the registered repositories. After a phase, the driver
//// hands its `Window` to `row`, which derives throughput, latency quantiles,
//// CPU and the per-action dispatch measures from `Timing` records.
////
//// ## Invariants
////
//// | Input | Preserved property |
//// | --- | --- |
//// | `Settings` | Every count is positive and bounded, and voters are 1 or 3. |
//// | `Timing` | Times share one monotonic microsecond base. |
//// | `Traffic` | Counts only grow, so a phase reports `difference(after, before)`. |

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// Validated benchmark knobs. A zero `rate` selects the original closed-loop
/// phases, in which every admission completes before the drain begins.
pub type Settings {
  Settings(
    /// Admitted actions per sample.
    runs: Int,
    /// Concurrent protocol clients, which are the drain's slots.
    workers: Int,
    /// Empty polls after the drain.
    polls: Int,
    /// Controller voters, either one or three.
    voters: Int,
    /// The first voter's HTTP port.
    port: Int,
    /// BEAM schedulers per voter.
    schedulers: Int,
    /// Registered repositories, each with a private Git remote.
    repositories: Int,
    /// Offered admissions per second, or zero for closed-loop admission.
    rate: Int,
    /// Sleep added to the shell action, in milliseconds.
    sleep_ms: Int,
    /// A slot's pause after an empty claim during the drain, in milliseconds.
    poll_ms: Int,
    /// Bound on open-loop admissions in flight.
    inflight: Int,
    /// Retries after an explicit CAS contention reply. The original driver
    /// allowed four.
    retries: Int,
    /// The per-request HTTP deadline, in milliseconds.
    timeout_ms: Int,
    /// Finished runs each voter keeps, which `[retention]` calls `keep_runs`.
    retained: Int,
  )
}

/// Read and bound every setting from an environment lookup.
///
/// ## Examples
///
/// ```gleam
/// assert load.parse(fn(_) { Error(Nil) }) |> result.is_ok
/// ```
pub fn parse(
  lookup: fn(String) -> Result(String, Nil),
) -> Result(Settings, String) {
  let setting = fn(name, fallback, minimum, maximum) {
    let raw =
      lookup(name) |> result.lazy_unwrap(fn() { int.to_string(fallback) })

    // Reject unparsable and out-of-range values with the bound in the message.
    case int.parse(raw) {
      Ok(value) if value >= minimum && value <= maximum -> Ok(value)
      Ok(_) | Error(Nil) ->
        Error(
          name
          <> " must be an integer from "
          <> int.to_string(minimum)
          <> " to "
          <> int.to_string(maximum),
        )
    }
  }
  use runs <- result.try(setting("GANTRY_BENCH_RUNS", 32, 1, 20_000))
  use workers <- result.try(setting("GANTRY_BENCH_WORKERS", 4, 1, 128))
  use polls <- result.try(setting("GANTRY_BENCH_POLLS", 120, 1, 10_000))
  use voters <- result.try(setting("GANTRY_BENCH_VOTERS", 1, 1, 3))
  use port <- result.try(setting("GANTRY_BENCH_PORT", 18_972, 1, 65_533))
  use schedulers <- result.try(setting("GANTRY_BENCH_SCHEDULERS", 2, 1, 32))
  use repositories <- result.try(setting("GANTRY_BENCH_REPOS", 1, 1, 1000))
  use rate <- result.try(setting("GANTRY_BENCH_RATE", 0, 0, 10_000))
  use sleep_ms <- result.try(setting("GANTRY_BENCH_SLEEP_MS", 0, 0, 999))
  use poll_ms <- result.try(setting("GANTRY_BENCH_POLL_MS", 10, 1, 5000))
  use inflight <- result.try(setting("GANTRY_BENCH_INFLIGHT", 256, 1, 4096))
  use retries <- result.try(setting("GANTRY_BENCH_RETRIES", 4, 0, 1000))
  use timeout_ms <- result.try(setting(
    "GANTRY_BENCH_TIMEOUT_MS",
    30_000,
    1000,
    600_000,
  ))

  use retained <- result.try(setting("GANTRY_BENCH_RETAINED", 200, 1, 1000))

  // Raft needs a majority, and the driver supports the two documented sizes.
  case voters {
    1 | 3 ->
      Ok(Settings(
        runs:,
        workers:,
        polls:,
        voters:,
        port:,
        schedulers:,
        repositories:,
        rate:,
        sleep_ms:,
        poll_ms:,
        inflight:,
        retries:,
        timeout_ms:,
        retained:,
      ))
    _ -> Error("use one or three voters")
  }
}

/// Milliseconds to wait before retry `attempt` after a contention reply:
/// the original driver's doubling from one, capped at 64 for long budgets.
///
/// ## Examples
///
/// ```gleam
/// assert load.backoff(3) == 8
/// ```
pub fn backoff(attempt: Int) -> Int {
  int.bitwise_shift_left(1, int.min(attempt, 6))
}

/// The route name that contention is counted under: `/v1/claims` is `claims`.
///
/// ## Examples
///
/// ```gleam
/// assert load.route("/v1/blobs/abc") == "blobs"
/// ```
pub fn route(path: String) -> String {
  case string.split(path, "/") {
    ["", "v1", name, ..] -> name
    _ -> path
  }
}

/// The integers from zero up to `count`, exclusive.
///
/// ## Examples
///
/// ```gleam
/// assert load.indices(3) == [0, 1, 2]
/// ```
pub fn indices(count: Int) -> List(Int) {
  list.repeat(Nil, int.max(count, 0)) |> list.index_map(fn(_, index) { index })
}

/// Microseconds after the admission start at which admission `index` is due.
/// Closed-loop admission is always due, so its clients pace themselves.
///
/// ## Examples
///
/// ```gleam
/// assert load.due(3, 100) == 30_000
/// ```
pub fn due(index: Int, rate: Int) -> Int {
  case rate {
    0 -> 0
    _ -> index * 1_000_000 / rate
  }
}

/// The repository that admission `index` targets. Consecutive admissions
/// visit every repository before any repository repeats.
///
/// ## Examples
///
/// ```gleam
/// assert load.repository(101, 100) == 1
/// ```
pub fn repository(index: Int, repositories: Int) -> Int {
  index % repositories
}

/// The queue name of repository `index`.
///
/// ## Examples
///
/// ```gleam
/// assert load.repository_name(7) == "fixture/project-007"
/// ```
pub fn repository_name(index: Int) -> String {
  "fixture/project-" <> string.pad_start(int.to_string(index), 3, "0")
}

/// The shell script that every benchmark action runs. A positive sleep comes
/// first so the output and log bytes do not depend on it.
///
/// ## Examples
///
/// ```gleam
/// assert load.script(50) == "sleep 0.050; printf '%s\\n' 'fixture output' > report.txt; printf '%s\\n' 'fixture log'"
/// ```
pub fn script(sleep_ms: Int) -> String {
  let body =
    "printf '%s\\n' 'fixture output' > report.txt; printf '%s\\n' 'fixture log'"

  // Without a sleep the script is byte-identical to the original fixture.
  case sleep_ms {
    0 -> body
    _ ->
      "sleep 0."
      <> string.pad_start(int.to_string(sleep_ms), 3, "0")
      <> "; "
      <> body
  }
}

/// When one action became ready, was leased and was acknowledged.
pub type Timing {
  Timing(
    /// Admission acknowledgement, or the drain start if that came later.
    ready: Int,
    /// The worker received its lease.
    dispatch: Int,
    /// The controller acknowledged the result.
    finish: Int,
  )
}

/// One response as the traffic counters see it.
pub type Reply {
  /// The explicit CAS retry-budget reply, a 503 on the named route.
  Contended(route: String)

  /// Any other response.
  Answered(status: Int)
}

/// Response counts by HTTP status, with explicit CAS contention replies
/// also counted by route.
pub type Traffic {
  Traffic(contention: Dict(String, Int), statuses: Dict(Int, Int))
}

/// No responses observed.
///
/// ## Examples
///
/// ```gleam
/// assert load.no_traffic().statuses == dict.new()
/// ```
pub fn no_traffic() -> Traffic {
  Traffic(dict.new(), dict.new())
}

/// Count one response.
///
/// ## Examples
///
/// ```gleam
/// assert load.contended(load.observe(load.no_traffic(), load.Contended("claims"))) == 1
/// ```
pub fn observe(traffic: Traffic, reply: Reply) -> Traffic {
  // A contention reply is a 503 too, so the status table stays complete.
  case reply {
    Contended(route) ->
      Traffic(
        increment(traffic.contention, route),
        increment(traffic.statuses, 503),
      )
    Answered(status) ->
      Traffic(traffic.contention, increment(traffic.statuses, status))
  }
}

fn increment(counts: Dict(key, Int), key: key) -> Dict(key, Int) {
  dict.upsert(counts, key, fn(count) { option.unwrap(count, 0) + 1 })
}

/// Total contention replies across routes.
///
/// ## Examples
///
/// ```gleam
/// assert load.contended(load.no_traffic()) == 0
/// ```
pub fn contended(traffic: Traffic) -> Int {
  dict.fold(traffic.contention, 0, fn(total, _, count) { total + count })
}

/// The responses observed between two cumulative readings.
///
/// ## Examples
///
/// ```gleam
/// assert load.difference(load.no_traffic(), load.no_traffic()) == load.no_traffic()
/// ```
pub fn difference(after: Traffic, before: Traffic) -> Traffic {
  Traffic(
    subtract(after.contention, before.contention),
    subtract(after.statuses, before.statuses),
  )
}

fn subtract(after: Dict(key, Int), before: Dict(key, Int)) -> Dict(key, Int) {
  dict.map_values(after, fn(key, count) {
    count - result.unwrap(dict.get(before, key), 0)
  })
  |> dict.filter(fn(_, count) { count > 0 })
}

/// Cumulative BEAM CPU ticks and current resident memory across voters.
pub type Usage {
  Usage(ticks: Int, rss_kib: Int)
}

/// Read user plus system ticks from a `/proc/PID/stat` line. The command
/// name may contain spaces, so fields are counted after its closing paren.
///
/// ## Examples
///
/// ```gleam
/// assert load.stat_ticks("1 (beam smp) S 0 0 0 0 0 0 0 0 0 0 7 5 0") == Ok(12)
/// ```
pub fn stat_ticks(stat: String) -> Result(Int, Nil) {
  use #(_, fields) <- result.try(last_split(stat, ") "))
  let fields = string.split(fields, " ")
  use user <- result.try(list.drop(fields, 11) |> list.first)
  use system <- result.try(list.drop(fields, 12) |> list.first)
  use user <- result.try(int.parse(user))
  use system <- result.try(int.parse(system))
  Ok(user + system)
}

/// Split at the last occurrence of `separator`.
fn last_split(
  text: String,
  separator: String,
) -> Result(#(String, String), Nil) {
  use #(tail, head) <- result.try(string.split_once(
    string.reverse(text),
    string.reverse(separator),
  ))
  Ok(#(string.reverse(head), string.reverse(tail)))
}

/// Read the executable name and resident memory from `/proc/PID/status`.
///
/// ## Examples
///
/// ```gleam
/// assert load.status_memory("Name:\tbeam.smp\nVmRSS:\t  42 kB\n") == Ok(#("beam.smp", 42))
/// ```
pub fn status_memory(status: String) -> Result(#(String, Int), Nil) {
  let fields =
    string.split(status, "\n")
    |> list.filter_map(fn(line) {
      use #(key, value) <- result.try(string.split_once(line, ":"))
      Ok(#(key, string.trim(value)))
    })
  use name <- result.try(list.key_find(fields, "Name"))
  use rss <- result.try(list.key_find(fields, "VmRSS"))
  use rss <- result.try(int.parse(string.replace(rss, " kB", "")))
  Ok(#(name, rss))
}

/// Everything one phase measured.
pub type Window {
  Window(
    /// The phase name printed in the row.
    id: String,
    /// Monotonic microseconds spanned by the phase.
    wall_us: Int,
    /// Individual operation latencies in microseconds.
    latencies: List(Int),
    /// Voter usage when the phase began and ended.
    before: Usage,
    after: Usage,
    /// The highest sampled resident memory.
    peak_rss_kib: Int,
    /// Responses observed during the phase.
    traffic: Traffic,
    /// Per-action timestamps, present only for a drain.
    timings: List(Timing),
    /// Additional fields that only this phase reports.
    extra: List(#(String, json.Json)),
  )
}

/// Nearest-rank quantile of an ascending list, in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// assert load.quantile([1000, 2000, 3000, 4000], 0.5) == 2.0
/// ```
pub fn quantile(sorted: List(Int), fraction: Float) -> Float {
  let count = list.length(sorted)
  let rank = float.ceiling(int.to_float(count) *. fraction) |> float.round

  // An empty list has no quantile and reports zero.
  case list.drop(sorted, int.max(rank - 1, 0)) |> list.first {
    Ok(value) -> milliseconds(value)
    Error(Nil) -> 0.0
  }
}

/// The share of slot time spent between lease and acknowledgement, over the
/// span from the first ready action to the last acknowledgement.
///
/// ## Examples
///
/// ```gleam
/// assert load.utilization([load.Timing(0, 0, 10)], 2) == 0.5
/// ```
pub fn utilization(timings: List(Timing), slots: Int) -> Float {
  let busy =
    list.fold(timings, 0, fn(total, timing) {
      total + timing.finish - timing.dispatch
    })
  let span = makespan(timings)

  // No span means no capacity to divide by.
  case span * slots {
    0 -> 0.0
    capacity -> int.to_float(busy) /. int.to_float(capacity)
  }
}

/// Microseconds from the first ready action to the last acknowledgement.
///
/// ## Examples
///
/// ```gleam
/// assert load.makespan([load.Timing(5, 6, 9), load.Timing(2, 7, 8)]) == 7
/// ```
pub fn makespan(timings: List(Timing)) -> Int {
  let first =
    list.map(timings, fn(timing) { timing.ready }) |> list.reduce(int.min)
  let last =
    list.map(timings, fn(timing) { timing.finish }) |> list.reduce(int.max)

  // An empty drain has no span.
  case first, last {
    Ok(first), Ok(last) -> last - first
    Error(Nil), _ | _, Error(Nil) -> 0
  }
}

/// Render one phase as the JSON row the original Node driver printed, plus
/// the multi-repository and dispatch fields.
///
/// ## Examples
///
/// ```gleam
/// // load.row(settings, window, 100) |> json.to_string
/// ```
pub fn row(settings: Settings, window: Window, clock_ticks: Int) -> json.Json {
  let count = list.length(window.latencies)
  let sorted = list.sort(window.latencies, int.compare)
  let wall_ms = milliseconds(window.wall_us)
  let cpu_ms =
    int.to_float({ window.after.ticks - window.before.ticks } * 1000)
    /. int.to_float(clock_ticks)
  let ready =
    list.map(window.timings, fn(timing) { timing.dispatch - timing.ready })
    |> list.sort(int.compare)
  let statuses =
    dict.to_list(window.traffic.statuses)
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.map(fn(pair) { #(int.to_string(pair.0), json.int(pair.1)) })

  let routes =
    dict.to_list(window.traffic.contention)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(pair) { #(pair.0, json.int(pair.1)) })

  let base = [
    #("id", json.string(window.id)),
    #("parallel", json.int(settings.workers)),
    #("voters", json.int(settings.voters)),
    #("schedulers", json.int(settings.schedulers)),
    #("runs", json.int(settings.runs)),
    #("repos", json.int(settings.repositories)),
    #("rate", json.int(settings.rate)),
    #("sleepMs", json.int(settings.sleep_ms)),
    #("count", json.int(count)),
    #("wallMs", json.float(wall_ms)),
    #("throughput", json.float(ratio(int.to_float(count) *. 1000.0, wall_ms))),
    #("p50Ms", json.float(quantile(sorted, 0.5))),
    #("p95Ms", json.float(quantile(sorted, 0.95))),
    #("p99Ms", json.float(quantile(sorted, 0.99))),
    #("cpuMs", json.float(cpu_ms)),
    #("cpuPercent", json.float(ratio(100.0 *. cpu_ms, wall_ms))),
    #("cpuMsPerOp", json.float(ratio(cpu_ms, int.to_float(count)))),
    #(
      "peakRssKiB",
      json.int(int.max(window.peak_rss_kib, window.after.rss_kib)),
    ),
    #("startRssKiB", json.int(window.before.rss_kib)),
    #("contentionRetries", json.int(contended(window.traffic))),
    #("contentionByRoute", json.object(routes)),
    #("statuses", json.object(statuses)),
  ]

  // Only a drain carries lease timestamps, so only it reports dispatch delay.
  let dispatch = case window.timings {
    [] -> []
    timings -> [
      #("readyP50Ms", json.float(quantile(ready, 0.5))),
      #("readyP95Ms", json.float(quantile(ready, 0.95))),
      #("readyP99Ms", json.float(quantile(ready, 0.99))),
      #("readyMaxMs", json.float(quantile(ready, 1.0))),
      #("makespanMs", json.float(milliseconds(makespan(timings)))),
      #("utilization", json.float(utilization(timings, settings.workers))),
    ]
  }

  json.object(list.flatten([base, dispatch, window.extra]))
}

fn milliseconds(microseconds: Int) -> Float {
  int.to_float(microseconds) /. 1000.0
}

fn ratio(numerator: Float, denominator: Float) -> Float {
  case denominator >. 0.0 {
    True -> numerator /. denominator
    False -> 0.0
  }
}
