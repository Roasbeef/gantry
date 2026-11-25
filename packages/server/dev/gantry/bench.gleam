//// Linux controller load benchmark. It boots isolated voters from an
//// installed launcher and drives them with real worker-protocol traffic:
//// Git enrollment, Khepri/Ra claims, blob staging and result reports.
////
//// ```sh
//// cd packages/server
//// GANTRY_BENCH_CONTROLLER="$(command -v gantryd)" gleam run -m gantry/bench
//// ```
////
//// `docs/controller-load.md` lists the settings. With `GANTRY_BENCH_RATE`
//// unset the phases match the original Node driver: closed-loop enrollment,
//// queue drain, then empty polls. A positive rate admits work open-loop at
//// that many actions per second, interleaved across every repository, while
//// the slots drain it.
////
//// ## Flow
////
//// `main` validates settings and calls `sample`. `sample` builds the Git
//// `fixtures`, writes each voter's `configuration` and starts the voters
//// through `boot`. `phases` runs `closed` (which calls `enroll`, then
//// `slots`) or `concurrent` (both at once), then `idle`, each inside
//// `measure`. `verify` re-reads every run and artifact. `halt` stops the
//// voters on every path, and only a verified sample prints its rows.
////
//// ## Processes
////
//// | Process | Owner | Lifetime |
//// | --- | --- | --- |
//// | `Ledger` actor | `sample` | The whole sample; counts responses and claim tickets. |
//// | `Sampler` actor | `measure` | One phase; samples voter RSS every 25 ms. |
//// | Weft scopes | each phase | One phase; a failed task cancels its siblings. |
//// | Voter BEAM | `boot` | Until `halt` signals it and observes its exit. |
////
//// Claim tickets keep the drain bounded: a slot reserves a ticket before
//// each claim and keeps polling until that claim yields an assignment, so the
//// slots issue exactly `runs` successful claims and then stop.

import envoy
import gantry/bench/load.{
  type Settings, type Timing, type Traffic, type Usage, type Window, Timing,
  Usage, Window,
}
import gantry/blobs
import gantry/config
import gantry/internal/ffi_bench
import gantry/internal/ffi_host
import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import weft
import weft/actor
import weft/poll

const image =
  "alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"

const artifact = "report.txt"

const expected = "fixture output\n"

const expected_log = "fixture log\n"

const contention = "queue contention exceeded retry budget"

/// Everything a sample's phases share once its voters are running.
type Bench {
  Bench(
    settings: Settings,
    root: String,
    agent_token: String,
    worker_token: String,
    revisions: Dict(Int, String),
    pids: List(Int),
    ledger: Subject(Note),
    clock_ticks: Int,
  )
}

/// Run one sample and print its rows, or report why it failed.
///
/// ## Examples
///
/// ```gleam
/// // GANTRY_BENCH_CONTROLLER=/usr/local/bin/gantryd gleam run -m gantry/bench
/// ```
pub fn main() -> Nil {
  let outcome = {
    use settings <- result.try(load.parse(envoy.get))
    use controller <- result.try(
      envoy.get("GANTRY_BENCH_CONTROLLER")
      |> result.replace_error(
        "usage: GANTRY_BENCH_CONTROLLER=PATH gleam run -m gantry/bench",
      ),
    )
    sample(settings, controller)
  }

  // Rows reach stdout only after every durable check passed.
  case outcome {
    Ok(rows) -> list.each(rows, fn(row) { io.println(json.to_string(row)) })
    Error(reason) -> {
      io.println_error("gantry bench: " <> reason)
      ffi_host.exit_failure()
    }
  }
}

// --- Sample lifecycle -------------------------------------------------------

/// Prepare fixtures, boot the voters and run the phases. The voters are
/// stopped on every path once any of them started, and the working tree is
/// removed only after a verified sample.
fn sample(
  settings: Settings,
  controller: String,
) -> Result(List(json.Json), String) {
  use root <- result.try(scratch())
  ffi_bench.widen_http(2 * { settings.workers + settings.inflight })
  use ledger <- result.try(start_ledger(settings.runs))
  use revisions <- result.try(fixtures(root, settings.repositories))
  use clock_ticks <- result.try(clock_ticks())
  let agent_token = secret()
  let worker_token = secret()
  let env = [
    #("GANTRY_TOKEN", agent_token),
    #("GANTRY_WORKER_TOKEN", worker_token),
    #("GANTRY_SUBMIT_TOKEN", secret()),
  ]
  let cookie = secret()

  // The voters outlive any failure below, so `halt` receives whatever started.
  let #(pids, booted) =
    boot(settings, root, controller, env, cookie, worker_token, 0, [])
  let outcome = {
    use Nil <- result.try(booted)
    let bench =
      Bench(
        settings:,
        root:,
        agent_token:,
        worker_token:,
        revisions:,
        pids:,
        ledger:,
        clock_ticks:,
      )
    phases(bench)
  }
  let stopped = halt(pids)

  // A failed or unstoppable sample keeps its logs and data for inspection.
  case outcome, stopped {
    Ok(rows), Ok(Nil) -> {
      let _ = simplifile.delete(root)
      Ok(rows)
    }
    Ok(_), Error(reason) | Error(reason), _ -> {
      io.println_error("Retained benchmark files in " <> root)
      Error(reason)
    }
  }
}

