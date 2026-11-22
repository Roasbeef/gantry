//// The runner calls the production queue through simulated controller CAS,
//// worker delivery and Git. The same boundaries drive a bounded heal.

import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

type Reply {
  Deliver
  Lose
}

type World {
  World(
    durable: queue.State,
    snapshot: queue.State,
    deliveries: List(queue.Assignment),
    intents: List(queue.Intent),
    head: String,
    writes: Int,
  )
}

/// Compare the complete final world and the externally visible event trace.
pub opaque type Report {
  Report(healed: World, trace: List(#(Int, Int, Int, String)))
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
  #(mask % 128, list.reverse(ops))
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
  let #(world, clock, trace) =
    list.fold(events, #(start(), 0, []), fn(state, op) {
      let #(before, clock, trace) = state
      observe(clock, op)
      let after = tick(before, mask, op, clock)
      check(after)
      assert after.durable.serial >= before.durable.serial
        as "lease serial is monotonic"
      #(after, clock + 1, [
        #(op, after.durable.serial, after.writes, after.head),
        ..trace
      ])
    })
  let healed = heal(world, clock, 24)
  let assert Ok(build) = queue.find(healed.durable, "build-only")
  assert queue.phase(build) == "passed" as "the build-only graph must pass"
  let submitted =
    list.filter(healed.durable.runs, fn(run) { run.id != "build-only" })
  assert list.all(submitted, fn(run) {
    list.contains(["landed", "blocked"], queue.phase(run))
  })
    as "both tested submissions must resolve"
  let assert Ok(first) = queue.find(healed.durable, "a")
  let assert Ok(second) = queue.find(healed.durable, "b")
  let assert queue.Blocked(_, "base advanced") = second.submission

  // Only an outside write before Gantry's push may block the first submission.
  case healed.head {
    "external" -> {
      let assert queue.Blocked(_, "base advanced") = first.submission
      assert healed.writes == 0
    }
    _ -> {
      let assert queue.Landed(_) = first.submission
      assert healed.writes == 1
    }
  }

  Report(healed, list.reverse(trace))
}

/// Admit two competing submissions and an independent build using two pools.
fn start() -> World {
  let empty = queue.empty()
  let durable =
    list.fold(["a", "b", "build-only"], empty, fn(state, id) {
      // The third run uses the same scheduler with build-only authority.
      let submission = case id {
        "build-only" -> queue.Build
        _ ->
          queue.Queued(
            queue.Candidate("main", "base", id, [queue.Member(1, id)]),
          )
      }

      let producer = graph.Action("build", ["build"], [], ["out"], [], [], 10)
      let consumer = graph.Action("test", ["test"], [], [], ["build"], [], 10)
      let assert Ok(#(next, _)) =
        queue.admit(state, id, "repo", id, "check", submission, [
          queue.Task(producer, id, "producer-" <> id, "build", "image"),
          queue.Task(consumer, id, "consumer-" <> id, "test", "image"),
        ])
      next
    })
  World(durable, empty, [], [], "base", 0)
}

/// Deliver an event. A disabled fault spends its event on the honest action.
fn tick(world: World, mask: Int, op: Int, clock: Int) -> World {
  // The next bit chooses the slot; the low nibble chooses the operation.
  let pool = case op / 16 % 2 {
    0 -> "build"
    _ -> "test"
  }

  // Cache stale reads until the controller polls or restarts.
  case op % 16 {
    0 | 1 -> read(world)
    2 -> claim(world, pool, clock, Deliver).0
    3 if mask % 2 == 1 -> claim(world, pool, clock, Lose).0
    3 -> claim(world, pool, clock, Deliver).0
    4 | 5 -> deliver(world, list.first(world.deliveries))
    6 if mask / 2 % 2 == 1 -> deliver(world, list.last(world.deliveries))
    6 -> deliver(world, list.first(world.deliveries))
    7 if mask / 4 % 2 == 1 ->
      wrong_receipt(world, list.first(world.deliveries), op)
    7 -> deliver(world, list.first(world.deliveries))
    8 if mask / 8 % 2 == 1 ->
      lose_result_reply(world, list.first(world.deliveries))
    8 -> deliver(world, list.first(world.deliveries))
    9 | 10 -> reconcile(world, Deliver)
    11 if mask / 16 % 2 == 1 -> reconcile(world, Lose)
    11 -> reconcile(world, Deliver)
    12 if mask / 32 % 2 == 1 -> external_advance(world)
    12 -> read(world)
    13 if mask / 64 % 2 == 1 -> restart(world)
    _ -> read(world)
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
  World(..world, snapshot:, intents: [])
}

/// Claim by CAS and deliver the assignment only after its write commits.
fn claim(
  world: World,
  pool: String,
  clock: Int,
  reply: Reply,
) -> #(World, Result(queue.Assignment, Nil)) {
  let #(next, assignment) =
    queue.claim(world.snapshot, pool <> "-worker", pool, clock)

  // Stale controller writes lose the CAS before their lease can escape.
  case world.snapshot == world.durable, assignment, reply {
    False, _, _ -> #(world, Error(Nil))
    True, Some(job), Deliver -> #(
      World(
        ..world,
        durable: next,
        deliveries: list.unique([job, ..world.deliveries]),
      ),
      Ok(job),
    )
    True, _, _ -> #(World(..world, durable: next), Error(Nil))
  }
}

