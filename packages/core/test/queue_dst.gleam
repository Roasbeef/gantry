//// The runner calls the production queue through simulated controller CAS,
//// worker delivery and Git. The same boundaries drive a bounded heal.
////
//// One lane holds three waiting groups that the core prepares in order as the
//// lane frees. Leases expire and are reassigned, so a result from an earlier
//// generation can arrive late. A preparation can be refused, the provider can
//// deny a landing, and retention can drop finished runs. Each event checks the
//// invariants, and the heal must leave every run finished with no live lease.

import gantry_core/graph
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

type Reply {
  Deliver
  Lose
  Deny
}

type World {
  World(
    durable: queue.State,
    snapshot: queue.State,
    deliveries: List(queue.Assignment),
    intents: List(queue.Intent),
    history: List(String),
    writes: List(String),
    prepared: List(String),
    clock: Int,
    counts: Dict(String, Int),
  )
}

/// Compare the complete final world and the externally visible event trace.
pub opaque type Report {
  Report(healed: World, trace: List(#(Int, Int, Int, String)))
}

/// The coverage counters of one report.
///
/// ## Examples
///
/// ```gleam
/// // queue_dst.counts(queue_dst.run_seed(73, 128))
/// ```
pub fn counts(report: Report) -> Dict(String, Int) {
  report.healed.counts
}

/// Expand a portable seed into a fault mask and operation stream.
///
/// ## Examples
///
/// ```gleam
/// // queue_dst.run_seed(73, 128)
/// ```
pub fn run_seed(seed: Int, events: Int) -> Report {
  let #(mask, ops) = schedule(seed, events)
  run(mask, ops)
}

/// Replay the seed and print each event before its invariant checks.
///
/// ## Examples
///
/// ```gleam
/// // queue_dst.replay_seed(73, 128)
/// ```
pub fn replay_seed(seed: Int, events: Int) -> Report {
  let #(mask, ops) = schedule(seed, events)
  replay(mask, ops)
}

/// Replay explicit operation bytes and show the last event before a failure.
///
/// ## Examples
///
/// ```gleam
/// // queue_dst.replay(127, [0, 3, 13])
/// ```
pub fn replay(mask: Int, events: List(Int)) -> Report {
  io.println("fault mask " <> int.to_string(mask))
  run_with_trace(mask, events, fn(index, op) {
    io.println("event " <> int.to_string(index) <> " op " <> int.to_string(op))
  })
}

/// Expand the seed without running the scenario.
fn schedule(seed: Int, events: Int) -> #(Int, List(Int)) {
  let seed = int.max(1, seed % 2_147_483_647)
  let mask = next_seed(seed)
  let #(_, ops) =
    list.fold(list.repeat(Nil, events), #(mask, []), fn(state, _) {
      let next = next_seed(state.0)
      #(next, [next % 256, ..state.1])
    })
  #(mask % 512, list.reverse(ops))
}

fn next_seed(seed: Int) -> Int {
  seed * 48_271 % 2_147_483_647
}

/// Run through faults, then drain the queue through normal calls.
///
/// ## Examples
///
/// ```gleam
/// // queue_dst.run(127, [0, 2, 4, 9, 12])
/// ```
pub fn run(mask: Int, events: List(Int)) -> Report {
  run_with_trace(mask, events, fn(_, _) { Nil })
}

/// Check each event before moving to the next one.
fn run_with_trace(
  mask: Int,
  events: List(Int),
  observe: fn(Int, Int) -> Nil,
) -> Report {
  let #(world, _, trace) =
    list.fold(events, #(start(), 0, []), fn(state, op) {
      let #(before, index, trace) = state
      observe(index, op)
      let after = tick(before, mask, op)
      check(after)
      assert after.durable.serial >= before.durable.serial
        as "lease serial is monotonic"
      #(after, index + 1, [
        #(op, after.durable.serial, list.length(after.writes), top(after)),
        ..trace
      ])
    })
  let healed = heal(world, 60)
  finish_checks(healed)
  Report(healed, list.reverse(trace))
}