/// Create a fresh working tree under `GANTRY_BENCH_DIR`, or `~/bench-gantry`.
fn scratch() -> Result(String, String) {
  let base =
    envoy.get("GANTRY_BENCH_DIR")
    |> result.lazy_unwrap(fn() {
      result.unwrap(envoy.get("HOME"), "/tmp") <> "/bench-gantry"
    })
  use Nil <- result.try(
    simplifile.create_directory_all(base)
    |> result.map_error(fn(_) { "cannot create " <> base }),
  )
  use output <- result.try(host("mktemp", ["-d", base <> "/sample-XXXXXX"]))
  Ok(string.trim(output))
}

/// Run a host tool and require a zero exit status.
fn host(program: String, arguments: List(String)) -> Result(String, String) {
  use #(status, output) <- result.try(ffi_host.run(
    program,
    arguments,
    [],
    60_000,
  ))

  // A failing tool reports its arguments and combined output.
  case status {
    0 -> Ok(output)
    _ ->
      Error(
        program
        <> " "
        <> string.join(arguments, " ")
        <> " exited "
        <> int.to_string(status)
        <> ": "
        <> output,
      )
  }
}

/// A fresh 192-bit hexadecimal credential.
fn secret() -> String {
  crypto.strong_random_bytes(24) |> bit_array.base16_encode |> string.lowercase
}

/// The kernel's `/proc` tick rate, for converting CPU ticks to milliseconds.
fn clock_ticks() -> Result(Int, String) {
  use output <- result.try(host("getconf", ["CLK_TCK"]))
  int.parse(string.trim(output)) |> result.replace_error("invalid CLK_TCK")
}

/// Push one distinct pinned commit to each repository's private bare remote.
/// Repository zero keeps the original fixture bytes.
fn fixtures(root: String, count: Int) -> Result(Dict(Int, String), String) {
  let fixture = root <> "/fixture"
  use _ <- result.try(
    host("git", ["init", "-q", "--initial-branch=main", fixture]),
  )
  load.indices(count)
  |> list.try_fold(dict.new(), fn(revisions, index) {
    let remote = remote(root, index)

    // Distinct README bytes give each repository its own pinned commit.
    let readme = case index {
      0 -> "Pinned Gantry load fixture\n"
      _ -> "Pinned Gantry load fixture " <> int.to_string(index) <> "\n"
    }

    use _ <- result.try(
      host("git", ["init", "-q", "--bare", "--initial-branch=main", remote]),
    )
    use Nil <- result.try(
      simplifile.write(fixture <> "/README", readme)
      |> result.replace_error("cannot write fixture"),
    )
    use _ <- result.try(host("git", ["-C", fixture, "add", "."]))
    use _ <- result.try(
      host("git", [
        "-C", fixture, "-c", "user.email=fixture@example.invalid", "-c",
        "user.name=Fixture", "commit", "-qm", "fixture",
      ]),
    )
    use _ <- result.try(
      host("git", ["-C", fixture, "push", "-q", remote, "HEAD:refs/heads/main"]),
    )
    use revision <- result.try(
      host("git", ["-C", fixture, "rev-parse", "HEAD"]),
    )
    Ok(dict.insert(revisions, index, string.trim(revision)))
  })
}

/// The private bare remote of repository `index`.
fn remote(root: String, index: Int) -> String {
  root <> "/remote-" <> int.to_string(index) <> ".git"
}

/// Write the voter's configuration with every repository registered.
fn configuration(
  settings: Settings,
  root: String,
  index: Int,
  worker_token: String,
) -> String {
  // The first voter bootstraps the cluster, and later voters join it.
  let seed = case index {
    0 -> ""
    _ -> node_name(0)
  }

  let repositories =
    load.indices(settings.repositories)
    |> list.map(fn(repository) {
      "\n[[repository]]\nname = \""
      <> load.repository_name(repository)
      <> "\"\nlocal_remote = \""
      <> remote(root, repository)
      <> "\"\nbranch = \"main\"\ntarget = \"check\"\npool = \"default\"\nimage = \""
      <> image
      <> "\"\n"
    })
  // Each lane is a registered worker with its own credential.
  let workers =
    load.indices(settings.workers)
    |> list.map(fn(lane) {
      "\n[[worker]]\nid = \"worker-"
      <> int.to_string(lane)
      <> "\"\ntoken_sha256 = \""
      <> config.token_digest(lane_token(worker_token, lane))
      <> "\"\n"
    })
  string.concat([
    "data_dir = \"" <> root <> "/data-" <> int.to_string(index) <> "\"\n",
    "blob_dir = \"" <> root <> "/blobs\"\n",
    "port = " <> int.to_string(settings.port + index) <> "\n",
    "seed = \"" <> seed <> "\"\n",
    ..list.append(repositories, workers)
  ])
}

/// The credential of one worker lane, derived from the sample's secret.
fn lane_token(secret: String, lane: Int) -> String {
  secret <> "-" <> int.to_string(lane)
}

/// The credential a lane presents to the controller.
fn worker_credential(bench: Bench, lane: Int) -> String {
  lane_token(bench.worker_token, lane)
}

/// The distributed Erlang name of voter `index`.
fn node_name(index: Int) -> String {
  "gantry_bench_" <> int.to_string(index) <> "@127.0.0.1"
}

