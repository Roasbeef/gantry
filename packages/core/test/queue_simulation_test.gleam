//// Deterministic controller, worker and Git fault scheduling over the queue core.

import gantry_core/graph
import gantry_core/queue
import gleam/list
import gleam/option.{None, Some}
import gleam/result

type World {
  World(
    durable: queue.State,
    snapshot: queue.State,
    delivery: List(queue.Assignment),
    head: String,
  )
}

fn candidate(id: String) -> queue.Candidate {
  queue.Candidate("main", "base", id, [queue.Member(1, id)])
}

fn task(id: String) -> queue.Task {
  queue.Task(
    graph.Action("check", ["check"], [], [], [], [], 1),
    id,
    id,
    "pool",
    "image",
  )
}

fn start() -> World {
  let initial = queue.empty()
  let durable =
    list.fold(["a", "b"], initial, fn(state, id) {
      let assert Ok(#(state, _)) =
        queue.admit(
          state,
          id,
          "repo",
          id,
          "check",
          queue.Queued(candidate(id)),
          [task(id)],
        )
      state
    })
  World(durable, initial, [], "base")
}

fn poll(world: World, now: Int) -> World {
  let #(proposed, assignment) =
    queue.claim(world.snapshot, "worker", "pool", now)
  // A stale controller may compute a proposal but cannot send its assignment.
  case world.durable == world.snapshot {
    False -> world
    True ->
      case assignment {
        None -> World(..world, durable: proposed)
        Some(job) ->
          World(..world, durable: proposed, delivery: [job, ..world.delivery])
      }
  }
}

fn deliver(world: World, reverse: Bool) -> World {
  let messages = case reverse {
    True -> list.reverse(world.delivery)
    False -> world.delivery
  }
  case messages {
    [] -> world
    [job, ..] -> {
      let accepted =
        queue.finish(
          world.durable,
          job.run,
          job.task.action.name,
          job.lease.worker,
          job.lease.serial,
          queue.Succeeded([], job.run),
        )
      World(..world, durable: result.unwrap(accepted, world.durable))
    }
  }
}

fn tick(world: World, event: Int, clock: Int) -> World {
  case event {
    0 -> World(..world, snapshot: world.durable)
    1 | 2 -> poll(world, clock)
    3 -> deliver(world, False)
    4 -> deliver(world, True)
    5 -> {
      let #(proposed, _) = queue.landing(world.durable)
      World(..world, durable: proposed)
    }
    6 | 7 -> {
      let #(proposed, intent) = queue.landing(world.durable)
      case proposed == world.durable, intent {
        True, Some(i) if event == 6 && world.head == i.candidate.base ->
          World(..world, head: i.candidate.commit)
        True, Some(i) if event == 7 && world.head != i.candidate.base -> {
          let outcome = case world.head == i.candidate.commit {
            True -> Ok(Nil)
            False -> Error("base advanced")
          }
          let assert Ok(durable) =
            queue.record_landing(world.durable, i, outcome)
          World(..world, durable:)
        }
        _, _ -> world
      }
    }
    // Model another writer advancing the base before our effect.
    8 if world.head == "base" -> World(..world, head: "other")
    _ -> world
  }
}

fn check(world: World) {
  let active =
    list.filter_map(world.durable.runs, fn(run) {
      let assert [work] = run.work
      case work.step {
        queue.Active(lease) -> Ok(lease)
        _ -> Error(Nil)
      }
    })
  assert list.length(active) <= 1
  let owners =
    list.filter(world.durable.runs, fn(run) {
      case run.submission {
        queue.Landing(_) -> True
        _ -> False
      }
    })
  assert list.length(owners) <= 1
  list.each(world.durable.runs, fn(run) {
    let assert [work] = run.work
    case run.submission {
      queue.Landing(c) | queue.Landed(c) | queue.Blocked(c, _) -> {
        let assert queue.Passed(proof) = work.step
        assert proof.log == run.id
        assert c.commit == run.revision
      }
      _ -> Nil
    }
    case run.submission {
      queue.Landed(c) -> {
        assert world.head == c.commit
      }
      _ -> Nil
    }
  })
}

fn simulate(world: World, seed: Int, steps: Int) {
  case steps {
    0 -> Nil
    _ -> {
      let next_seed = seed * 48_271 % 2_147_483_647
      let next = tick(world, next_seed % 10, 1000 - steps)
      check(next)
      simulate(next, next_seed, steps - 1)
    }
  }
}

pub fn seeded_queue_faults_test() {
  list.each([1, 19, 73, 2026, 48_271, 999_983], fn(seed) {
    simulate(start(), seed, 1000)
  })
}

pub fn uncertain_worker_retains_slot_test() {
  let world = start()
  let assert #(leased, Some(job)) =
    queue.claim(world.durable, "worker", "pool", 0)
  let assert #(replayed, Some(retry)) =
    queue.claim(leased, "worker", "pool", 10_000)
  assert replayed == leased
  assert retry == job
  assert result.is_error(queue.finish(
    leased,
    job.run,
    "check",
    "worker",
    job.lease.serial + 1,
    queue.Succeeded([], "foreign"),
  ))
}

pub fn guarded_landing_replay_test() {
  let world = start()
  let assert Error(_) =
    queue.admit(
      world.durable,
      "x",
      "repo",
      "untested",
      "check",
      queue.Queued(candidate("different")),
      [task("untested")],
    )
  let world =
    list.fold([0, 1, 3, 5, 6], world, fn(w, event) { tick(w, event, 0) })
  let assert #(replayed, Some(intent)) = queue.landing(world.durable)
  assert replayed == world.durable
  assert world.head == intent.candidate.commit
  let assert Error(_) =
    queue.record_landing(
      replayed,
      queue.Intent(..intent, repo: "foreign"),
      Ok(Nil),
    )
  let done = tick(world, 7, 0)
  check(done)
  let assert Ok(run) = queue.find(done.durable, "a")
  assert queue.phase(run) == "landed"
}