/// The liveness and ordering facts that hold once the heal completes.
fn finish_checks(world: World) {
  assert list.all(world.durable.runs, finished)
    as "every run is terminal after the heal"
  assert list.all(world.durable.runs, fn(run) {
    list.all(run.work, fn(work) {
      case work.step {
        queue.Active(_) | queue.Pending(_) -> False
        _ -> True
      }
    })
  })
    as "no live lease or pending action survives the heal"
  let lane = ["a", "b", "c"]
  assert list.reverse(world.prepared)
    == list.filter(lane, list.contains(world.prepared, _))
    as "waiting groups are prepared in queue order"
}

/// Admit three waiting groups for one branch and an independent build.
fn start() -> World {
  let empty = queue.empty()
  let durable =
    list.fold(["a", "b", "build-only", "c"], empty, fn(state, id) {
      let assert Ok(#(next, _)) = case id {
        "build-only" ->
          queue.admit(state, id, "repo", id, "check", queue.Build, tasks(id))
        _ ->
          queue.admit(
            state,
            id,
            "repo",
            "",
            "check",
            queue.Waiting("main", [queue.Member(1, id)]),
            [],
          )
      }
      next
    })
  World(durable, empty, [], [], ["base"], [], [], 0, dict.new())
}

/// The two-action graph of one run, with a cross-pool dependency.
fn tasks(id: String) -> List(queue.Task) {
  let producer = graph.action("build", ["build"], [], ["out"], [], [], 10)
  let consumer = graph.action("test", ["test"], [], [], ["build"], [], 10)
  [
    queue.whole_task(
      producer,
      id,
      "producer-" <> id,
      "build",
      "image",
      pool_profile("build"),
    ),
    queue.whole_task(
      consumer,
      id,
      "consumer-" <> id,
      "test",
      "image",
      pool_profile("test"),
    ),
  ]
}

/// Each pool serves one sandbox profile, as `controller.toml` requires. The
/// consumer's pool is the wider one, so profiles cross a dependency edge.
fn pool_profile(pool: String) -> sandbox.Profile {
  case pool {
    "test" -> sandbox.Userns
    _ -> sandbox.Strict
  }
}

fn top(world: World) -> String {
  case world.history {
    [head, ..] -> head
    [] -> ""
  }
}

fn bump(world: World, name: String) -> World {
  add(world, name, 1)
}

fn add(world: World, name: String, by: Int) -> World {
  World(
    ..world,
    counts: dict.upsert(world.counts, name, fn(prior) {
      case prior {
        Some(n) -> n + by
        None -> by
      }
    }),
  )
}

/// Deliver an event. A disabled fault spends its event on the honest action.
fn tick(world: World, mask: Int, op: Int) -> World {
  // The next bit chooses the slot; the low nibble chooses the operation.
  let pool = case op / 16 % 2 {
    0 -> "build"
    _ -> "test"
  }
  let lose_claim = mask % 2 == 1
  let oldest = mask / 2 % 2 == 1
  let wrong = mask / 4 % 2 == 1
  let lose_result = mask / 8 % 2 == 1
  let lose_git = mask / 16 % 2 == 1
  let advance = mask / 32 % 2 == 1
  let reload = mask / 64 % 2 == 1
  let refuse = mask / 128 % 2 == 1
  let deny = mask / 256 % 2 == 1
  let world = World(..world, clock: world.clock + 1)

  // Cache stale reads until the controller polls or restarts.
  case op % 16 {
    0 | 1 -> read(world)
    2 -> claim(world, pool, Deliver).0
    3 if lose_claim -> claim(world, pool, Lose).0
    3 -> claim(world, pool, Deliver).0
    4 | 5 -> deliver(world, list.first(world.deliveries))
    6 if oldest -> deliver(world, list.last(world.deliveries))
    6 -> deliver(world, list.first(world.deliveries))
    7 if wrong -> wrong_receipt(world, list.first(world.deliveries), op)
    7 -> deliver(world, list.first(world.deliveries))
    8 if lose_result -> lose_result_reply(world, list.first(world.deliveries))
    8 -> deliver(world, list.first(world.deliveries))
    9 -> reconcile(world, Deliver)
    10 if deny && op / 16 % 2 == 1 -> reconcile(world, Deny)
    10 -> reconcile(world, Deliver)
    11 if lose_git -> reconcile(world, Lose)
    11 -> reconcile(world, Deliver)
    12 if advance -> external_advance(world)
    12 -> read(world)
    13 if reload -> restart(world)
    13 -> read(world)
    14 -> elapse(world)
    _ ->
      case op / 64 % 2 {
        0 -> prepare(world, refuse && op / 32 % 2 == 1)
        _ -> retention(world)
      }
  }
}