/// Start voters in order, each after its predecessor reports healthy, since
/// a joining voter needs the seed's cluster. The returned pids include every
/// voter that started, whatever the outcome.
fn boot(
  settings: Settings,
  root: String,
  controller: String,
  env: List(#(String, String)),
  cookie: String,
  worker_token: String,
  index: Int,
  started: List(Int),
) -> #(List(Int), Result(Nil, String)) {
  // Each voter starts only after every earlier voter is healthy.
  case index >= settings.voters {
    True -> #(list.reverse(started), Ok(Nil))
    False -> {
      let config = root <> "/node-" <> int.to_string(index) <> ".toml"
      let log = root <> "/node-" <> int.to_string(index) <> ".log"
      let flags =
        "+S "
        <> int.to_string(settings.schedulers)
        <> ":"
        <> int.to_string(settings.schedulers)
        <> " -name "
        <> node_name(index)
        <> " -setcookie "
        <> cookie
      let spawned = {
        use Nil <- result.try(
          simplifile.write(
            config,
            configuration(settings, root, index, worker_token),
          )
          |> result.replace_error("cannot write voter configuration"),
        )

        // The shell detaches the launcher with its own log and prints its pid.
        // The launcher must exec BEAM, so that pid is the voter's VM.
        use #(status, output) <- result.try(ffi_host.run(
          "sh",
          [
            "-c",
            "\"$1\" >\"$2\" 2>&1 </dev/null & echo $!",
            "sh",
            controller,
            log,
          ],
          [#("ERL_FLAGS", flags), #("GANTRY_CONFIG", config), ..env],
          10_000,
        ))

        // The shell's only output is the detached launcher's pid.
        case status, int.parse(string.trim(output)) {
          0, Ok(pid) -> Ok(pid)
          _, _ -> Error("cannot start voter: " <> output)
        }
      }

      // A started voter joins the list before its health check can fail.
      case spawned {
        Error(reason) -> #(list.reverse(started), Error(reason))
        Ok(pid) -> {
          let started = [pid, ..started]

          // An unhealthy voter stops the boot, and `halt` still stops it.
          case healthy(settings, index, pid, log, worker_token) {
            Ok(Nil) ->
              boot(
                settings,
                root,
                controller,
                env,
                cookie,
                worker_token,
                index + 1,
                started,
              )
            Error(reason) -> #(list.reverse(started), Error(reason))
          }
        }
      }
    }
  }
}

/// Wait up to 20 seconds for the voter's quorum-fenced health read.
fn healthy(
  settings: Settings,
  index: Int,
  pid: Int,
  log: String,
  token: String,
) -> Result(Nil, String) {
  let reason = fn(prefix) {
    prefix <> ": " <> result.unwrap(simplifile.read(log), "")
  }
  let outcome =
    poll.until(within: 20_000, every: 100, attempt: fn() {
      // A voter that exited cannot become healthy, so stop waiting at once.
      case
        alive(pid),
        dispatch(settings, index, http.Get, "/health", token, None)
      {
        False, _ -> poll.Fail(reason("voter exited"))
        True, Ok(#(200, _)) -> poll.Done(Nil)
        True, Ok(_) | True, Error(_) -> poll.Retry
      }
    })

  // An expired wait includes the voter's log, as a crash report does.
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(error) -> Error(error)
    poll.Expired -> Error(reason("voter health timed out"))
  }
}

/// Whether a process with this pid still exists.
fn alive(pid: Int) -> Bool {
  simplifile.is_directory("/proc/" <> int.to_string(pid))
  |> result.unwrap(False)
}

/// Signal every voter, then wait for each exit, so a later sample on the
/// same ports cannot race a draining VM.
fn halt(pids: List(Int)) -> Result(Nil, String) {
  let _ = host("kill", list.map(pids, int.to_string))
  list.try_each(pids, fn(pid) {
    // The voter is gone once its `/proc` entry disappears.
    case
      poll.until(within: 30_000, every: 50, attempt: fn() {
        // Keep waiting while the entry exists.
        case alive(pid) {
          True -> poll.Retry
          False -> poll.Done(Nil)
        }
      })
    {
      poll.Answered(Nil) -> Ok(Nil)
      poll.Failed(Nil) | poll.Expired ->
        Error("voter " <> int.to_string(pid) <> " did not exit")
    }
  })
}

// --- Phases -----------------------------------------------------------------

/// Run the timed phases, verify durable evidence, then attach end-of-sample
/// sizes to every row.
fn phases(bench: Bench) -> Result(List(json.Json), String) {
  use _ <- result.try(usage(bench.pids))

  // A rate selects open-loop admission concurrent with the drain.
  use #(windows, serial) <- result.try(case bench.settings.rate {
    0 -> closed(bench)
    _ -> concurrent(bench)
  })

  use idle <- result.try(idle(bench))
  use snapshot <- result.try(verify(bench, serial))
  use data <- result.try(data_bytes(bench))
  let sizes = [
    #("snapshotBytes", json.int(snapshot)),
    #("dataDirBytes", json.int(data)),
  ]
  list.append(windows, [idle])
  |> list.map(fn(window) {
    load.row(
      bench.settings,
      Window(..window, extra: list.append(window.extra, sizes)),
      bench.clock_ticks,
    )
  })
  |> Ok
}

/// Admission acknowledgement for one run.
type Admitted {
  Admitted(index: Int, due: Int, sent: Int, acknowledged: Int)
}

/// One assignment a slot completed.
type Leased {
  Leased(run: String, serial: Int, dispatch: Int, finish: Int)
}

