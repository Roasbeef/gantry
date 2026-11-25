//// A counting simulation over the production queue. Two controllers share one
//// linearizable store and one simulated Git remote with two branches. Either
//// controller can crash at any point of the landing sequence and restart from
//// the persisted codec bytes. Both can reconcile the same intent at once.
//// Workers can vanish while holding a lease, restart under the same ID, and
//// deliver late results. The fixture shares one recipe across two runs so a
//// proof is reused, and a fault can reject a completion.
////
//// Violations are counted rather than asserted so a sweep reports numbers.
//// The heal phase restores reliable delivery to live workers and controllers
//// only. A vanished worker never returns, so a lease it held stays visible.

import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The reconciler's view of one observed ref, as in `submit.reconcile`.
type Decision {
  AlreadyLanded
  Advanced
  Push
}

/// The controller-local landing program. A crash discards all of it.
type Program {
  Idle
  Holding(intents: List(queue.Intent))
  Decided(intent: queue.Intent, decision: Decision, rest: List(queue.Intent))
  Recording(
    intent: queue.Intent,
    outcome: Result(Nil, String),
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
    controllers: List(Controller),
    workers: List(Worker),
    ghosts: List(queue.Assignment),
    vanished: List(String),
    refs: Dict(String, String),
    parents: Dict(String, String),
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
]

/// Counters that report liveness after the heal phase.
pub const liveness = [
  "stuck_active_seeds", "stuck_active_vanished_seeds",
  "stuck_active_other_seeds", "stuck_landing_seeds", "nonterminal_runs",
  "nonterminal_lanes",
]

/// Counters that show each fault class was exercised.
pub const coverage = [
  "restarts", "crash_idle", "crash_after_landings_before_push",
  "crash_after_observe_before_record", "crash_after_push_before_record",
  "crash_after_record_before_reply", "concurrent_reconciles",
  "push_lease_failures", "external_advances", "force_pushes",
  "vanished_with_lease", "replayed_claims", "late_accepted", "late_rejected",
  "cache_hits", "rejected_runs", "landed_runs", "blocked_runs",
  "recovery_censored",
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
    list.fold(ops, start(), fn(world, op) {
      let world = tick(world, mask, op)
      World(
        ..world,
        event: world.event + 1,
        clock: world.clock + 5 + op * 13 % 41,
      )
    })
  Report(classify(heal(world, 0, 40)))
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
      <> queue.phase(run)
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
  #(mask % 128, list.reverse(ops))
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

fn bump(world: World, name: String) -> World {
  World(..world, counts: add(world.counts, name, 1))
}

/// Admit two candidates on `main`, one on `release`, and a build that shares
/// the first candidate's producer recipe.
fn start() -> World {
  let specs = [
    #("a", Some(#("main", "main-0")), "producer-shared"),
    #("r", Some(#("release", "rel-0")), "producer-r"),
    #("b", Some(#("main", "main-0")), "producer-b"),
    #("build-only", None, "producer-shared"),
  ]
  let durable =
    list.fold(specs, queue.empty(), fn(state, spec) {
      let #(id, lane, recipe) = spec
      let submission = case lane {
        None -> queue.Build
        Some(#(branch, base)) ->
          queue.Queued(queue.Candidate(branch, base, id, [queue.Member(1, id)]))
      }
      let producer = graph.Action("build", ["build"], [], ["out"], [], [], 10)
      let consumer = graph.Action("test", ["test"], [], [], ["build"], [], 10)
      let assert Ok(#(next, _)) =
        queue.admit(state, id, "repo", id, "check", submission, [
          queue.Task(producer, id, recipe, "build", "image"),
          queue.Task(consumer, id, "consumer-" <> id, "test", "image"),
        ])
      next
    })
  World(
    durable:,
    controllers: [Controller(Idle, None), Controller(Idle, None)],
    workers: [Worker("build", 0, None), Worker("test", 0, None)],
    ghosts: [],
    vanished: [],
    refs: dict.from_list([#("main", "main-0"), #("release", "rel-0")]),
    parents: dict.from_list([
      #("a", "main-0"),
      #("b", "main-0"),
      #("r", "rel-0"),
    ]),
    writes: [],
    issued: dict.new(),
    fresh: 0,
    counts: dict.new(),
    samples: [],
    event: 0,
    clock: 0,
  )
}

/// Mask bits: 0 lost claim replies, 1 lost result replies, 2 controller
/// crashes, 3 outside ref writes, 4 vanishing workers, 5 same-ID restarts and
/// late results, 6 rejected completions. A disabled fault runs the honest op.
fn tick(world: World, mask: Int, op: Int) -> World {
  let k = op / 16 % 2
  let pool = case op / 32 % 2 {
    0 -> "build"
    _ -> "test"
  }
  let on = fn(bit) { mask / bit % 2 == 1 }
  case op % 16 {
    0 | 1 -> poll(world, k, pool, False)
    2 -> poll(world, k, pool, on(1))
    3 | 4 -> complete(world, k, pool, False, False)
    5 -> complete(world, k, pool, on(2), False)
    6 -> complete(world, k, pool, False, on(64) && op / 64 == 0)
    7 | 8 | 9 -> step(world, k)
    10 if mask / 4 % 2 == 1 -> crash(world, k)
    10 -> step(world, k)
    11 if mask / 8 % 2 == 1 -> outside_write(world, pool, op / 64 % 2 == 0)
    11 -> step(world, k)
    12 if mask / 16 % 2 == 1 -> vanish(world, pool)
    12 -> poll(world, k, pool, False)
    13 if mask / 32 % 2 == 1 -> restart_worker(world, k, pool)
    13 -> poll(world, k, pool, False)
    14 if mask / 32 % 2 == 1 || mask / 16 % 2 == 1 -> late(world, k)
    14 -> complete(world, k, pool, False, False)
    _ -> world
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
fn commit(world: World, k: Int, next: queue.State) -> World {
  case next == world.durable {
    True -> world
    False -> {
      let world = admissions(world, next)
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
          list.any(before, fn(old) { old.0 == run && old.1 == action })
        let reissued = case dict.get(world.issued, lease.serial) {
          Ok(identity) -> identity != #(run, action, lease.worker)
          Error(Nil) -> False
        }
        let doubled =
          list.count(after, fn(other) {
            let #(_, _, held) = other
            held.worker == lease.worker
          })
          > 1
        let world = case replaced || reissued || doubled {
          True -> bump(world, "duplicate_admissions")
          False -> world
        }
        World(
          ..world,
          issued: dict.insert(world.issued, lease.serial, #(
            run,
            action,
            lease.worker,
          )),
        )
      }
    }
  })
}

/// Poll through controller `k`. A lost reply leaves the lease committed.
fn poll(world: World, k: Int, pool: String, lose: Bool) -> World {
  let w = worker(world, pool)
  case w.held {
    Some(_) -> world
    None -> {
      let #(next, assignment) =
        queue.claim(world.durable, worker_id(w), pool, world.clock)
      let world = commit(world, k, next)
      let held = case lose {
        True -> None
        False -> assignment
      }
      set_worker(world, Worker(..w, held:))
    }
  }
}

fn completion(job: queue.Assignment, reject: Bool) -> queue.Completion {
  case reject {
    True -> queue.Rejected("planted rejection", job.run <> "-rejected")
    False ->
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
      job.lease.worker,
      job.lease.serial,
      completion,
    )
  {
    Error(_) -> #(world, False)
    Ok(next) -> {
      let live = case current {
        Some(lease) ->
          lease.serial == job.lease.serial && lease.worker == job.lease.worker
        None -> False
      }
      let world = case live {
        True -> world
        False -> bump(world, "stale_acceptances")
      }
      #(commit(world, k, next), True)
    }
  }
}

/// A worker reports its held lease. A lost reply makes it resend later.
fn complete(
  world: World,
  k: Int,
  pool: String,
  lose: Bool,
  reject: Bool,
) -> World {
  let w = worker(world, pool)
  case w.held {
    None -> world
    Some(job) -> {
      let #(world, accepted) = report(world, k, job, completion(job, reject))
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
      lease.worker == id
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

/// The worker restarts under the same ID, forgets its lease and polls again.
/// The old incarnation's result can still arrive later.
fn restart_worker(world: World, k: Int, pool: String) -> World {
  let w = worker(world, pool)
  case w.held {
    None -> poll(world, k, pool, False)
    Some(job) -> {
      let before = world.durable
      let world =
        World(..world, ghosts: list.append(world.ghosts, [job]))
        |> set_worker(Worker(..w, held: None))
        |> poll(k, pool, False)
      case worker(world, pool).held {
        Some(again) if again.lease == job.lease && world.durable == before ->
          bump(world, "replayed_claims")
        _ -> world
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
        report(World(..world, ghosts: rest), k, job, completion(job, False))
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
      let #(next, intents) = queue.landings(world.durable)
      let world = commit(world, k, next)
      let other = held_intents(controller(world, 1 - k).program)
      let world = case
        list.any(intents, fn(i) { list.any(other, fn(o) { o.run == i.run }) })
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
      let c = intent.candidate
      let observed = ref(world, c.branch)
      let decision = case
        ancestor(world.parents, c.commit, observed),
        observed == c.base
      {
        True, _ -> AlreadyLanded
        False, False -> Advanced
        False, True -> Push
      }
      set_program(world, k, Decided(intent, decision, rest))
    }
    Decided(intent, AlreadyLanded, rest) ->
      set_program(world, k, Recording(intent, Ok(Nil), False, rest))
    Decided(intent, Advanced, rest) ->
      set_program(
        world,
        k,
        Recording(
          intent,
          Error("target advanced outside the tested candidate"),
          False,
          rest,
        ),
      )
    Decided(intent, Push, rest) -> {
      let c = intent.candidate
      case ref(world, c.branch) == c.base {
        // The expected-old-object lease rejects the push. The intent stays open.
        False ->
          bump(world, "push_lease_failures")
          |> set_program(k, Holding(rest))
        True -> {
          let world = audit_write(world, intent)
          World(
            ..world,
            refs: dict.insert(world.refs, c.branch, c.commit),
            writes: [#(c.branch, intent.run, c.commit), ..world.writes],
          )
          |> set_program(k, Recording(intent, Ok(Nil), True, rest))
        }
      }
    }
    Recording(intent, outcome, _, rest) -> {
      let open = case queue.find(world.durable, intent.run) {
        Ok(run) -> run.submission == queue.Landing(intent.candidate)
        Error(Nil) -> False
      }
      let world = case queue.record_landing(world.durable, intent, outcome) {
        Error(_) -> world
        Ok(next) ->
          case open {
            True -> commit(world, k, next)
            False -> bump(world, "double_resolutions") |> commit(k, next)
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
  let c = intent.candidate
  let #(tested, open) = case queue.find(world.durable, intent.run) {
    Ok(run) -> #(
      run.revision == c.commit
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
  case list.any(world.writes, fn(w) { w.1 == intent.run }) {
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

fn terminal(run: queue.Run) -> Bool {
  case run.submission, queue.phase(run) {
    queue.Build, "passed" -> True
    _, "failed" | _, "landed" | _, "blocked" -> True
    _, _ -> False
  }
}

/// Restore reliable delivery to live workers and both controllers.
fn heal(world: World, round: Int, rounds: Int) -> World {
  case round == rounds || list.all(world.durable.runs, terminal) {
    True -> world
    False -> {
      let k = round % 2
      world
      |> event(poll(_, k, "build", False))
      |> event(complete(_, k, "build", False, False))
      |> event(poll(_, k, "test", False))
      |> event(complete(_, k, "test", False, False))
      |> drain(k, 12)
      |> drain(1 - k, 12)
      |> heal(round + 1, rounds)
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
  let count = fn(world, name, n) {
    World(..world, counts: add(world.counts, name, n))
  }
  let ghostly = fn(entry: #(String, String, queue.Lease)) {
    let #(_, _, lease) = entry
    list.contains(world.vanished, lease.worker)
  }
  let landed =
    list.filter_map(runs, fn(run) {
      case run.submission {
        queue.Landed(c) -> Ok(#(c.branch, run.id, c.commit))
        _ -> Error(Nil)
      }
    })
  let lanes =
    list.filter(["main", "release"], fn(branch) {
      list.any(runs, fn(run) {
        case run.submission {
          queue.Queued(c)
          | queue.Landing(c)
          | queue.Landed(c)
          | queue.Blocked(c, _) -> c.branch == branch && !terminal(run)
          queue.Build -> False
        }
      })
    })
  let world =
    world
    |> flag("stuck_active_seeds", leases != [])
    |> flag("stuck_active_vanished_seeds", list.any(leases, ghostly))
    |> flag("stuck_active_other_seeds", list.any(leases, fn(e) { !ghostly(e) }))
    |> flag(
      "stuck_landing_seeds",
      list.any(runs, fn(run) { queue.phase(run) == "landing" }),
    )
    |> count("nonterminal_runs", list.count(runs, fn(run) { !terminal(run) }))
    |> count("nonterminal_lanes", list.length(lanes))
    |> count(
      "landed_without_write",
      list.count(landed, fn(l) { !list.contains(world.writes, l) }),
    )
    |> count("landed_runs", list.length(landed))
    |> count(
      "blocked_runs",
      list.count(runs, fn(run) { queue.phase(run) == "blocked" }),
    )
    |> count(
      "rejected_runs",
      list.count(runs, fn(run) {
        list.any(run.work, fn(w) {
          case w.step {
            queue.Failed(_, _) -> True
            _ -> False
          }
        })
      }),
    )
    |> count(
      "cache_hits",
      list.count(list.flat_map(runs, fn(run) { run.work }), fn(w) {
        case w.step {
          queue.Reused(_) -> True
          _ -> False
        }
      }),
    )
  list.fold(world.controllers, world, fn(world, c) {
    case c.restarted {
      Some(_) -> bump(world, "recovery_censored")
      None -> world
    }
  })
}