/// Apply a worker report. A previously delivered receipt is still replayable.
fn deliver(world: World, message: Result(queue.Assignment, Nil)) -> World {
  case message {
    Error(Nil) -> world
    Ok(job) -> {
      let outcome =
        queue.finish(
          world.durable,
          job.run,
          job.task.action.name,
          job.lease.worker,
          job.lease.serial,
          completion(job),
        )
      World(..world, durable: result.unwrap(outcome, world.durable))
    }
  }
}

/// Lose the HTTP response after the controller processes an attempt.
fn lose_result_reply(
  world: World,
  message: Result(queue.Assignment, Nil),
) -> World {
  let applied = deliver(world, message)
  assert deliver(applied, message) == applied
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
        0 -> #(job.lease.worker, job.lease.serial + 1)
        _ -> #("unassigned-worker", job.lease.serial)
      }

      assert result.is_error(queue.finish(
        world.durable,
        job.run,
        job.task.action.name,
        worker,
        serial,
        completion(job),
      ))
        as "wrong worker or serial cannot settle an action"
      world
    }
  }
}

fn completion(job: queue.Assignment) -> queue.Completion {
  let files =
    list.map(job.task.action.outputs, queue.Artifact(_, job.run <> "-out"))
  queue.Succeeded(files, job.run <> "-" <> job.task.action.name)
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
      let updated = git_cas(World(..world, intents: []), effect)

      // A later reconciliation learns the Git outcome after a lost reply.
      case reply {
        Lose -> updated
        Deliver -> settle_landing(updated, effect)
      }
    }
    _ -> panic as "the fixture's single lane issued multiple intents"
  }
}

/// Apply the simulated expected-old-object update.
fn git_cas(world: World, effect: queue.Intent) -> World {
  let candidate = effect.candidate
  let assert Ok(run) = queue.find(world.durable, effect.run)
  let assert queue.Landing(pinned) = run.submission
  assert effect.repo == run.repo && candidate.branch == "main"
  assert pinned == candidate && run.revision == candidate.commit
  assert list.all(run.work, fn(work) { passing(work.step) })

  // An external advance makes this intent ineligible to mutate the ref.
  case world.head == candidate.base {
    False -> world
    True -> World(..world, head: candidate.commit, writes: world.writes + 1)
  }
}

/// Model a competing push before the candidate or a descendant after it.
fn external_advance(world: World) -> World {
  case world.head {
    "base" -> World(..world, head: "external")
    "a" | "b" -> World(..world, head: "after-" <> world.head)
    _ -> world
  }
}

fn settle_landing(world: World, effect: queue.Intent) -> World {
  // A descendant is evidence that the original push succeeded.
  let outcome = case reachable(effect.candidate.commit, world.head) {
    True -> Ok(Nil)
    False -> Error("base advanced")
  }

  let assert Ok(durable) = queue.record_landing(world.durable, effect, outcome)
  World(..world, durable:)
}

fn reachable(commit: String, head: String) -> Bool {
  head == commit || head == "after-" <> commit
}

/// Check slot ownership, lane exclusivity, graph order and Git identity.
fn check(world: World) {
  let lives =
    list.flat_map(world.durable.runs, fn(run) {
      list.filter_map(run.work, fn(work) {
        case work.step {
          queue.Active(lease) -> Ok(lease.worker)
          _ -> Error(Nil)
        }
      })
    })
  assert list.unique(lives) == lives as "a worker owns at most one active lease"
  let landing =
    list.filter(world.durable.runs, fn(run) {
      case run.submission {
        queue.Landing(_) -> True
        _ -> False
      }
    })
  assert list.length(landing) <= 1 as "one intent owns the submit lane"
  assert world.writes <= 1 as "the base can advance at most once"
  list.each(world.durable.runs, fn(run) { check_run(run, world.head) })
}

/// Require upstream evidence for every started consumer and landed commit.
fn check_run(run: queue.Run, head: String) {
  let assert [producer, consumer] = run.work

  // A scheduled consumer holds the resolved dependency content in its key.
  let key = case consumer.step {
    queue.Pending(_) | queue.Failed(_, _) -> None
    queue.Active(lease) -> Some(lease.key)
    queue.Passed(proof) | queue.Reused(proof) -> Some(proof.key)
  }

  case key {
    None -> Nil
    Some(key) -> {
      assert passing(producer.step)
      assert key.dependencies == [queue.Artifact("out", run.id <> "-out")]
    }
  }

  // Check exact-ref identity separately from the claimed landing phase.
  case run.submission {
    queue.Landed(candidate) -> {
      assert candidate.commit == run.revision
        && reachable(candidate.commit, head)
      assert list.all(run.work, fn(work) { passing(work.step) })
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

/// Restore reliable delivery while preserving the existing store and Git ref.
fn heal(world: World, clock: Int, rounds: Int) -> World {
  let done =
    list.all(world.durable.runs, fn(run) {
      case run.submission {
        queue.Build -> queue.phase(run) == "passed"
        queue.Landed(_) | queue.Blocked(_, _) -> True
        queue.Queued(_) | queue.Landing(_) -> False
      }
    })

  // A passing candidate still needs a terminal submission outcome.
  case done, rounds {
    True, _ -> world
    False, 0 -> panic as "reliable delivery could not drain the queue"
    False, rounds -> {
      let after =
        world
        |> heal_slot("build", clock)
        |> heal_slot("test", clock)
        |> reconcile(Deliver)
      check(after)
      heal(after, clock + 1, rounds - 1)
    }
  }
}

/// Finish only this slot's current claim and check both transitions.
fn heal_slot(world: World, pool: String, clock: Int) -> World {
  let #(claimed, message) = claim(read(world), pool, clock, Deliver)
  check(claimed)
  let finished = deliver(claimed, message)
  check(finished)
  finished
}
