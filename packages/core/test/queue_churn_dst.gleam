//// A counting simulation over the production queue. Two controllers share one
//// linearizable store and one simulated Git remote with two branches. Either
//// controller can crash at any point of the landing sequence and restart from
//// the persisted codec bytes. Both can reconcile the same intent at once.
//// Workers can vanish while holding a lease, restart under the same ID, and
//// deliver late results. A restarted worker may instead report its attempt
//// `Interrupted`, which lapses the lease at once and counts the attempt.
//// Leases lapse and are reassigned under a new serial, so a late result is
//// stale and a poisoned action fails its run. Submissions
//// wait for their lane, are prepared in order as it frees, and a preparation
//// can be refused. The provider can deny a landing. Retention drops finished
//// runs while the proof index keeps reuse working. The fixture shares one
//// recipe across two runs so a proof is reused, and a fault can reject a
//// completion with an oversized reason.
////
//// Violations are counted rather than asserted so a sweep reports numbers.
//// The heal phase restores reliable delivery to live workers and controllers
//// only. A vanished worker never returns, so its lease must expire and be
//// reassigned for the queue to finish.

import gantry_core/chunks
import gantry_core/graph
import gantry_core/image.{type Image}
import gantry_core/protocol
import gantry_core/queue
import gantry_core/sandbox
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import layout_audit as audit

/// The reconciler's view of one observed ref, as in `submit.reconcile`.
type Decision {
  AlreadyLanded
  Advanced
  Denied
  Push
}

/// The controller-local landing program. A crash discards all of it.
type Program {
  Idle
  Holding(intents: List(queue.Intent))
  Decided(intent: queue.Intent, decision: Decision, rest: List(queue.Intent))
  Recording(
    intent: queue.Intent,
    outcome: Result(Nil, queue.Block),
    pushed: Bool,
    rest: List(queue.Intent),
  )
  Replying(rest: List(queue.Intent))
}