fn read(world: World) -> World {
  World(..world, snapshot: world.durable)
}

/// A restart reloads the real serialized durable state through the codec.
fn restart(world: World) -> World {
  let encoded = json.to_string(protocol.encode_state(world.durable))
  let assert Ok(snapshot) = json.parse(encoded, protocol.state_decoder())
  assert snapshot == world.durable as "restart preserves the durable snapshot"

  // A snapshot written before profiles existed has no sandbox field. Its
  // tasks were strict, so dropping the strict fields must decode the same.
  let old = string.replace(encoded, "\"sandbox\":\"strict\",", "")
  let old = string.replace(old, ",\"sandbox\":\"strict\"", "")
  assert !string.contains(old, "\"sandbox\":\"strict\"")
    as "every strict field was removed from the old snapshot"
  let assert Ok(upgraded) = json.parse(old, protocol.state_decoder())
  assert upgraded == world.durable
    as "a snapshot without profiles decodes its tasks as strict"
  World(..world, snapshot:, intents: [])
}

/// Let time pass so held leases lapse, then run the controller's expiry tick.
fn elapse(world: World) -> World {
  // The jump outlasts the lease slack plus the fixture's action timeout.
  let clock = world.clock + 1000
  let durable = queue.expire(world.durable, clock)
  let lapsed = active_count(world.durable) - active_count(durable)
  World(..world, clock:, durable:) |> add("expiries", lapsed)
}

fn active_count(state: queue.State) -> Int {
  list.count(list.flat_map(state.runs, fn(run) { run.work }), fn(work) {
    case work.step {
      queue.Active(_) -> True
      _ -> False
    }
  })
}

/// Claim by CAS and deliver the assignment only after its write commits.
fn claim(
  world: World,
  pool: String,
  reply: Reply,
) -> #(World, Result(queue.Assignment, Nil)) {
  let #(next, assignment) =
    queue.claim(world.snapshot, pool <> "-worker", pool, world.clock)

  // Stale controller writes lose the CAS before their lease can escape.
  case world.snapshot == world.durable, assignment, reply {
    False, _, _ -> #(world, Error(Nil))
    True, Some(job), Deliver -> {
      assert job.task.sandbox == pool_profile(pool)
        as "an assignment carries its pool's sandbox profile unchanged"
      let world = case job.task.sandbox {
        sandbox.Userns -> bump(world, "userns_assignments")
        sandbox.Strict -> world
      }
      let world = case queue.lease_attempt(job.lease) > 1 {
        True -> bump(world, "reassigned")
        False -> world
      }
      #(
        World(
          ..world,
          durable: next,
          deliveries: list.unique([job, ..world.deliveries]),
        ),
        Ok(job),
      )
    }
    True, _, _ -> #(World(..world, durable: next), Error(Nil))
  }
}

/// The step of one action, when its run still exists.
fn step_of(state: queue.State, job: queue.Assignment) -> Option(queue.Step) {
  case queue.find(state, job.run) {
    Error(Nil) -> None
    Ok(run) ->
      list.find(run.work, fn(work) {
        work.task.action.name == job.task.action.name
      })
      |> option.from_result
      |> option.map(fn(work) { work.step })
  }
}

/// Whether the worker and serial name the action's live lease.
fn live(
  state: queue.State,
  job: queue.Assignment,
  worker: String,
  serial: Int,
) -> Bool {
  case step_of(state, job) {
    Some(queue.Active(lease)) ->
      queue.lease_serial(lease) == serial && queue.lease_worker(lease) == worker
    _ -> False
  }
}

/// Apply a worker report. A previously delivered receipt is still replayable.
fn deliver(world: World, message: Result(queue.Assignment, Nil)) -> World {
  case message {
    Error(Nil) -> world
    Ok(job) -> {
      let worker = queue.lease_worker(job.lease)
      let serial = queue.lease_serial(job.lease)
      let was_live = live(world.durable, job, worker, serial)
      let outcome =
        queue.finish(
          world.durable,
          job.run,
          job.task.action.name,
          worker,
          serial,
          completion(job),
        )
      case outcome {
        Ok(next) -> {
          assert was_live as "only the live generation is accepted"
          World(..world, durable: next)
        }
        Error(_) -> {
          assert !was_live as "a live generation is never refused"
          classify_rejection(world, job)
        }
      }
    }
  }
}