/// The original driver's shape: admit everything, then drain, then poll.
fn closed(bench: Bench) -> Result(#(List(Window), Int), String) {
  use #(admitted, probe) <- result.try(
    measure(bench, fn() { enroll(bench, ffi_bench.now_us()) }),
  )
  let enrollment =
    window(
      "enrollment",
      probe,
      list.map(admitted, fn(entry) { entry.acknowledged - entry.sent }),
      [],
      [],
    )
  use #(#(start, leased), probe) <- result.try(
    measure(bench, fn() {
      let start = ffi_bench.now_us()
      slots(bench) |> result.map(fn(leased) { #(start, leased) })
    }),
  )
  use timings <- result.try(timings(admitted, leased, start))
  let drain =
    window(
      "queue-drain",
      probe,
      list.map(leased, fn(entry) { entry.finish - entry.dispatch }),
      timings,
      [],
    )
  Ok(#([enrollment, drain], max_serial(leased)))
}

/// Admissions or slot results from the shared open-loop scope.
type Lane {
  Admissions(List(Admitted))
  Slot(List(Leased))
}

/// Admit open-loop at the offered rate while the slots drain, in one window.
/// Both rows share the window's CPU and memory measurements.
fn concurrent(bench: Bench) -> Result(#(List(Window), Int), String) {
  let settings = bench.settings
  use #(#(start, lanes), probe) <- result.try(
    measure(bench, fn() {
      let start = ffi_bench.now_us()
      let admit = fn() { enroll(bench, start) |> result.map(Admissions) }
      let workers =
        load.indices(settings.workers)
        |> list.map(fn(lane) {
          fn() { slot(bench, lane, []) |> result.map(Slot) }
        })
      weft.new([admit, ..workers])
      |> weft.limit(settings.workers + 1)
      |> weft.on_failure(weft.CancelSiblings)
      |> weft.start
      |> gather
      |> result.map(fn(lanes) { #(start, lanes) })
    }),
  )

  // The scope returns one admission lane and one lane per slot.
  let admitted =
    list.flat_map(lanes, fn(lane) {
      // Keep only the admission lane's acknowledgements.
      case lane {
        Admissions(admitted) -> admitted
        Slot(_) -> []
      }
    })
  let leased =
    list.flat_map(lanes, fn(lane) {
      // Keep only the slots' leases.
      case lane {
        Admissions(_) -> []
        Slot(leased) -> leased
      }
    })
  use Nil <- result.try(unique(leased, settings.runs))
  use timings <- result.try(timings(admitted, leased, start))

  // Admission spans its last acknowledgement. Lag is how late the driver
  // sent each admission against its schedule.
  let last_ack =
    list.fold(admitted, start, fn(last, entry) {
      int.max(last, entry.acknowledged)
    })
  let lag =
    list.map(admitted, fn(entry) { entry.sent - start - entry.due })
    |> list.sort(int.compare)
  let offered = [#("offeredRate", json.int(settings.rate))]
  let admission =
    window(
      "admission",
      with_wall(probe, last_ack - start),
      list.map(admitted, fn(entry) { entry.acknowledged - entry.sent }),
      [],
      [#("lagP99Ms", json.float(load.quantile(lag, 0.99))), ..offered],
    )
  let drain =
    window(
      "queue-drain",
      with_wall(probe, load.makespan(timings)),
      list.map(leased, fn(entry) { entry.finish - entry.dispatch }),
      timings,
      offered,
    )
  Ok(#([admission, drain], max_serial(leased)))
}

/// Admit every run. With a rate, each admission waits for its due time and
/// at most `inflight` are outstanding. Without one, `workers` clients admit
/// back to back, as in the original driver.
fn enroll(bench: Bench, start: Int) -> Result(List(Admitted), String) {
  let settings = bench.settings

  // Open-loop admissions wait for their due time, so they need more slots.
  let limit = case settings.rate {
    0 -> settings.workers
    _ -> settings.inflight
  }

  load.indices(settings.runs)
  |> list.map(fn(index) { fn() { admit(bench, index, start) } })
  |> weft.new
  |> weft.limit(limit)
  |> weft.on_failure(weft.CancelSiblings)
  |> weft.start
  |> gather
}

/// Admit one uncached ad hoc action on its repository's pinned commit.
fn admit(bench: Bench, index: Int, start: Int) -> Result(Admitted, String) {
  let settings = bench.settings
  let due = load.due(index, settings.rate)
  let wait = start + due - ffi_bench.now_us()

  // Sleep in whole milliseconds, never past the due time.
  case wait > 1000 {
    True -> process.sleep(wait / 1000)
    False -> Nil
  }

  let repository = load.repository(index, settings.repositories)
  let revision = dict.get(bench.revisions, repository) |> result.unwrap("")
  let body =
    json.object([
      #("id", json.string(run_id(index))),
      #("repo", json.string(load.repository_name(repository))),
      #("revision", json.string(revision)),
      #("target", json.string("check")),
      #("action", graph.encode_action(action(settings))),
    ])
  let sent = ffi_bench.now_us()
  use run <- result.try(post(
    bench,
    index % settings.voters,
    "/v1/runs",
    bench.agent_token,
    body,
    protocol.run_decoder(),
  ))
  let acknowledged = ffi_bench.now_us()

  // The admitted run must echo this request with its single action.
  case run {
    Some(run) if run.revision == revision ->
      case run.id == run_id(index), run.work {
        True, [_] -> Ok(Admitted(index:, due:, sent:, acknowledged:))
        _, _ -> Error("unexpected admission for " <> run_id(index))
      }
    Some(_) | None -> Error("unexpected admission for " <> run_id(index))
  }
}

/// The run ID of admission `index`.
fn run_id(index: Int) -> String {
  "build-" <> int.to_string(index)
}

/// The ad hoc action every run admits: the shell fixture, one declared
/// output, no inputs and a ten-second timeout.
fn action(settings: Settings) -> graph.Action {
  graph.Action(
    name: "short",
    argv: ["sh", "-ec", load.script(settings.sleep_ms)],
    inputs: [],
    outputs: [artifact],
    dependencies: [],
    after: [],
    timeout: 10,
  )
}

/// Run every slot until the claim tickets are spent.
fn slots(bench: Bench) -> Result(List(Leased), String) {
  let settings = bench.settings
  use leased <- result.try(
    load.indices(settings.workers)
    |> list.map(fn(lane) { fn() { slot(bench, lane, []) } })
    |> weft.new
    |> weft.limit(settings.workers)
    |> weft.on_failure(weft.CancelSiblings)
    |> weft.start
    |> gather,
  )
  let leased = list.flatten(leased)
  use Nil <- result.try(unique(leased, settings.runs))
  Ok(leased)
}

/// Reserve a claim ticket, then poll until it yields an assignment.
fn slot(
  bench: Bench,
  lane: Int,
  done: List(Leased),
) -> Result(List(Leased), String) {
  // A spent ticket supply means every admitted run has a claim.
  case actor.call(bench.ledger, waiting: 5000, sending: Reserve) {
    Spent -> Ok(done)
    Granted -> {
      use leased <- result.try(claim(bench, lane))
      slot(bench, lane, [leased, ..done])
    }
  }
}

/// Claim, execute and report one action, re-polling after empty claims.
fn claim(bench: Bench, lane: Int) -> Result(Leased, String) {
  let worker = "worker-" <> int.to_string(lane)
  let node = lane % bench.settings.voters
  let body =
    json.object([
      #("worker", json.string(worker)),
      #("pool", json.string("default")),
    ])
  use offer <- result.try(post(
    bench,
    node,
    "/v1/claims",
    worker_credential(bench, lane),
    body,
    protocol.assignment_decoder(),
  ))
  let dispatch = ffi_bench.now_us()

  // An empty claim keeps the ticket and polls again after the pause.
  case offer {
    None -> {
      process.sleep(bench.settings.poll_ms)
      claim(bench, lane)
    }
    Some(offer) -> {
      use Nil <- result.try(require(
        queue.lease_worker(offer.lease) == worker
          && offer.task.action.argv == action(bench.settings).argv,
        "assignment does not match the admitted action",
      ))
      use Nil <- result.try(execute(bench, node, lane, worker, offer))
      Ok(Leased(
        run: offer.run,
        serial: queue.lease_serial(offer.lease),
        dispatch:,
        finish: ffi_bench.now_us(),
      ))
    }
  }
}

/// Fetch the source, run the shell fixture, stage its bytes and report.
fn execute(
  bench: Bench,
  node: Int,
  lane: Int,
  worker: String,
  offer: queue.Assignment,
) -> Result(Nil, String) {
  let directory = bench.root <> "/work-" <> int.to_string(lane)
  use source <- result.try(get(
    bench,
    node,
    "/v1/blobs/" <> offer.task.source,
    worker_credential(bench, lane),
  ))
  use Nil <- result.try(require(
    blobs.digest(source) == offer.task.source,
    "source archive digest mismatch",
  ))
  use Nil <- result.try(
    simplifile.create_directory_all(directory)
    |> result.replace_error("cannot create work directory"),
  )

  // The wrapper enters the slot's directory and execs the leased argv.
  use #(status, log) <- result.try(ffi_host.run(
    "sh",
    [
      "-c",
      "cd \"$1\" && shift && exec \"$@\"",
      "sh",
      directory,
      ..offer.task.action.argv
    ],
    [],
    15_000,
  ))
  use output <- result.try(
    simplifile.read_bits(directory <> "/" <> artifact)
    |> result.replace_error("action did not write its output"),
  )
  use Nil <- result.try(require(
    status == 0
      && log == expected_log
      && output == bit_array.from_string(expected),
    "unexpected action output",
  ))
  use output <- result.try(stage(bench, node, lane, output))
  use log <- result.try(stage(bench, node, lane, bit_array.from_string(log)))
  let report =
    json.object([
      #("run", json.string(offer.run)),
      #("action", json.string(offer.task.action.name)),
      #("worker", json.string(worker)),
      #("serial", json.int(queue.lease_serial(offer.lease))),
      #(
        "completion",
        protocol.encode_completion(queue.Succeeded(
          [queue.Artifact(artifact, output)],
          log,
        )),
      ),
    ])
  use accepted <- result.try(post(
    bench,
    node,
    "/v1/results",
    worker_credential(bench, lane),
    report,
    decode.at(["accepted"], decode.bool),
  ))
  require(accepted == Some(True), "result was not accepted")
}

/// Upload bytes under their digest and return the digest the controller
/// confirmed storing.
fn stage(
  bench: Bench,
  node: Int,
  lane: Int,
  bytes: BitArray,
) -> Result(String, String) {
  let id = blobs.digest(bytes)
  use #(_, reply) <- result.try(exchange(
    bench,
    node,
    http.Put,
    "/v1/blobs/" <> id,
    worker_credential(bench, lane),
    Some(#("application/octet-stream", bytes)),
  ))
  use saved <- result.try(decoded(reply, decode.at(["digest"], decode.string)))
  require(saved == id, "blob digest mismatch") |> result.replace(id)
}

/// Poll with nothing left to claim. Every reply must be empty.
fn idle(bench: Bench) -> Result(Window, String) {
  let settings = bench.settings
  use #(latencies, probe) <- result.try(
    measure(bench, fn() {
      load.indices(settings.polls)
      |> list.map(fn(index) {
        fn() {
          let lane = index % settings.workers
          let body =
            json.object([
              #("worker", json.string("worker-" <> int.to_string(lane))),
              #("pool", json.string("default")),
            ])
          let sent = ffi_bench.now_us()
          use offer <- result.try(post(
            bench,
            lane % settings.voters,
            "/v1/claims",
            worker_credential(bench, lane),
            body,
            protocol.assignment_decoder(),
          ))
          let elapsed = ffi_bench.now_us() - sent

          // Every run has passed, so any assignment is a queue defect.
          case offer {
            None -> Ok(elapsed)
            Some(_) -> Error("an empty poll received work")
          }
        }
      })
      |> weft.new
      |> weft.limit(settings.workers)
      |> weft.on_failure(weft.CancelSiblings)
      |> weft.start
      |> gather
    }),
  )
  Ok(window("empty-polls", probe, latencies, [], []))
}

