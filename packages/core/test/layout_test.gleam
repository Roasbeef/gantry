//// Scenarios for the indexed layout that the churn simulation's small
//// fixture does not reach: more ready runs than one claim loads, a proof
//// that unlocks a run's successor, retention of runs and proofs, the
//// expectations of a commit, and the import of a whole state.

import gantry_core/graph
import gantry_core/image
import gantry_core/layout
import gantry_core/queue
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import layout_audit as audit

fn action(name: String, dependencies: List(String)) -> graph.Action {
  graph.Action(name, [name], [], [name <> ".out"], dependencies, [], 10)
}

fn task(id: String, name: String, recipe: String, deps: List(String)) {
  queue.Task(action(name, deps), id, recipe, "pool", "image")
}

fn tasks(id: String, shared: Bool) -> List(queue.Task) {
  let recipe = case shared {
    True -> "shared"
    False -> id
  }
  [task(id, "build", recipe, [])]
}

/// Both sides, kept in step, with a note of the first difference.
type Both {
  Both(state: queue.State, store: image.Image)
}

fn start() -> Both {
  Both(queue.empty(), image.empty())
}

fn admit(both: Both, id: String, shared: Bool) -> Both {
  let work = tasks(id, shared)
  let assert Ok(#(next, _)) =
    queue.admit(both.state, id, "repo", id, "check", queue.Build, work)
  let assert Ok(store) =
    audit.admit(
      both.store,
      both.state,
      id,
      "repo",
      id,
      "check",
      queue.Build,
      work,
    )
  Both(next, store)
}

fn replay(both: Both, op: audit.Op, next: queue.State) -> Both {
  let assert Ok(store) = audit.replay(both.store, both.state, op)
  Both(next, store)
}

fn claim(
  both: Both,
  worker: String,
  now: Int,
) -> #(Both, option.Option(queue.Assignment)) {
  let #(next, assignment) = queue.claim(both.state, worker, "pool", now)
  #(replay(both, audit.Claim(worker, "pool", now), next), assignment)
}

fn finish(both: Both, job: queue.Assignment) -> Both {
  let completion =
    queue.Succeeded(
      [queue.Artifact(job.task.action.name <> ".out", "digest")],
      "log",
    )
  let worker = queue.lease_worker(job.lease)
  let serial = queue.lease_serial(job.lease)
  let assert Ok(next) =
    queue.finish(both.state, job.run, "build", worker, serial, completion)
  replay(both, audit.Finish(job.run, "build", worker, serial, completion), next)
}

pub fn a_proof_reuses_more_runs_than_one_window_loads_test() {
  let both =
    numbers(1, 30)
    |> list.fold(start(), fn(both, n) {
      admit(both, "run-" <> int.to_string(n), True)
    })
  // The first claim leases run-1, and its proof makes the other 29 reusable.
  let #(both, first) = claim(both, "w", 0)
  let assert Some(job) = first
  let both = finish(both, job)
  let #(both, next) = claim(both, "w", 1)
  assert next == None
  assert list.all(both.state.runs, fn(run) {
    queue.phase(run) == queue.PhasePassed
  })
}

pub fn expired_runs_join_the_ready_runs_in_enrollment_order_test() {
  let both =
    numbers(1, 12)
    |> list.fold(start(), fn(both, n) {
      admit(both, "run-" <> int.to_string(n), False)
    })
  // Twelve distinct runs, three leased by workers that then vanish.
  let #(both, _) = claim(both, "a", 0)
  let #(both, _) = claim(both, "b", 0)
  let #(both, _) = claim(both, "c", 0)
  // Past the deadline the three lapse, and the oldest is leased again first.
  let #(both, reissued) = claim(both, "d", 10_000)
  let assert Some(job) = reissued
  assert job.run == "run-1"
  assert queue.lease_attempt(job.lease) == 2
  let #(_, replay_of_d) = claim(both, "d", 10_001)
  assert replay_of_d == Some(job)
}