/// Count why a late result was refused, which shows each path is reachable.
fn classify_rejection(world: World, job: queue.Assignment) -> World {
  case step_of(world.durable, job) {
    Some(queue.Pending(_)) -> bump(world, "result_after_expiry_rejected")
    Some(queue.Active(_)) -> bump(world, "result_after_reassign_rejected")
    Some(queue.Skipped) | Some(queue.Failed(_, _)) ->
      bump(world, "result_in_failed_run_rejected")
    _ -> world
  }
}

/// Lose the HTTP response after the controller processes an attempt.
fn lose_result_reply(
  world: World,
  message: Result(queue.Assignment, Nil),
) -> World {
  let applied = deliver(world, message)
  assert deliver(applied, message).durable == applied.durable
    as "committed results replay idempotently"
  applied
}

/// Send the same result with a worker ID or serial outside the lease.
fn wrong_receipt(
  world: World,
  message: Result(queue.Assignment, Nil),
  op: Int,
) -> World {
  case message {
    Error(Nil) -> world
    Ok(job) -> {
      // Use the high bits to cover each field independently.
      let #(worker, serial) = case op / 32 % 2 {
        0 -> #(queue.lease_worker(job.lease), queue.lease_serial(job.lease) + 1)
        _ -> #("unassigned-worker", queue.lease_serial(job.lease))
      }

      // A reassigned action can legitimately hold the neighboring serial.
      let outcome =
        queue.finish(
          world.durable,
          job.run,
          job.task.action.name,
          worker,
          serial,
          completion(job),
        )
      case live(world.durable, job, worker, serial), outcome {
        True, _ -> world
        False, Error(_) -> world
        False, Ok(_) -> panic as "wrong worker or serial settled an action"
      }
    }
  }
}

fn completion(job: queue.Assignment) -> queue.Completion {
  let files =
    list.map(job.task.action.outputs, queue.Artifact(_, job.run <> "-out"))
  queue.Succeeded(files, job.run <> "-" <> job.task.action.name)
}

/// Prepare the head-of-lane group, or refuse it when the fault is enabled.
fn prepare(world: World, refuse: Bool) -> World {
  case queue.preparations(world.snapshot) {
    [] -> world
    [offer, ..] -> {
      // Only a controller holding the current snapshot can commit the write.
      let id = queue.preparation_run(offer)
      let outcome = case refuse {
        True -> Error(queue.MemberMoved(1))
        False ->
          Ok(#(
            queue.candidate(
              queue.preparation_branch(offer),
              top(world),
              id,
              queue.preparation_members(offer),
            ),
            tasks(id),
          ))
      }
      case world.snapshot == world.durable {
        False -> world
        True -> {
          let assert Ok(durable) =
            queue.record_preparation(world.durable, offer, outcome)
          let world = case outcome {
            Ok(_) ->
              World(..world, prepared: [id, ..world.prepared])
              |> bump("prepared")
            Error(_) -> bump(world, "preparation_refused")
          }
          // A repeat of the same offer must be refused, not applied twice.
          assert result.is_error(queue.record_preparation(
            durable,
            offer,
            outcome,
          ))
            as "a recorded preparation is not recorded twice"
          World(..world, durable:)
        }
      }
    }
  }
}

/// Drop finished runs and check what survives against an independent oracle.
fn retention(world: World) -> World {
  let before = world.durable
  let after = queue.retain(before, queue.Retention(1, 6))
  let kept = list.map(after.runs, fn(run) { run.id })
  let dropped =
    list.filter(before.runs, fn(run) { !list.contains(kept, run.id) })
  assert list.all(dropped, finished) as "retention never drops a live run"
  assert list.all(before.runs, fn(run) {
    finished(run) || list.contains(kept, run.id)
  })
  assert after.cache == list.take(before.cache, 6)
    as "retention keeps the newest proofs for reuse"
  assert list.length(list.filter(after.runs, finished)) <= 1
    as "retention bounds finished runs"
  World(..world, durable: after)
  |> add("retained_dropped", list.length(dropped))
}