/// Join leases to admissions. An action is ready at its acknowledgement, or
/// at the drain start when it was admitted before the drain began.
fn timings(
  admitted: List(Admitted),
  leased: List(Leased),
  start: Int,
) -> Result(List(Timing), String) {
  let ready =
    list.map(admitted, fn(entry) {
      #(run_id(entry.index), int.max(entry.acknowledged, start))
    })
    |> dict.from_list

  list.try_map(leased, fn(entry) {
    dict.get(ready, entry.run)
    |> result.map_error(fn(_) { "lease for an unadmitted run " <> entry.run })
    |> result.map(fn(ready) { Timing(ready, entry.dispatch, entry.finish) })
  })
}

/// Require exactly one lease per admitted run.
fn unique(leased: List(Leased), runs: Int) -> Result(Nil, String) {
  let ids = list.map(leased, fn(entry) { entry.run })
  require(
    list.length(ids) == runs && list.length(list.unique(ids)) == runs,
    "duplicate or missing claims",
  )
}

/// The newest lease serial, which is the queue state's serial at the end.
fn max_serial(leased: List(Leased)) -> Int {
  list.fold(leased, 0, fn(serial, entry) { int.max(serial, entry.serial) })
}

/// Re-read every stored run, proof and artifact independently of the timed
/// replies. Returns the size of the queue snapshot those runs encode to.
fn verify(bench: Bench, serial: Int) -> Result(Int, String) {
  let settings = bench.settings
  let output = blobs.digest(bit_array.from_string(expected))
  let log = blobs.digest(bit_array.from_string(expected_log))
  use runs <- result.try(
    load.indices(settings.runs)
    |> list.try_map(fn(index) {
      use bytes <- result.try(get(
        bench,
        index % settings.voters,
        "/v1/runs/" <> run_id(index),
        bench.agent_token,
      ))
      use run <- result.try(decoded(bytes, protocol.run_decoder()))

      // A passed run must hold exactly the fixture's output and log digests.
      let held = case queue.phase(run), run.work {
        queue.PhasePassed, [queue.Work(_, queue.Passed(proof))] ->
          queue.proof_files(proof) == [queue.Artifact(artifact, output)]
          && queue.proof_log(proof) == log
        _, _ -> False
      }
      case held {
        True -> Ok(run)
        False -> Error("run " <> run_id(index) <> " lacks its durable proof")
      }
    }),
  )
  use bytes <- result.try(get(
    bench,
    0,
    "/v1/blobs/" <> output,
    bench.agent_token,
  ))
  use Nil <- result.try(require(
    bytes == bit_array.from_string(expected),
    "stored artifact bytes differ",
  ))

  // The store persists exactly this encoding, so its size is the snapshot's.
  queue.State(serial, runs, [])
  |> protocol.encode_state
  |> json.to_string
  |> string.byte_size
  |> Ok
}