type Controller {
  Controller(program: Program, restarted: Option(#(Int, Int)))
}

type Worker {
  Worker(pool: String, generation: Int, held: Option(queue.Assignment))
}

type World {
  World(
    durable: queue.State,
    store: Image,
    controllers: List(Controller),
    workers: List(Worker),
    ghosts: List(queue.Assignment),
    vanished: List(String),
    refs: Dict(String, String),
    parents: Dict(String, String),
    mask: Int,
    prepared: List(String),
    expired: List(Int),
    writes: List(#(String, String, String)),
    issued: Dict(Int, #(String, String, String)),
    fresh: Int,
    counts: Dict(String, Int),
    samples: List(#(Int, Int)),
    event: Int,
    clock: Int,
  )
}

/// The final world and its counters for one schedule.
pub opaque type Report {
  Report(world: World)
}

/// Counters whose nonzero value is a safety violation.
pub const safety = [
  "duplicate_admissions", "stale_acceptances", "double_writes",
  "double_resolutions", "untested_writes", "unauthorized_writes",
  "landed_without_write", "codec_mismatches", "nondeterministic",
  "lane_overlaps", "waiting_built", "out_of_order_preparations",
  "pending_in_failed", "uncapped_reasons", "retention_dropped_live",
  "retention_lost_proofs", "layout_mismatches", "interrupt_miscounted",
]

/// Counters that report liveness after the heal phase.
pub const liveness = [
  "stuck_active_seeds", "stuck_active_vanished_seeds",
  "stuck_active_other_seeds", "stuck_landing_seeds", "stuck_runs",
  "nonterminal_runs", "nonterminal_lanes", "heal_live_lapses",
]

/// Counters that show each fault class was exercised.
pub const coverage = [
  "restarts", "crash_idle", "crash_after_landings_before_push",
  "crash_after_observe_before_record", "crash_after_push_before_record",
  "crash_after_record_before_reply", "concurrent_reconciles",
  "push_lease_failures", "external_advances", "force_pushes",
  "vanished_with_lease", "replayed_claims", "late_accepted", "late_rejected",
  "cache_hits", "rejected_runs", "landed_runs", "blocked_runs",
  "recovery_censored", "expiries", "reassignments", "expired_results_rejected",
  "returned_after_expiry", "poisoned_runs", "poison_drops", "skipped_actions",
  "prepared_groups", "preparation_refusals", "policy_denials",
  "retained_dropped", "oversized_reasons", "interrupted_reports",
  "interrupted_at_bound", "staging_refusals",
]

/// Expand a seed with the same Park–Miller stream as `queue_dst`.
///
/// ## Examples
///
/// ```gleam
/// // queue_churn_dst.run_seed(73, 128)
/// ```
pub fn run_seed(seed: Int, events: Int) -> Report {
  let #(mask, ops) = schedule(seed, events)
  run(mask, ops)
}

/// Run explicit operation bytes under a fault mask, then heal.
///
/// ## Examples
///
/// ```gleam
/// // queue_churn_dst.run(127, [0, 3, 7, 10])
/// ```
pub fn run(mask: Int, ops: List(Int)) -> Report {
  let world =
    list.fold(ops, World(..start(), mask:), fn(world, op) {
      let world = tick(world, mask, op)
      World(
        ..world,
        event: world.event + 1,
        clock: world.clock + 5 + op * 13 % 41,
      )
    })
  // Live workers must finish under healed delivery without any expiry. Only
  // then does time pass, so vanished workers' leases can lapse.
  let world = heal(world, 0, 60, Deliver)
  let world = bump_by(world, "heal_live_lapses", live_leases(world))
  Report(classify(heal(world, 0, 60, Expire)))
}

/// What a heal round does once its deliveries are done.
type Heal {
  /// Deliver only. Time does not pass, so no lease can lapse.
  Deliver
  /// Deliver, then let leases lapse so a vanished worker's action moves on.
  Expire
}

/// Count active leases held by workers that have not vanished, leaving out
/// poison actions, which never report and are meant to need expiry.
fn live_leases(world: World) -> Int {
  list.count(active_leases(world.durable), fn(entry) {
    let #(run, _, lease) = entry
    !list.contains(world.vanished, queue.lease_worker(lease))
    && !poisoned(world, run)
  })
}

/// Whether a run's action kills its worker on every attempt in this world.
fn poisoned(world: World, run: String) -> Bool {
  world.mask / 512 % 2 == 1 && { world.mask + denial_key(run) } % 4 == 0
}

/// Read the counters of one report.
pub fn counts(report: Report) -> Dict(String, Int) {
  report.world.counts
}

/// Read the recovery samples of one report as (events, simulated ms) pairs.
pub fn samples(report: Report) -> List(#(Int, Int)) {
  report.world.samples
}

/// Totals, seeds with a nonzero count, the first such seed, and samples.
pub type Sweep {
  Sweep(
    totals: Dict(String, Int),
    seeds: Dict(String, Int),
    first: Dict(String, Int),
    samples: List(#(Int, Int)),
  )
}

/// Run each seed in `[first, first + count)` twice and aggregate the counts.
///
/// ## Examples
///
/// ```gleam
/// // queue_churn_dst.sweep_counts(1, 1000, 128)
/// ```
pub fn sweep_counts(first: Int, count: Int, events: Int) -> Sweep {
  let initial = Sweep(dict.new(), dict.new(), dict.new(), [])
  int.range(first, first + count, initial, fn(acc, seed) {
    let report = run_seed(seed, events)
    let again = run_seed(seed, events)
    let counts = case report == again {
      True -> counts(report)
      False -> add(counts(report), "nondeterministic", 1)
    }
    let names = list.flatten([safety, liveness, coverage])
    let acc =
      list.fold(names, acc, fn(acc, name) {
        case get(counts, name) {
          0 -> acc
          n ->
            Sweep(
              ..acc,
              totals: add(acc.totals, name, n),
              seeds: add(acc.seeds, name, 1),
              first: case dict.has_key(acc.first, name) {
                True -> acc.first
                False -> dict.insert(acc.first, name, seed)
              },
            )
        }
      })
    Sweep(..acc, samples: list.append(samples(report), acc.samples))
  })
}

/// Print the count table and recovery percentiles. Return the safety total.
///
/// ## Examples
///
/// ```gleam
/// // queue_churn_dst.sweep(1, 1000, 128)
/// ```
pub fn sweep(first: Int, count: Int, events: Int) -> Int {
  let result = sweep_counts(first, count, events)
  io.println(
    "seeds "
    <> int.to_string(first)
    <> ".."
    <> int.to_string(first + count - 1)
    <> " events "
    <> int.to_string(events),
  )
  io.println(
    pad("counter", 36) <> pad("total", 10) <> pad("seeds", 8) <> "first_seed",
  )
  list.each(
    [#("safety", safety), #("liveness", liveness), #("coverage", coverage)],
    fn(group) {
      io.println("-- " <> group.0)
      list.each(group.1, fn(name) {
        let first = case dict.get(result.first, name) {
          Ok(seed) -> int.to_string(seed)
          Error(Nil) -> "-"
        }
        io.println(
          pad(name, 36)
          <> pad(int.to_string(get(result.totals, name)), 10)
          <> pad(int.to_string(get(result.seeds, name)), 8)
          <> first,
        )
      })
    },
  )
  let events_sorted =
    list.sort(list.map(result.samples, fn(s) { s.0 }), int.compare)
  let ms_sorted =
    list.sort(list.map(result.samples, fn(s) { s.1 }), int.compare)
  io.println(
    "recovery samples "
    <> int.to_string(list.length(result.samples))
    <> " events p50 "
    <> int.to_string(percentile(events_sorted, 50))
    <> " p95 "
    <> int.to_string(percentile(events_sorted, 95))
    <> " sim_ms p50 "
    <> int.to_string(percentile(ms_sorted, 50))
    <> " p95 "
    <> int.to_string(percentile(ms_sorted, 95)),
  )
  list.fold(safety, 0, fn(total, name) { total + get(result.totals, name) })
}

/// Print the counters for a single seed.
///
/// ## Examples
///
/// ```gleam
/// // queue_churn_dst.describe(73, 128)
/// ```
pub fn describe(seed: Int, events: Int) -> Nil {
  let #(mask, ops) = schedule(seed, events)
  io.println("seed " <> int.to_string(seed) <> " mask " <> int.to_string(mask))
  io.println("ops " <> string.join(list.map(ops, int.to_string), " "))
  let report = run(mask, ops)
  list.each(list.flatten([safety, liveness, coverage]), fn(name) {
    case get(counts(report), name) {
      0 -> Nil
      n -> io.println(name <> " " <> int.to_string(n))
    }
  })
  list.each(report.world.durable.runs, fn(run) {
    io.println(
      run.id
      <> " "
      <> string.inspect(queue.phase(run))
      <> " "
      <> string.inspect(list.map(run.work, fn(w) { w.step })),
    )
  })
}

fn pad(text: String, width: Int) -> String {
  text <> string.repeat(" ", int.max(1, width - string.length(text)))
}

/// Nearest-rank percentile of a sorted list.
fn percentile(sorted: List(Int), p: Int) -> Int {
  let n = list.length(sorted)
  case n {
    0 -> 0
    _ -> {
      let rank = int.max(1, { p * n + 99 } / 100)
      case list.drop(sorted, rank - 1) {
        [value, ..] -> value
        [] -> 0
      }
    }
  }
}

fn schedule(seed: Int, events: Int) -> #(Int, List(Int)) {
  let seed = int.max(1, seed % 2_147_483_647)
  let mask = next_seed(seed)
  let #(_, ops) =
    list.fold(list.repeat(Nil, events), #(mask, []), fn(state, _) {
      let next = next_seed(state.0)
      #(next, [next % 256, ..state.1])
    })
  #(mask % 2048, list.reverse(ops))
}

fn next_seed(seed: Int) -> Int {
  seed * 48_271 % 2_147_483_647
}

fn get(counts: Dict(String, Int), name: String) -> Int {
  case dict.get(counts, name) {
    Ok(n) -> n
    Error(Nil) -> 0
  }
}

fn add(counts: Dict(String, Int), name: String, by: Int) -> Dict(String, Int) {
  dict.upsert(counts, name, fn(prior) {
    case prior {
      Some(n) -> n + by
      None -> by
    }
  })
}

fn bump_by(world: World, name: String, by: Int) -> World {
  World(..world, counts: add(world.counts, name, by))
}

fn bump(world: World, name: String) -> World {
  World(..world, counts: add(world.counts, name, 1))
}

/// Admit waiting groups on `main` and `release` and a build that shares the
/// first group's producer recipe. A group is prepared when its lane frees.
fn start() -> World {
  let specs = [
    #("a", Some("main")),
    #("r", Some("release")),
    #("b", Some("main")),
    #("s", Some("release")),
    #("build-only", None),
    #("c", Some("main")),
  ]
  let #(durable, store, mismatches) =
    list.fold(specs, #(queue.empty(), image.empty(), 0), fn(acc, spec) {
      let #(state, store, bad) = acc
      let #(id, lane) = spec
      let #(revision, submission, work) = case lane {
        None -> #(id, queue.Build, tasks(id))
        Some(branch) -> #("", queue.Waiting(branch, [queue.Member(1, id)]), [])
      }
      let assert Ok(#(next, _)) =
        queue.admit(state, id, "repo", revision, "check", submission, work)
      case
        audit.admit(
          store,
          state,
          id,
          "repo",
          revision,
          "check",
          submission,
          work,
        )
      {
        Ok(stored) -> #(next, stored, bad)
        Error(_) -> #(next, audit.import_state(next), bad + 1)
      }
    })
  World(
    durable:,
    store:,
    controllers: [Controller(Idle, None), Controller(Idle, None)],
    workers: [Worker("build", 0, None), Worker("test", 0, None)],
    ghosts: [],
    vanished: [],
    refs: dict.from_list([#("main", "main-0"), #("release", "rel-0")]),
    parents: dict.new(),
    mask: 0,
    prepared: [],
    expired: [],
    writes: [],
    issued: dict.new(),
    fresh: 0,
    counts: case mismatches {
      0 -> dict.new()
      n -> dict.from_list([#("layout_mismatches", n)])
    },
    samples: [],
    event: 0,
    clock: 0,
  )
}

/// The recipe a run's producer uses decides whether a proof is shared.
fn recipe_of(id: String) -> String {
  case id {
    "a" | "build-only" -> "producer-shared"
    _ -> "producer-" <> id
  }
}

/// The two-action graph of one run.
fn tasks(id: String) -> List(queue.Task) {
  let producer = graph.action("build", ["build"], [], ["out"], [], [], 10)
  let consumer = graph.action("test", ["test"], [], [], ["build"], [], 10)
  [
    queue.whole_task(
      producer,
      id,
      recipe_of(id),
      "build",
      "image",
      sandbox.Strict,
    ),
    queue.whole_task(
      consumer,
      id,
      "consumer-" <> id,
      "test",
      "image",
      sandbox.Strict,
    ),
  ]
}

/// The provider's verdict on a run is fixed, so every controller agrees.
fn denial_key(id: String) -> Int {
  list.fold(string.to_utf_codepoints(id), 0, fn(sum, point) {
    sum + string.utf_codepoint_to_int(point)
  })
}

/// Mask bits: 0 lost claim replies, 1 lost result replies, 2 controller
/// crashes, 3 outside ref writes, 4 vanishing workers, 5 same-ID restarts,
/// half of which report the held attempt `Interrupted`, and late results,
/// 6 rejected completions, 7 refused preparations, 8 provider policy
/// denials, 9 poison actions that never report, 10 inputs the worker refuses
/// to stage (a chunk or manifest that fails its checks). A disabled fault
/// runs the honest op.
fn tick(world: World, mask: Int, op: Int) -> World {
  let k = op / 16 % 2
  let pool = case op / 32 % 2 {
    0 -> "build"
    _ -> "test"
  }
  let lose_result = mask / 2 % 2 == 1
  let crash_on = mask / 4 % 2 == 1
  let outside_on = mask / 8 % 2 == 1
  let vanish_on = mask / 16 % 2 == 1
  let restart_on = mask / 32 % 2 == 1
  let reject_on = mask / 64 % 2 == 1
  let refuse_on = mask / 128 % 2 == 1
  let staging_on = mask / 1024 % 2 == 1

  // The same op byte picks one of the worker's possible refusals.
  let verdict = case op / 64 {
    0 if reject_on -> Planted
    1 if staging_on -> Refused(staging_violation(op / 16))
    _ -> Honest
  }
  case op % 16 {
    0 | 1 -> poll(world, k, pool, False)
    2 -> poll(world, k, pool, mask % 2 == 1)
    3 | 4 -> complete(world, k, pool, False, Honest)
    5 -> complete(world, k, pool, lose_result, Honest)
    6 -> complete(world, k, pool, False, verdict)
    7 | 8 | 9 -> step(world, k)
    10 if crash_on -> crash(world, k)
    10 -> step(world, k)
    11 if outside_on -> outside_write(world, pool, op / 64 % 2 == 0)
    11 -> step(world, k)
    12 if vanish_on -> vanish(world, pool)
    12 -> poll(world, k, pool, False)
    13 if restart_on -> restart_worker(world, k, pool, op / 64 % 2 == 0)
    13 -> poll(world, k, pool, False)
    14 if restart_on || vanish_on -> late(world, k)
    14 -> complete(world, k, pool, False, Honest)
    _ ->
      case op / 64 % 4 {
        1 -> elapse(world, k)
        3 -> retention(world, k)
        _ -> prepare(world, k, refuse_on && op / 4 % 2 == 1)
      }
  }
}

fn controller(world: World, k: Int) -> Controller {
  let assert [c, ..] = list.drop(world.controllers, k)
  c
}

fn set_controller(world: World, k: Int, c: Controller) -> World {
  World(
    ..world,
    controllers: list.index_map(world.controllers, fn(old, i) {
      case i == k {
        True -> c
        False -> old
      }
    }),
  )
}

fn set_program(world: World, k: Int, program: Program) -> World {
  set_controller(world, k, Controller(..controller(world, k), program:))
}

fn worker(world: World, pool: String) -> Worker {
  let assert Ok(w) = list.find(world.workers, fn(w) { w.pool == pool })
  w
}

fn set_worker(world: World, w: Worker) -> World {
  World(
    ..world,
    workers: list.map(world.workers, fn(old) {
      case old.pool == w.pool {
        True -> w
        False -> old
      }
    }),
  )
}

fn worker_id(w: Worker) -> String {
  w.pool <> "-w" <> int.to_string(w.generation)
}

fn active_leases(state: queue.State) -> List(#(String, String, queue.Lease)) {
  list.flat_map(state.runs, fn(run) {
    list.filter_map(run.work, fn(work) {
      case work.step {
        queue.Active(lease) -> Ok(#(run.id, work.task.action.name, lease))
        _ -> Error(Nil)
      }
    })
  })
}

fn current_lease(
  state: queue.State,
  run: String,
  action: String,
) -> Option(queue.Lease) {
  active_leases(state)
  |> list.find(fn(entry) { entry.0 == run && entry.1 == action })
  |> option.from_result
  |> option.map(fn(entry) { entry.2 })
}

/// Commit a proposal through controller `k`. A changed state is a committed
/// transition: check new leases and close any pending recovery sample.
fn commit(world: World, k: Int, op: audit.Op, next: queue.State) -> World {
  let world = shadow(world, op, next)
  case next == world.durable {
    True -> world
    False -> {
      let world = admissions(world, next) |> lapses(next) |> audit(next)
      let c = controller(world, k)
      let world = case c.restarted {
        None -> world
        Some(#(event, clock)) ->
          World(
            ..set_controller(world, k, Controller(..c, restarted: None)),
            samples: [
              #(world.event - event, world.clock - clock),
              ..world.samples
            ],
          )
      }
      World(..world, durable: next)
    }
  }
}

/// Run the operation through the indexed layout on the reference store. The
/// layout must leave the runs, proofs, serial, and index exactly as the whole
/// state transition did. After a difference the store resynchronizes, so one
/// bug counts once.
fn shadow(world: World, op: audit.Op, next: queue.State) -> World {
  case audit.replay(world.store, world.durable, op) {
    Ok(store) -> World(..world, store:)
    Error(detail) -> {
      io.println("LAYOUT MISMATCH " <> detail)
      World(..world, store: audit.import_state(next))
      |> bump("layout_mismatches")
    }
  }
}

/// A new active lease must not replace a live one, reuse a serial, or give a
/// worker a second live lease.
fn admissions(world: World, next: queue.State) -> World {
  let before = active_leases(world.durable)
  let after = active_leases(next)
  list.fold(after, world, fn(world, entry) {
    let #(run, action, lease) = entry
    case list.contains(before, entry) {
      True -> world
      False -> {
        let replaced =
          list.any(before, fn(old) {
            old.0 == run
            && old.1 == action
            && queue.lease_until(old.2) >= world.clock
          })
        let reissued = case dict.get(world.issued, queue.lease_serial(lease)) {
          Ok(identity) -> identity != #(run, action, queue.lease_worker(lease))
          Error(Nil) -> False
        }
        let doubled =
          list.count(after, fn(other) {
            let #(_, _, held) = other
            queue.lease_worker(held) == queue.lease_worker(lease)
          })
          > 1
        let world = case queue.lease_attempt(lease) > 1 {
          True -> bump(world, "reassignments")
          False -> world
        }
        let world = case replaced || reissued || doubled {
          True -> bump(world, "duplicate_admissions")
          False -> world
        }
        World(
          ..world,
          issued: dict.insert(world.issued, queue.lease_serial(lease), #(
            run,
            action,
            queue.lease_worker(lease),
          )),
        )
      }
    }
  })
}

/// A lease that left `Active` for `Pending`, a lease failure or a skip lapsed.
fn lapses(world: World, next: queue.State) -> World {
  list.fold(active_leases(world.durable), world, fn(world, entry) {
    let #(run, action, lease) = entry
    let step = case queue.find(next, run) {
      Ok(found) ->
        list.find(found.work, fn(work) { work.task.action.name == action })
        |> result.map(fn(work) { work.step })
      Error(Nil) -> Error(Nil)
    }
    let lapsed = case step {
      Ok(queue.Pending(_)) | Ok(queue.Skipped) -> True
      Ok(queue.Failed(queue.LeaseExpired(_), _)) -> True
      _ -> False
    }
    let world = case step {
      Ok(queue.Failed(queue.LeaseExpired(_), _)) -> bump(world, "poisoned_runs")
      _ -> world
    }
    case lapsed {
      False -> world
      True ->
        World(..world, expired: [queue.lease_serial(lease), ..world.expired])
        |> bump("expiries")
    }
  })
}

/// Safety audit of a committed state: lanes, graphs, failures and text.
fn audit(world: World, next: queue.State) -> World {
  let runs = next.runs
  let holders =
    list.filter_map(runs, fn(run) {
      case holds_lane(run) {
        Ok(branch) -> Ok(#(run.repo, branch))
        Error(Nil) -> Error(Nil)
      }
    })
  let world = case list.length(list.unique(holders)) == list.length(holders) {
    True -> world
    False -> bump(world, "lane_overlaps")
  }
  list.fold(runs, world, fn(world, run) {
    let flag = fn(world, name, condition) {
      case condition {
        True -> bump(world, name)
        False -> world
      }
    }
    let failed =
      list.any(run.work, fn(work) {
        case work.step {
          queue.Failed(_, _) -> True
          _ -> False
        }
      })
    let pending =
      list.any(run.work, fn(work) {
        case work.step {
          queue.Pending(_) -> True
          _ -> False
        }
      })
    let waiting_built = case run.submission {
      queue.Waiting(_, _) | queue.Unprepared(_, _, _) -> run.work != []
      _ -> False
    }
    let long = fn(text) { string.byte_size(text) > queue.max_detail_bytes }
    let uncapped =
      list.any(run.work, fn(work) {
        case work.step {
          queue.Failed(queue.Reported(detail), _) -> long(detail)
          _ -> False
        }
      })
      || case run.submission {
        queue.Blocked(_, queue.PolicyDenied(detail)) -> long(detail)
        queue.Unprepared(_, _, queue.Unmergeable(detail))
        | queue.Unprepared(_, _, queue.Refused(detail)) -> long(detail)
        _ -> False
      }
    world
    |> flag("pending_in_failed", failed && pending)
    |> flag("waiting_built", waiting_built)
    |> flag("uncapped_reasons", uncapped)
    |> flag("out_of_order_preparations", out_of_order(runs, run))
  })
}

/// A prepared run with an earlier waiting run in its lane skipped the line.
fn out_of_order(runs: List(queue.Run), run: queue.Run) -> Bool {
  case lane_of(run) {
    Error(Nil) -> False
    Ok(branch) ->
      case run.submission {
        queue.Waiting(_, _) -> False
        _ ->
          list.take_while(runs, fn(other) { other.id != run.id })
          |> list.any(fn(other) {
            lane_of(other) == Ok(branch)
            && case other.submission {
              queue.Waiting(_, _) -> True
              _ -> False
            }
          })
      }
  }
}

/// The branch a submission targets.
fn lane_of(run: queue.Run) -> Result(String, Nil) {
  case run.submission {
    queue.Build -> Error(Nil)
    queue.Waiting(branch, _) | queue.Unprepared(branch, _, _) -> Ok(branch)
    queue.Queued(c)
    | queue.Landing(c)
    | queue.Landed(c)
    | queue.Blocked(c, _) -> Ok(queue.candidate_branch(c))
  }
}

/// A queued run with live work or a landing run reserves its branch.
fn holds_lane(run: queue.Run) -> Result(String, Nil) {
  case run.submission {
    queue.Queued(c) ->
      case
        list.any(run.work, fn(work) {
          case work.step {
            queue.Failed(_, _) -> True
            _ -> False
          }
        })
      {
        True -> Error(Nil)
        False -> Ok(queue.candidate_branch(c))
      }
    queue.Landing(c) -> Ok(queue.candidate_branch(c))
    _ -> Error(Nil)
  }
}

/// Prepare one waiting group the core offers, or refuse it as a fault.
fn prepare(world: World, k: Int, refuse: Bool) -> World {
  case queue.preparations(world.durable) {
    [] -> world
    offers -> {
      let offer = case list.drop(offers, world.event % list.length(offers)) {
        [picked, ..] -> picked
        [] -> list.first(offers) |> result.unwrap(offer_placeholder(offers))
      }
      let id = queue.preparation_run(offer)
      let branch = queue.preparation_branch(offer)
      let base = ref(world, branch)
      let outcome = case refuse {
        True -> Error(queue.MemberMoved(1))
        False ->
          Ok(#(
            queue.candidate(branch, base, id, queue.preparation_members(offer)),
            tasks(id),
          ))
      }
      let assert Ok(next) =
        queue.record_preparation(world.durable, offer, outcome)
      let world = case outcome {
        Ok(_) ->
          World(
            ..world,
            parents: dict.insert(world.parents, id, base),
            prepared: [id, ..world.prepared],
          )
          |> bump("prepared_groups")
        Error(_) -> bump(world, "preparation_refusals")
      }
      commit(world, k, audit.Prepare(offer, outcome), next)
    }
  }
}

/// The first offer of a non-empty list, for the total fallback branch.
fn offer_placeholder(offers: List(queue.Preparation)) -> queue.Preparation {
  case offers {
    [first, ..] -> first
    [] -> panic as "offers are never empty here"
  }
}

/// Let time pass and run the controller's expiry tick.
fn elapse(world: World, k: Int) -> World {
  // The jump outlasts the lease slack plus the fixture's action timeout.
  let world = World(..world, clock: world.clock + 1000)
  commit(
    world,
    k,
    audit.Expire(world.clock),
    queue.expire(world.durable, world.clock),
  )
}

/// Let leases lapse at the end of an expiring heal round.
fn heal_expiry(world: World, k: Int, mode: Heal) -> World {
  case mode {
    Deliver -> world
    Expire -> elapse(world, k)
  }
}

/// Drop finished runs and check the survivors against an independent oracle.
fn retention(world: World, k: Int) -> World {
  let before = world.durable
  let after = queue.retain(before, queue.Retention(1, 6))
  let kept = list.map(after.runs, fn(run) { run.id })
  let dropped =
    list.filter(before.runs, fn(run) { !list.contains(kept, run.id) })
  let flag = fn(world, name, condition) {
    case condition {
      True -> bump(world, name)
      False -> world
    }
  }
  world
  |> flag(
    "retention_dropped_live",
    list.any(dropped, fn(run) { !finished(run) }),
  )
  |> flag("retention_lost_proofs", after.cache != list.take(before.cache, 6))
  |> tally(dropped)
  |> bump_by("retained_dropped", list.length(dropped))
  |> commit(k, audit.Retain(queue.Retention(1, 6)), after)
}

/// Poll through controller `k`. A lost reply leaves the lease committed.
fn poll(world: World, k: Int, pool: String, lose: Bool) -> World {
  let w = worker(world, pool)
  case w.held {
    Some(_) -> world
    None -> {
      let #(next, assignment) =
        queue.claim(world.durable, worker_id(w), pool, world.clock)
      let world =
        commit(world, k, audit.Claim(worker_id(w), pool, world.clock), next)
      let held = case lose {
        True -> None
        False -> assignment
      }
      set_worker(world, Worker(..w, held:))
    }
  }
}

/// What a worker reports for an assignment it ran or tried to stage.
type Verdict {
  Honest
  Planted
  Refused(chunks.Violation)
}

/// One of the ways a worker refuses a chunked input, picked by `n`.
fn staging_violation(n: Int) -> chunks.Violation {
  case n % 5 {
    0 -> chunks.ChunkLength(n)
    1 -> chunks.ChunkDigest(n)
    2 -> chunks.NoChunk(n)
    3 -> chunks.TotalDigest
    _ -> chunks.InvalidManifest("total is not the sum")
  }
}

fn completion(job: queue.Assignment, verdict: Verdict) -> queue.Completion {
  case verdict {
    Planted ->
      queue.Rejected(
        "planted rejection " <> string.repeat("x", 3000),
        job.run <> "-rejected",
      )
    Refused(violation) ->
      queue.Rejected(chunks.describe(violation), job.run <> "-refused")
    Honest ->
      queue.Succeeded(
        list.map(job.task.action.outputs, queue.Artifact(_, job.run <> "-out")),
        job.run <> "-" <> job.task.action.name,
      )
  }
}

/// Submit a result and flag an acceptance that was not for the live lease.
fn report(
  world: World,
  k: Int,
  job: queue.Assignment,
  completion: queue.Completion,
) -> #(World, Bool) {
  let action = job.task.action.name
  let current = current_lease(world.durable, job.run, action)
  case
    queue.finish(
      world.durable,
      job.run,
      action,
      queue.lease_worker(job.lease),
      queue.lease_serial(job.lease),
      completion,
    )
  {
    Error(_) ->
      case list.contains(world.expired, queue.lease_serial(job.lease)) {
        True -> #(bump(world, "expired_results_rejected"), False)
        False -> #(world, False)
      }
    Ok(next) -> {
      let world = case completion {
        queue.Rejected(reason, _) ->
          case string.byte_size(reason) > 1024 {
            True -> bump(world, "oversized_reasons")
            False -> world
          }
        queue.Succeeded(_, _) -> world
        queue.Interrupted ->
          interrupted(bump(world, "interrupted_reports"), next, job)
      }
      let live = case current {
        Some(lease) ->
          queue.lease_serial(lease) == queue.lease_serial(job.lease)
          && queue.lease_worker(lease) == queue.lease_worker(job.lease)
        None -> False
      }
      let world = case live {
        True -> world
        False -> bump(world, "stale_acceptances")
      }
      let op =
        audit.Finish(
          job.run,
          action,
          queue.lease_worker(job.lease),
          queue.lease_serial(job.lease),
          completion,
        )
      #(commit(world, k, op, next), True)
    }
  }
}

/// An accepted interruption must leave the action where an expiry would: the
/// next attempt, the bound's `LeaseExpired`, or a skip in a failed run.
fn interrupted(
  world: World,
  next: queue.State,
  job: queue.Assignment,
) -> World {
  let attempt = queue.lease_attempt(job.lease)
  let step = case queue.find(next, job.run) {
    Ok(run) ->
      list.find(run.work, fn(work) {
        work.task.action.name == job.task.action.name
      })
      |> result.map(fn(work) { work.step })
    Error(Nil) -> Error(Nil)
  }
  case step {
    Ok(queue.Pending(previous))
      if previous == attempt && attempt < queue.max_attempts
    -> world
    Ok(queue.Failed(queue.LeaseExpired(attempts), _))
      if attempts == attempt && attempt >= queue.max_attempts
    -> bump(world, "interrupted_at_bound")
    Ok(queue.Skipped) ->
      case queue.find(next, job.run) {
        Ok(run) ->
          case list.any(run.work, fn(work) { failed_step(work.step) }) {
            True -> world
            False -> bump(world, "interrupt_miscounted")
          }
        Error(Nil) -> bump(world, "interrupt_miscounted")
      }
    _ -> bump(world, "interrupt_miscounted")
  }
}

/// Whether a step ended its run in failure.
fn failed_step(step: queue.Step) -> Bool {
  case step {
    queue.Failed(_, _) -> True
    queue.Pending(_)
    | queue.Active(_)
    | queue.Passed(_)
    | queue.Reused(_)
    | queue.Skipped -> False
  }
}

/// A worker reports its held lease. A lost reply makes it resend later.
fn complete(
  world: World,
  k: Int,
  pool: String,
  lose: Bool,
  verdict: Verdict,
) -> World {
  let w = worker(world, pool)
  let poison = case w.held {
    Some(job) -> poisoned(world, job.run)
    None -> False
  }
  case w.held, poison {
    None, _ -> world
    // A poison action kills its worker every time, so it never reports.
    Some(_), True ->
      set_worker(bump(world, "poison_drops"), Worker(..w, held: None))
    Some(job), False -> {
      let #(world, accepted) = report(world, k, job, completion(job, verdict))

      // Count a refused input only when the queue took the result.
      let world = case verdict, accepted {
        Refused(_), True -> bump(world, "staging_refusals")
        _, _ -> world
      }
      let held = case accepted && lose {
        True -> Some(job)
        False -> None
      }
      set_worker(world, Worker(..w, held:))
    }
  }
}

/// A worker holding a live lease disappears for good. The pool's next poll
/// comes from a new worker ID. Its result may still arrive late.
fn vanish(world: World, pool: String) -> World {
  let w = worker(world, pool)
  let id = worker_id(w)
  let holds =
    list.any(active_leases(world.durable), fn(entry) {
      let #(_, _, lease) = entry
      queue.lease_worker(lease) == id
    })
  case holds {
    False -> world
    True -> {
      let ghosts = case w.held {
        Some(job) -> list.append(world.ghosts, [job])
        None -> world.ghosts
      }
      let world =
        World(..world, ghosts:, vanished: [id, ..world.vanished])
        |> bump("vanished_with_lease")
      set_worker(world, Worker(..w, generation: w.generation + 1, held: None))
    }
  }
}

/// The worker restarts under the same ID and polls again. An interrupting
/// restart first reports the held attempt `Interrupted`, as the worker does
/// from its journal after `docker start`. Otherwise it forgets the lease, and
/// the old incarnation's result can still arrive later.
fn restart_worker(
  world: World,
  k: Int,
  pool: String,
  interrupt: Bool,
) -> World {
  let w = worker(world, pool)
  case w.held {
    None -> poll(world, k, pool, False)
    Some(job) if interrupt -> {
      let #(world, _) = report(world, k, job, queue.Interrupted)
      set_worker(world, Worker(..w, held: None)) |> poll(k, pool, False)
    }
    Some(job) -> {
      let before = world.durable
      let world =
        World(..world, ghosts: list.append(world.ghosts, [job]))
        |> set_worker(Worker(..w, held: None))
        |> poll(k, pool, False)
      case worker(world, pool).held {
        Some(again) if again.lease == job.lease && world.durable == before ->
          bump(world, "replayed_claims")
        Some(again) ->
          case
            again.lease != job.lease
            && list.contains(world.expired, queue.lease_serial(job.lease))
          {
            True -> bump(world, "returned_after_expiry")
            False -> world
          }
        None -> world
      }
    }
  }
}

/// Deliver the oldest outstanding result from a vanished or replaced
/// incarnation after other events have progressed.
fn late(world: World, k: Int) -> World {
  case world.ghosts {
    [] -> world
    [job, ..rest] -> {
      let #(world, accepted) =
        report(World(..world, ghosts: rest), k, job, completion(job, Honest))
      case accepted {
        True -> bump(world, "late_accepted")
        False -> bump(world, "late_rejected")
      }
    }
  }
}

/// An outside writer fast-forwards a branch or force-pushes over it.
fn outside_write(world: World, pool: String, forward: Bool) -> World {
  let branch = case pool {
    "build" -> "main"
    _ -> "release"
  }
  let base = case branch {
    "main" -> "main-0"
    _ -> "rel-0"
  }
  let head = ref(world, branch)
  let commit = "x" <> int.to_string(world.fresh)
  let parent = case forward {
    True -> head
    False -> base
  }
  World(
    ..world,
    fresh: world.fresh + 1,
    refs: dict.insert(world.refs, branch, commit),
    parents: dict.insert(world.parents, commit, parent),
  )
  |> bump(case forward {
    True -> "external_advances"
    False -> "force_pushes"
  })
}

fn ref(world: World, branch: String) -> String {
  let assert Ok(head) = dict.get(world.refs, branch)
  head
}

fn ancestor(
  parents: Dict(String, String),
  commit: String,
  head: String,
) -> Bool {
  case commit == head {
    True -> True
    False ->
      case dict.get(parents, head) {
        Ok(parent) -> ancestor(parents, commit, parent)
        Error(Nil) -> False
      }
  }
}

fn held_intents(program: Program) -> List(queue.Intent) {
  case program {
    Idle -> []
    Holding(intents) -> intents
    Decided(intent, _, rest) | Recording(intent, _, _, rest) -> [intent, ..rest]
    Replying(rest) -> rest
  }
}

/// Advance controller `k` one step through the `reconcile.tick` sequence.
fn step(world: World, k: Int) -> World {
  case controller(world, k).program {
    Idle -> {
      // Each reconcile tick prepares the heads of free lanes before landing.
      let world = prepare(world, k, False)
      let #(next, intents) = queue.landings(world.durable)
      let world = commit(world, k, audit.Landings, next)
      let other = held_intents(controller(world, 1 - k).program)
      let world = case
        list.any(intents, fn(i) {
          list.any(other, fn(o) { queue.intent_run(o) == queue.intent_run(i) })
        })
      {
        True -> bump(world, "concurrent_reconciles")
        False -> world
      }
      case intents {
        [] -> world
        _ -> set_program(world, k, Holding(intents))
      }
    }
    Holding([]) -> set_program(world, k, Idle)
    Holding([intent, ..rest]) -> {
      let c = queue.intent_candidate(intent)
      let observed = ref(world, queue.candidate_branch(c))
      let decision = case
        ancestor(world.parents, queue.candidate_commit(c), observed),
        observed == queue.candidate_base(c)
      {
        True, _ -> AlreadyLanded
        False, False -> Advanced
        False, True ->
          case
            world.mask / 256 % 2 == 1
            && { world.mask + denial_key(queue.intent_run(intent)) } % 3 == 0
          {
            True -> Denied
            False -> Push
          }
      }
      set_program(world, k, Decided(intent, decision, rest))
    }
    Decided(intent, AlreadyLanded, rest) ->
      set_program(world, k, Recording(intent, Ok(Nil), False, rest))
    Decided(intent, Advanced, rest) ->
      set_program(
        world,
        k,
        Recording(intent, Error(queue.TargetAdvanced), False, rest),
      )
    Decided(intent, Denied, rest) ->
      set_program(
        world,
        k,
        Recording(
          intent,
          Error(queue.PolicyDenied("pull request is not mergeable")),
          False,
          rest,
        ),
      )
    Decided(intent, Push, rest) -> {
      let c = queue.intent_candidate(intent)
      case ref(world, queue.candidate_branch(c)) == queue.candidate_base(c) {
        // The expected-old-object lease rejects the push. The intent stays open.
        False ->
          bump(world, "push_lease_failures")
          |> set_program(k, Holding(rest))
        True -> {
          let world = audit_write(world, intent)
          World(
            ..world,
            refs: dict.insert(
              world.refs,
              queue.candidate_branch(c),
              queue.candidate_commit(c),
            ),
            writes: [
              #(
                queue.candidate_branch(c),
                queue.intent_run(intent),
                queue.candidate_commit(c),
              ),
              ..world.writes
            ],
          )
          |> set_program(k, Recording(intent, Ok(Nil), True, rest))
        }
      }
    }
    Recording(intent, outcome, _, rest) -> {
      let open = case queue.find(world.durable, queue.intent_run(intent)) {
        Ok(run) ->
          run.submission == queue.Landing(queue.intent_candidate(intent))
        Error(Nil) -> False
      }
      let world = case queue.record_landing(world.durable, intent, outcome) {
        Error(_) -> world
        Ok(next) ->
          case open {
            True -> commit(world, k, audit.RecordLanding(intent, outcome), next)
            False ->
              bump(world, "double_resolutions")
              |> commit(k, audit.RecordLanding(intent, outcome), next)
          }
      }
      set_program(world, k, Replying(rest))
    }
    Replying(rest) -> set_program(world, k, Holding(rest))
  }
}

/// A ref write must come from an open intent for a fully tested candidate,
/// and an intent may write the ref only once.
fn audit_write(world: World, intent: queue.Intent) -> World {
  let c = queue.intent_candidate(intent)
  let #(tested, open) = case
    queue.find(world.durable, queue.intent_run(intent))
  {
    Ok(run) -> #(
      run.revision == queue.candidate_commit(c)
        && list.all(run.work, fn(work) { passing(work.step) }),
      run.submission == queue.Landing(c),
    )
    Error(Nil) -> #(False, False)
  }
  let world = case tested {
    True -> world
    False -> bump(world, "untested_writes")
  }
  let world = case open {
    True -> world
    False -> bump(world, "unauthorized_writes")
  }
  case list.any(world.writes, fn(w) { w.1 == queue.intent_run(intent) }) {
    True -> bump(world, "double_writes")
    False -> world
  }
}

fn passing(step: queue.Step) -> Bool {
  case step {
    queue.Passed(_) | queue.Reused(_) -> True
    _ -> False
  }
}

/// Crash controller `k` and start a new instance from the persisted bytes.
fn crash(world: World, k: Int) -> World {
  let c = controller(world, k)
  let point = case c.program {
    Idle | Holding([]) -> "crash_idle"
    Holding(_) | Decided(_, Push, _) -> "crash_after_landings_before_push"
    Decided(_, _, _) | Recording(_, _, False, _) ->
      "crash_after_observe_before_record"
    Recording(_, _, True, _) -> "crash_after_push_before_record"
    Replying(_) -> "crash_after_record_before_reply"
  }
  let encoded = json.to_string(protocol.encode_state(world.durable))
  let world = case json.parse(encoded, protocol.state_decoder()) {
    Ok(decoded) if decoded == world.durable -> world
    _ -> bump(world, "codec_mismatches")
  }
  let world = case c.restarted {
    Some(_) -> bump(world, "recovery_censored")
    None -> world
  }
  world
  |> bump(point)
  |> bump("restarts")
  |> set_controller(k, Controller(Idle, Some(#(world.event, world.clock))))
}

/// An independent oracle: no action can still change and no lane is held.
fn finished(run: queue.Run) -> Bool {
  let open =
    list.any(run.work, fn(work) {
      case work.step {
        queue.Pending(_) | queue.Active(_) -> True
        _ -> False
      }
    })
  let failed =
    list.any(run.work, fn(work) {
      case work.step {
        queue.Failed(_, _) -> True
        _ -> False
      }
    })
  case run.submission {
    queue.Landed(_) | queue.Blocked(_, _) | queue.Unprepared(_, _, _) -> True
    queue.Waiting(_, _) | queue.Landing(_) -> False
    queue.Build -> !open
    queue.Queued(_) -> !open && failed
  }
}

/// Restore reliable delivery to live workers and both controllers.
fn heal(world: World, round: Int, rounds: Int, mode: Heal) -> World {
  case round == rounds || list.all(world.durable.runs, finished) {
    True -> world
    False -> {
      let k = round % 2
      world
      |> event(prepare(_, k, False))
      |> event(prepare(_, k, False))
      |> event(poll(_, k, "build", False))
      |> event(complete(_, k, "build", False, Honest))
      |> event(poll(_, k, "test", False))
      |> event(complete(_, k, "test", False, Honest))
      |> drain(k, 12)
      |> drain(1 - k, 12)
      |> heal_expiry(k, mode)
      |> heal(round + 1, rounds, mode)
    }
  }
}

fn event(world: World, apply: fn(World) -> World) -> World {
  let world = apply(world)
  World(..world, event: world.event + 1, clock: world.clock + 10)
}

/// Run one full reconcile pass on controller `k`.
fn drain(world: World, k: Int, budget: Int) -> World {
  let world = event(world, step(_, k))
  case controller(world, k).program, budget {
    Idle, _ | _, 0 -> world
    _, _ -> drain(world, k, budget - 1)
  }
}

/// Count what the heal could not finish and the outcomes it reached.
fn classify(world: World) -> World {
  let runs = world.durable.runs
  let leases = active_leases(world.durable)
  let flag = fn(world, name, condition) {
    case condition {
      True -> bump(world, name)
      False -> world
    }
  }
  let count = fn(world, name, n) { bump_by(world, name, n) }
  let ghostly = fn(entry: #(String, String, queue.Lease)) {
    let #(_, _, lease) = entry
    list.contains(world.vanished, queue.lease_worker(lease))
  }
  let lanes =
    list.filter(["main", "release"], fn(branch) {
      list.any(runs, fn(run) { lane_of(run) == Ok(branch) && !finished(run) })
    })
  let stuck =
    list.filter(runs, fn(run) { !finished(run) && !behind_holder(runs, run) })
  let world =
    world
    |> flag("stuck_active_seeds", leases != [])
    |> flag("stuck_active_vanished_seeds", list.any(leases, ghostly))
    |> flag("stuck_active_other_seeds", list.any(leases, fn(e) { !ghostly(e) }))
    |> flag(
      "stuck_landing_seeds",
      list.any(runs, fn(run) {
        case run.submission {
          queue.Landing(_) -> True
          _ -> False
        }
      }),
    )
    |> count("stuck_runs", list.length(stuck))
    |> count("nonterminal_runs", list.count(runs, fn(run) { !finished(run) }))
    |> count("nonterminal_lanes", list.length(lanes))
    |> tally(runs)
  list.fold(world.controllers, world, fn(world, c) {
    case c.restarted {
      Some(_) -> bump(world, "recovery_censored")
      None -> world
    }
  })
}

/// A waiting run is explained by an unfinished run ahead of it in its lane.
fn behind_holder(runs: List(queue.Run), run: queue.Run) -> Bool {
  case run.submission {
    queue.Waiting(branch, _) ->
      list.take_while(runs, fn(other) { other.id != run.id })
      |> list.any(fn(other) { lane_of(other) == Ok(branch) && !finished(other) })
    _ -> False
  }
}

/// Count the outcomes of runs that reached a final state.
fn tally(world: World, runs: List(queue.Run)) -> World {
  let count = fn(world, name, n) { bump_by(world, name, n) }
  let landed =
    list.filter_map(runs, fn(run) {
      case run.submission {
        queue.Landed(c) ->
          Ok(#(queue.candidate_branch(c), run.id, queue.candidate_commit(c)))
        _ -> Error(Nil)
      }
    })
  let steps = list.flat_map(runs, fn(run) { run.work })
  world
  |> count(
    "landed_without_write",
    list.count(landed, fn(l) { !list.contains(world.writes, l) }),
  )
  |> count("landed_runs", list.length(landed))
  |> count(
    "blocked_runs",
    list.count(runs, fn(run) {
      case run.submission {
        queue.Blocked(_, _) | queue.Unprepared(_, _, _) -> True
        _ -> False
      }
    }),
  )
  |> count(
    "policy_denials",
    list.count(runs, fn(run) {
      case run.submission {
        queue.Blocked(_, queue.PolicyDenied(_)) -> True
        _ -> False
      }
    }),
  )
  |> count(
    "rejected_runs",
    list.count(runs, fn(run) {
      list.any(run.work, fn(w) {
        case w.step {
          queue.Failed(queue.Reported(_), _) -> True
          _ -> False
        }
      })
    }),
  )
  |> count(
    "poisoned_runs_final",
    list.count(steps, fn(w) {
      case w.step {
        queue.Failed(queue.LeaseExpired(_), _) -> True
        _ -> False
      }
    }),
  )
  |> count(
    "cache_hits",
    list.count(steps, fn(w) {
      case w.step {
        queue.Reused(_) -> True
        _ -> False
      }
    }),
  )
  |> count(
    "skipped_actions",
    list.count(steps, fn(w) {
      case w.step {
        queue.Skipped -> True
        _ -> False
      }
    }),
  )
}

/// Drive a long stream of builds through the core with retention after every
/// transition. Return the largest encoded state in bytes, the runs still held,
/// and the proofs reused. Every fifth run is rejected with a 256 KiB reason.
///
/// ## Examples
///
/// ```gleam
/// // queue_churn_dst.growth(400)
/// ```
pub fn growth(runs: Int) -> #(Int, Int, Int) {
  let retention = queue.Retention(8, 16)
  let #(state, largest) =
    int.range(0, runs, #(queue.empty(), 0), fn(acc, i) {
      let #(state, largest) = acc
      let id = "g" <> int.to_string(i)
      let action = graph.action("build", ["build"], [], ["out"], [], [], 10)
      let task =
        queue.whole_task(
          action,
          id,
          "recipe-" <> int.to_string(i % 7),
          "build",
          "image",
          sandbox.Strict,
        )
      let assert Ok(#(state, _)) =
        queue.admit(state, id, "repo", id, "check", queue.Build, [task])
      let #(state, claimed) = queue.claim(state, "w", "build", i * 1000)
      let done = case claimed {
        None -> state
        Some(job) -> {
          let completion = case i % 5 {
            4 -> queue.Rejected(string.repeat("r", 262_144), id)
            _ ->
              queue.Succeeded(
                list.map(action.outputs, queue.Artifact(_, id <> "-out")),
                id,
              )
          }
          let assert Ok(next) =
            queue.finish(
              state,
              id,
              "build",
              "w",
              queue.lease_serial(job.lease),
              completion,
            )
          next
        }
      }
      let state = queue.retain(done, retention)
      let size = string.byte_size(json.to_string(protocol.encode_state(state)))
      #(state, int.max(largest, size))
    })
  let reused =
    list.count(list.flat_map(state.runs, fn(run) { run.work }), fn(work) {
      case work.step {
        queue.Reused(_) -> True
        _ -> False
      }
    })
  #(largest, list.length(state.runs), reused)
}