/// Simulate the Git adapter and the separate durable result write.
fn reconcile(world: World, reply: Reply) -> World {
  // Dispatch the exact intent returned by the committed queue transition.
  case world.intents {
    [] -> {
      let #(durable, intents) = queue.landings(world.durable)
      assert list.length(intents) <= 1 as "one returned intent per lane"
      World(..world, durable:, intents:)
    }
    [effect] -> {
      let world = World(..world, intents: [])
      let candidate = queue.intent_candidate(effect)
      let open = top(world) == queue.candidate_base(candidate)

      // A later reconciliation learns the Git outcome after a lost reply.
      case reply, open {
        Deny, True -> {
          let assert Ok(durable) =
            queue.record_landing(
              world.durable,
              effect,
              Error(queue.PolicyDenied("pull request is not mergeable")),
            )
          World(..world, durable:) |> bump("policy_denied")
        }
        Lose, _ -> git_cas(world, effect)
        Deliver, _ | Deny, False ->
          settle_landing(git_cas(world, effect), effect)
      }
    }
    _ -> panic as "the fixture's single lane issued multiple intents"
  }
}

/// Apply the simulated expected-old-object update.
fn git_cas(world: World, effect: queue.Intent) -> World {
  let candidate = queue.intent_candidate(effect)
  let assert Ok(run) = queue.find(world.durable, queue.intent_run(effect))
  let assert queue.Landing(pinned) = run.submission
  assert queue.intent_repo(effect) == run.repo
    && queue.candidate_branch(candidate) == "main"
  assert pinned == candidate
    && run.revision == queue.candidate_commit(candidate)
  assert list.all(run.work, fn(work) { passing(work.step) })

  // An external advance makes this intent ineligible to mutate the ref.
  case top(world) == queue.candidate_base(candidate) {
    False -> world
    True -> {
      assert !list.contains(world.writes, run.id) as "one write per intent"
      World(
        ..world,
        history: [queue.candidate_commit(candidate), ..world.history],
        writes: [run.id, ..world.writes],
      )
    }
  }
}

/// Model a competing push before the candidate or after it.
fn external_advance(world: World) -> World {
  case list.length(world.history) < 12 {
    False -> world
    True ->
      World(..world, history: [
        "ext" <> int.to_string(list.length(world.history)),
        ..world.history
      ])
      |> bump("external_advances")
  }
}

fn settle_landing(world: World, effect: queue.Intent) -> World {
  // A descendant is evidence that the original push succeeded.
  let commit = queue.candidate_commit(queue.intent_candidate(effect))
  let outcome = case list.contains(world.history, commit) {
    True -> Ok(Nil)
    False -> Error(queue.TargetAdvanced)
  }

  let assert Ok(durable) = queue.record_landing(world.durable, effect, outcome)
  World(..world, durable:)
  |> bump(case outcome {
    Ok(Nil) -> "landed"
    Error(_) -> "target_advanced"
  })
}

/// Check slot ownership, lane exclusivity, graph order and Git identity.
fn check(world: World) {
  let leases =
    list.flat_map(world.durable.runs, fn(run) {
      list.filter_map(run.work, fn(work) {
        case work.step {
          queue.Active(lease) -> Ok(lease)
          _ -> Error(Nil)
        }
      })
    })
  let workers = list.map(leases, queue.lease_worker)
  let serials = list.map(leases, queue.lease_serial)
  assert list.unique(workers) == workers
    as "a worker owns at most one active lease"
  assert list.unique(serials) == serials as "every live generation is unique"
  assert list.all(serials, fn(serial) { serial <= world.durable.serial })
    as "no lease outruns the serial counter"
  let holders = list.filter(world.durable.runs, holds_lane)
  assert list.length(holders) <= 1 as "one run owns the lane"
  assert list.length(
      list.filter(world.durable.runs, fn(run) {
        case run.submission {
          queue.Landing(_) -> True
          _ -> False
        }
      }),
    )
    <= 1
    as "one intent owns the submit lane"
  assert list.length(world.writes) == list.length(list.unique(world.writes))
    as "the base advances at most once per intent"
  assert in_order(world.durable.runs) as "the lane prepares in queue order"
  list.each(world.durable.runs, fn(run) { check_run(run, world) })
}