/// Total bytes in the voters' data directories, which hold Ra's WAL,
/// segments and snapshots.
fn data_bytes(bench: Bench) -> Result(Int, String) {
  load.indices(bench.settings.voters)
  |> list.try_fold(0, fn(total, index) {
    use output <- result.try(
      host("du", ["-sb", bench.root <> "/data-" <> int.to_string(index)]),
    )

    // `du -sb` prints the byte count before a tab.
    case string.split(output, "\t") {
      [size, ..] ->
        int.parse(size)
        |> result.map(fn(size) { total + size })
        |> result.replace_error("unexpected du output")
      [] -> Error("unexpected du output")
    }
  })
}

// --- Measurement ------------------------------------------------------------

/// Usage, memory and traffic around one phase.
type Probe {
  Probe(
    wall_us: Int,
    before: Usage,
    after: Usage,
    peak_rss_kib: Int,
    traffic: Traffic,
  )
}

/// The same measurements over a sub-span of the probed window.
fn with_wall(probe: Probe, wall_us: Int) -> Probe {
  Probe(..probe, wall_us:)
}

/// Combine a phase's probe with its operations into a reportable window.
fn window(
  id: String,
  probe: Probe,
  latencies: List(Int),
  timings: List(Timing),
  extra: List(#(String, json.Json)),
) -> Window {
  Window(
    id:,
    wall_us: probe.wall_us,
    latencies:,
    before: probe.before,
    after: probe.after,
    peak_rss_kib: probe.peak_rss_kib,
    traffic: probe.traffic,
    timings:,
    extra:,
  )
}

/// Run `work` between two usage readings while a sampler tracks peak RSS.
/// A failed RSS sample fails the phase, as the original driver's did.
fn measure(
  bench: Bench,
  work: fn() -> Result(a, String),
) -> Result(#(a, Probe), String) {
  use before <- result.try(usage(bench.pids))
  let traffic = actor.call(bench.ledger, waiting: 5000, sending: Read)
  use sampler <- result.try(
    actor.new(Sampler(bench.pids, before.rss_kib, None))
    |> actor.periodic(every: 25, sending: Sample)
    |> actor.on_message(sample_memory)
    |> actor.start
    |> result.replace_error("cannot start the RSS sampler"),
  )

  // The sampler stops on `Collect` whether or not the work succeeded.
  let start = ffi_bench.now_us()
  let outcome = work()
  let wall_us = ffi_bench.now_us() - start
  let peak = actor.call(sampler.data, waiting: 5000, sending: Collect)
  use value <- result.try(outcome)
  use peak <- result.try(peak)
  use after <- result.try(usage(bench.pids))
  let ledger = actor.call(bench.ledger, waiting: 5000, sending: Read)
  Ok(#(
    value,
    Probe(
      wall_us:,
      before:,
      after:,
      peak_rss_kib: int.max(peak, after.rss_kib),
      traffic: load.difference(ledger.traffic, traffic.traffic),
    ),
  ))
}

