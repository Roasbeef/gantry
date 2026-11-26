//// Deterministic controller, worker and Git fault scheduling over the queue core.

import gantry_core/graph
import gantry_core/queue
import gantry_core/sandbox
import gleam/int
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
  queue.candidate("main", "base", id, [queue.Member(1, id)])
}

fn task(id: String) -> queue.Task {
  queue.Task(
    graph.Action("check", ["check"], [], [], [], [], 1),
    id,
    id,
    "pool",
    "image",
    sandbox.Strict,
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
          "",
          "check",
          queue.Waiting("main", [queue.Member(1, id)]),
          [],
        )
      state
    })
  World(durable, initial, [], "base")
}

/// Prepare every waiting group the core offers, as the controller would.
fn prepare(world: World) -> World {
  let durable =
    list.fold(queue.preparations(world.durable), world.durable, fn(state, p) {
      let id = queue.preparation_run(p)
      let assert Ok(next) =
        queue.record_preparation(state, p, Ok(#(candidate(id), [task(id)])))
      next
    })
  World(..world, durable:)
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
          queue.lease_worker(job.lease),
          queue.lease_serial(job.lease),
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
      let #(proposed, _) = queue.landings(world.durable)
      World(..world, durable: proposed)
    }
    6 | 7 -> {
      let #(proposed, intents) = queue.landings(world.durable)
      case proposed == world.durable, intents {
        True, [i] -> {
          let c = queue.intent_candidate(i)
          let base = queue.candidate_base(c)
          let commit = queue.candidate_commit(c)
          case
            event == 6 && world.head == base,
            event == 7 && world.head != base
          {
            True, _ -> World(..world, head: commit)
            _, True -> {
              let outcome = case world.head == commit {
                True -> Ok(Nil)
                False -> Error(queue.TargetAdvanced)
              }
              let assert Ok(durable) =
                queue.record_landing(world.durable, i, outcome)
              World(..world, durable:)
            }
            _, _ -> world
          }
        }
        _, _ -> world
      }
    }
    9 -> prepare(world)
    // Model another writer advancing the base before our effect.
    8 if world.head == "base" -> World(..world, head: "other")
    _ -> world
  }
}

fn check(world: World) {
  let active =
    list.filter_map(world.durable.runs, fn(run) {
      case run.work {
        [work] ->
          case work.step {
            queue.Active(lease) -> Ok(lease)
            _ -> Error(Nil)
          }
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
    case run.submission {
      queue.Landing(c) | queue.Landed(c) | queue.Blocked(c, _) -> {
        let assert [queue.Work(_, queue.Passed(proof))] = run.work
        assert queue.proof_log(proof) == run.id
        assert queue.candidate_commit(c) == run.revision
      }
      queue.Waiting(_, _) -> {
        assert run.work == []
      }
      _ -> Nil
    }
    case run.submission {
      queue.Landed(c) -> {
        assert world.head == queue.candidate_commit(c)
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
  let world = prepare(start())
  let assert #(leased, Some(job)) =
    queue.claim(world.durable, "worker", "pool", 0)
  let assert #(replayed, Some(retry)) =
    queue.claim(leased, "worker", "pool", 100)
  assert replayed == leased
  assert retry == job
  assert result.is_error(queue.finish(
    leased,
    job.run,
    "check",
    "worker",
    queue.lease_serial(job.lease) + 1,
    queue.Succeeded([], "foreign"),
  ))
}

pub fn lapsed_lease_is_reassigned_and_the_old_serial_is_stale_test() {
  let world = prepare(start())
  let assert #(leased, Some(job)) =
    queue.claim(world.durable, "worker", "pool", 0)

  // The deadline is the action timeout plus the slack, so 151 has not passed.
  assert queue.expire(leased, 151) == leased
  let assert #(next, Some(again)) = queue.claim(leased, "second", "pool", 1000)
  assert again.run == job.run
  assert queue.lease_serial(again.lease) > queue.lease_serial(job.lease)
  assert queue.lease_attempt(again.lease) == 2

  // The first generation can no longer publish, even for the same worker ID.
  let late =
    queue.finish(
      next,
      job.run,
      "check",
      "worker",
      queue.lease_serial(job.lease),
      queue.Succeeded([], "late"),
    )
  assert late == Error("attempt is no longer active")
  let assert Ok(_) =
    queue.finish(
      next,
      again.run,
      "check",
      "second",
      queue.lease_serial(again.lease),
      queue.Succeeded([], again.run),
    )
}

pub fn poison_action_fails_after_the_last_attempt_test() {
  let world = prepare(start())
  let #(state, last) =
    list.fold(
      list.map(list.repeat(Nil, queue.max_attempts), fn(_) { Nil })
        |> list.index_map(fn(_, i) { i + 1 }),
      #(world.durable, None),
      fn(acc, attempt) {
        let #(state, _) = acc
        let assert #(state, Some(job)) =
          queue.claim(
            state,
            "w" <> int.to_string(attempt),
            "pool",
            attempt * 1000,
          )
        #(state, Some(job))
      },
    )
  let assert Some(job) = last
  assert queue.lease_attempt(job.lease) == queue.max_attempts
  let expired = queue.expire(state, 100_000)
  let assert Ok(run) = queue.find(expired, job.run)
  assert queue.phase(run) == queue.PhaseFailed
  assert queue.terminal(run)
  assert run.work
    == [
      queue.Work(
        task(job.run),
        queue.Failed(queue.LeaseExpired(queue.max_attempts), ""),
      ),
    ]
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
    list.fold([9, 0, 1, 3, 5, 6], world, fn(w, event) { tick(w, event, 0) })
  let assert #(replayed, [intent]) = queue.landings(world.durable)
  assert replayed == world.durable
  assert world.head == queue.candidate_commit(queue.intent_candidate(intent))

  // An intent minted for another repository cannot resolve this run.
  let assert Ok(#(other, _)) =
    queue.admit(
      queue.empty(),
      "a",
      "foreign",
      "a",
      "check",
      queue.Queued(candidate("a")),
      [task("a")],
    )
  let assert #(other, Some(job)) = queue.claim(other, "worker", "pool", 0)
  let assert Ok(other) =
    queue.finish(
      other,
      "a",
      "check",
      "worker",
      queue.lease_serial(job.lease),
      queue.Succeeded([], "a"),
    )
  let assert #(_, [foreign]) = queue.landings(other)
  let assert Error(_) = queue.record_landing(replayed, foreign, Ok(Nil))
  let done = tick(world, 7, 0)
  check(done)
  let assert Ok(run) = queue.find(done.durable, "a")
  assert queue.phase(run) == queue.PhaseLanded
}