/// A queued run with live work or a landing run reserves the lane.
fn holds_lane(run: queue.Run) -> Bool {
  case run.submission {
    queue.Queued(_) ->
      !list.any(run.work, fn(work) {
        case work.step {
          queue.Failed(_, _) -> True
          _ -> False
        }
      })
    queue.Landing(_) -> True
    _ -> False
  }
}

/// Once a waiting run appears, no later lane member may be past waiting.
fn in_order(runs: List(queue.Run)) -> Bool {
  let lane =
    list.filter(runs, fn(run) {
      case run.submission {
        queue.Build -> False
        _ -> True
      }
    })
  let after_first_wait =
    list.drop_while(lane, fn(run) {
      case run.submission {
        queue.Waiting(_, _) -> False
        _ -> True
      }
    })
  list.all(after_first_wait, fn(run) {
    case run.submission {
      queue.Waiting(_, _) -> True
      _ -> False
    }
  })
}

/// Require upstream evidence for every started consumer and landed commit.
fn check_run(run: queue.Run, world: World) {
  case run.work {
    [] -> {
      // Only a waiting or unprepared group has no graph, so none ever builds.
      assert case run.submission {
        queue.Waiting(_, _) | queue.Unprepared(_, _, _) -> True
        _ -> False
      }
    }
    [producer, consumer] -> {
      // A scheduled consumer holds the resolved dependency content in its key.
      let key = case consumer.step {
        queue.Pending(_) | queue.Failed(_, _) | queue.Skipped -> None
        queue.Active(lease) -> Some(queue.lease_key(lease))
        queue.Passed(proof) | queue.Reused(proof) ->
          Some(queue.proof_key(proof))
      }
      case key {
        None -> Nil
        Some(key) -> {
          assert passing(producer.step)
          assert key.dependencies == [queue.Artifact("out", run.id <> "-out")]
        }
      }

      // A failed run starts nothing and leaves no pending action behind.
      let failed =
        list.any(run.work, fn(work) {
          case work.step {
            queue.Failed(_, _) -> True
            _ -> False
          }
        })
      assert !failed
        || list.all(run.work, fn(work) {
          case work.step {
            queue.Pending(_) -> False
            _ -> True
          }
        })
        as "a failed run holds no pending action"
      assert failed
        || list.all(run.work, fn(work) { work.step != queue.Skipped })
        as "only a failed run skips actions"
    }
    _ -> panic as "unexpected graph shape"
  }

  // Check exact-ref identity separately from the claimed landing phase.
  case run.submission {
    queue.Landed(candidate) -> {
      assert queue.candidate_commit(candidate) == run.revision
        && list.contains(world.history, run.revision)
      assert list.all(run.work, fn(work) { passing(work.step) })
    }
    queue.Queued(candidate) | queue.Landing(candidate) -> {
      assert queue.candidate_commit(candidate) == run.revision
    }
    _ -> Nil
  }
}

fn passing(step: queue.Step) -> Bool {
  case step {
    queue.Passed(_) | queue.Reused(_) -> True
    _ -> False
  }
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

/// Restore reliable delivery while preserving the existing store and Git ref.
fn heal(world: World, rounds: Int) -> World {
  // A passing candidate still needs a terminal submission outcome.
  case list.all(world.durable.runs, finished), rounds {
    True, _ -> world
    False, 0 -> panic as "reliable delivery could not drain the queue"
    False, rounds -> {
      let after =
        World(..world, clock: world.clock + 1)
        |> heal_prepare
        |> heal_slot("build")
        |> heal_slot("test")
        |> reconcile(Deliver)
      check(after)
      heal(after, rounds - 1)
    }
  }
}

/// Prepare the head of the lane from a fresh read, without faults.
fn heal_prepare(world: World) -> World {
  prepare(read(world), False)
}

/// Finish only this slot's current claim and check both transitions.
fn heal_slot(world: World, pool: String) -> World {
  let #(claimed, message) = claim(read(world), pool, Deliver)
  check(claimed)
  let finished = deliver(claimed, message)
  check(finished)
  finished
}