/// Sum CPU ticks and RSS over the voters, requiring each to be a BEAM VM.
fn usage(pids: List(Int)) -> Result(Usage, String) {
  list.try_fold(pids, Usage(0, 0), fn(total, pid) {
    let proc = "/proc/" <> int.to_string(pid)
    use stat <- result.try(
      simplifile.read(proc <> "/stat") |> result.replace_error("voter exited"),
    )
    use status <- result.try(
      simplifile.read(proc <> "/status") |> result.replace_error("voter exited"),
    )
    use ticks <- result.try(
      load.stat_ticks(stat) |> result.replace_error("unreadable /proc stat"),
    )
    use #(name, rss) <- result.try(
      load.status_memory(status) |> result.replace_error("unreadable status"),
    )
    use Nil <- result.try(require(name == "beam.smp", "launcher must exec BEAM"))
    Ok(Usage(total.ticks + ticks, total.rss_kib + rss))
  })
}

/// The RSS sampler's peak, or the first sampling failure.
type Sampler {
  Sampler(pids: List(Int), peak: Int, failure: Option(String))
}

/// Messages to the RSS sampler.
type Probing {
  Sample
  Collect(reply: Subject(Result(Int, String)))
}

/// Keep the highest resident total until the phase collects it.
fn sample_memory(
  state: Sampler,
  message: Probing,
) -> actor.Next(Sampler, Probing) {
  // The first failed reading is kept and reported when the phase collects.
  case message, state.failure {
    Sample, Some(_) -> actor.continue(state)
    Sample, None ->
      // A voter that vanished mid-phase fails the sample.
      case usage(state.pids) {
        Ok(usage) ->
          actor.continue(
            Sampler(..state, peak: int.max(state.peak, usage.rss_kib)),
          )
        Error(reason) -> actor.continue(Sampler(..state, failure: Some(reason)))
      }
    Collect(reply), None -> {
      process.send(reply, Ok(state.peak))
      actor.stop()
    }
    Collect(reply), Some(reason) -> {
      process.send(reply, Error(reason))
      actor.stop()
    }
  }
}

// --- Ledger -----------------------------------------------------------------

/// Response counts and the claim tickets the slots draw from.
type Ledger {
  Ledger(traffic: Traffic, tickets: Int)
}

/// Whether a slot may issue another successful claim.
type Ticket {
  Granted
  Spent
}

/// Messages to the sample's ledger.
type Note {
  Observed(reply: load.Reply)
  Reserve(reply: Subject(Ticket))
  Read(reply: Subject(Ledger))
}