pub fn retention_drops_the_oldest_runs_and_proofs_test() {
  let both =
    numbers(1, 10)
    |> list.fold(start(), fn(both, n) {
      admit(both, "run-" <> int.to_string(n), False)
    })
  let both =
    numbers(1, 10)
    |> list.fold(both, fn(both, n) {
      let #(both, leased) = claim(both, "w" <> int.to_string(n), n)
      let assert Some(job) = leased
      finish(both, job)
    })
  let retention = queue.Retention(3, 4)
  let next = queue.retain(both.state, retention)
  let both = replay(both, audit.Retain(retention), next)
  assert list.length(both.state.runs) == 3
  assert list.length(both.state.cache) == 4
  assert list.map(both.state.runs, fn(run) { run.id })
    == ["run-8", "run-9", "run-10"]
}

pub fn retention_in_small_batches_reaches_the_same_state_test() {
  let both =
    numbers(1, 10)
    |> list.fold(start(), fn(both, n) {
      admit(both, "run-" <> int.to_string(n), False)
    })
  let both =
    numbers(1, 10)
    |> list.fold(both, fn(both, n) {
      let #(both, leased) = claim(both, "w" <> int.to_string(n), n)
      let assert Some(job) = leased
      finish(both, job)
    })
  let retention = queue.Retention(3, 4)
  let batched = drain(both.store, retention)
  let assert Ok(found) = layout.materialize(image.reader(batched))
  assert found == queue.retain(both.state, retention)
}

/// Retain two at a time until the layout reports nothing more to drop.
fn drain(store: image.Image, retention: queue.Retention) -> image.Image {
  let assert Ok(plan) = layout.retain(image.reader(store), retention, 2)
  let assert Ok(next) = image.commit(store, plan)
  case layout.receipt(plan) {
    True -> drain(next, retention)
    False -> next
  }
}

pub fn a_plan_is_refused_when_a_key_it_read_changed_test() {
  let both = admit(start(), "run-1", False)
  let assert Ok(plan) = layout.claim(image.reader(both.store), "w", "pool", 0)
  // A competing claim commits first, so the first plan's expectations fail.
  let assert Ok(rival) = layout.claim(image.reader(both.store), "x", "pool", 0)
  let assert Ok(store) = image.commit(both.store, rival)
  assert image.commit(store, plan) == Error(Nil)
  // The refused commit left the store as the rival made it.
  let assert Ok(again) = layout.find(image.reader(store), "run-1")
  assert option.is_some(layout.receipt(again))
}

pub fn an_empty_poll_expects_an_empty_ready_index_test() {
  let assert Ok(plan) =
    layout.claim(image.reader(image.empty()), "w", "pool", 0)
  assert layout.writes(plan) == []
  assert layout.receipt(plan) == None
  // A run admitted after the read makes that confirmation fail.
  let both = admit(start(), "run-1", False)
  assert image.commit(both.store, plan) == Error(Nil)
}

pub fn importing_a_state_round_trips_test() {
  let both =
    numbers(1, 6)
    |> list.fold(start(), fn(both, n) {
      admit(both, "run-" <> int.to_string(n), n % 2 == 0)
    })
  let #(both, leased) = claim(both, "w", 0)
  let assert Some(job) = leased
  let both = finish(both, job)
  let #(both, _) = claim(both, "v", 5)
  let imported = audit.import_state(both.state)
  let assert Ok(found) = layout.materialize(image.reader(imported))
  assert found == both.state
  assert list.filter(image.keys(imported), fn(key) {
      key != layout.format_key()
    })
    == image.keys(both.store)
}

/// The integers from `first` to `last`.
fn numbers(first: Int, last: Int) -> List(Int) {
  list.index_map(list.repeat(0, last - first + 1), fn(_, offset) {
    first + offset
  })
}