/// Start the sample's ledger with one claim ticket per admitted run.
fn start_ledger(runs: Int) -> Result(Subject(Note), String) {
  actor.new(Ledger(load.no_traffic(), runs))
  |> actor.on_message(fn(ledger: Ledger, note: Note) {
    // The ledger serializes counters and ticket grants for every slot.
    case note {
      Observed(reply) ->
        actor.continue(
          Ledger(..ledger, traffic: load.observe(ledger.traffic, reply)),
        )
      Reserve(reply) ->
        // A grant spends one ticket. The supply never goes below zero.
        case ledger.tickets {
          0 -> {
            process.send(reply, Spent)
            actor.continue(ledger)
          }
          tickets -> {
            process.send(reply, Granted)
            actor.continue(Ledger(..ledger, tickets: tickets - 1))
          }
        }
      Read(reply) -> {
        process.send(reply, ledger)
        actor.continue(ledger)
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("cannot start the ledger")
}

// --- HTTP -------------------------------------------------------------------

/// POST JSON and decode a 200 body, or return `None` for 204.
fn post(
  bench: Bench,
  node: Int,
  path: String,
  token: String,
  body: json.Json,
  decoder: decode.Decoder(a),
) -> Result(Option(a), String) {
  use #(status, reply) <- result.try(exchange(
    bench,
    node,
    http.Post,
    path,
    token,
    Some(#("application/json", bit_array.from_string(json.to_string(body)))),
  ))

  // Claims answer 204 when nothing is ready. Every other route answers JSON.
  case status {
    204 -> Ok(None)
    _ -> decoded(reply, decoder) |> result.map(Some)
  }
}

/// GET a path and return the 2xx body bytes.
fn get(
  bench: Bench,
  node: Int,
  path: String,
  token: String,
) -> Result(BitArray, String) {
  exchange(bench, node, http.Get, path, token, None)
  |> result.map(fn(pair) { pair.1 })
}

/// Decode a UTF-8 JSON reply, quoting the reply when it does not match.
fn decoded(bytes: BitArray, decoder: decode.Decoder(a)) -> Result(a, String) {
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error("non-UTF-8 reply"),
  )
  json.parse(text, decoder)
  |> result.map_error(fn(_) { "unexpected reply: " <> text })
}

/// Send one request and count its status. Only the explicit CAS contention
/// reply proves the operation never committed, so only it is retried, up to
/// `GANTRY_BENCH_RETRIES` times with doubling backoff. Any other non-2xx
/// status fails the operation.
fn exchange(
  bench: Bench,
  node: Int,
  method: http.Method,
  path: String,
  token: String,
  body: Option(#(String, BitArray)),
) -> Result(#(Int, BitArray), String) {
  exchange_loop(bench, node, method, path, token, body, 0)
}

/// One attempt of `exchange`. Every response is counted before the retry
/// decision, so the ledger sees each contention reply exactly once.
fn exchange_loop(
  bench: Bench,
  node: Int,
  method: http.Method,
  path: String,
  token: String,
  body: Option(#(String, BitArray)),
  attempt: Int,
) -> Result(#(Int, BitArray), String) {
  let label = http.method_to_string(method) <> " " <> path
  use #(status, reply) <- result.try(
    dispatch(bench.settings, node, method, path, token, body)
    |> result.map_error(fn(reason) { label <> ": " <> reason }),
  )

  // Only the exact retry-budget body counts as contention.
  let reply_kind = case
    status == 503
    && decoded(reply, decode.at(["error"], decode.string)) == Ok(contention)
  {
    True -> load.Contended(load.route(path))
    False -> load.Answered(status)
  }

  actor.send(bench.ledger, Observed(reply_kind))
  let retry = attempt < bench.settings.retries

  // Retry contention within the budget, accept 2xx and fail the rest.
  case reply_kind, status >= 200 && status < 300 {
    load.Contended(_), _ if retry -> {
      process.sleep(load.backoff(attempt))
      exchange_loop(bench, node, method, path, token, body, attempt + 1)
    }
    _, True -> Ok(#(status, reply))
    _, False ->
      Error(
        label
        <> ": "
        <> int.to_string(status)
        <> " "
        <> result.unwrap(bit_array.to_string(reply), ""),
      )
  }
}

/// One loopback HTTP exchange with the voter at `node`.
fn dispatch(
  settings: Settings,
  node: Int,
  method: http.Method,
  path: String,
  token: String,
  body: Option(#(String, BitArray)),
) -> Result(#(Int, BitArray), String) {
  let base =
    request.new()
    |> request.set_scheme(http.Http)
    |> request.set_host("127.0.0.1")
    |> request.set_port(settings.port + node)
    |> request.set_method(method)
    |> request.set_path(path)
    |> request.set_header("authorization", "Bearer " <> token)
    |> request.set_body(<<>>)

  // A body carries its media type. GET requests send neither.
  let req = case body {
    Some(#(media, bytes)) ->
      base
      |> request.set_header("content-type", media)
      |> request.set_body(bytes)
    None -> base
  }

  httpc.configure()
  |> httpc.timeout(settings.timeout_ms)
  |> httpc.dispatch_bits(req)
  |> result.map(fn(response) { #(response.status, response.body) })
  |> result.map_error(string.inspect)
}

fn require(condition: Bool, reason: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(reason)
  }
}

/// Collect every task's value. A cancelled sibling reports the failure that
/// cancelled it, so a real failure is preferred over a cancellation.
fn gather(outcomes: List(weft.Outcome(a, String))) -> Result(List(a), String) {
  let failures =
    list.filter_map(outcomes, fn(outcome) {
      // Keep the failures and crashes that started any cancellation.
      case outcome {
        weft.Failed(_, reason) -> Ok(reason)
        weft.Crashed(index, reason) ->
          Ok(
            "task "
            <> int.to_string(index)
            <> " crashed: "
            <> string.inspect(reason),
          )
        weft.Completed(_, _)
        | weft.Abandoned(_)
        | weft.NeverStarted(_)
        | weft.DrainProofLost(_, _)
        | weft.CancellationUnconfirmed(_) -> Error(Nil)
      }
    })

  // Without a failure, every outcome must be a completed value.
  case failures {
    [reason, ..] -> Error(reason)
    [] ->
      list.try_map(outcomes, fn(outcome) {
        // A cancellation with no recorded failure still fails the phase.
        case outcome {
          weft.Completed(_, value) -> Ok(value)
          weft.Failed(_, _)
          | weft.Crashed(_, _)
          | weft.Abandoned(_)
          | weft.NeverStarted(_)
          | weft.DrainProofLost(_, _)
          | weft.CancellationUnconfirmed(_) -> Error("task cancelled")
        }
      })
  }
}
