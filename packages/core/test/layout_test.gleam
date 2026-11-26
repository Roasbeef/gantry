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

pub fn a_full_queue_refuses_a_new_run_until_retention_frees_one_test() {
  let full =
    image.apply(image.empty(), [
      layout.Put(["counter", "runs"], int.to_string(layout.max_runs)),
    ])
  let admitted =
    layout.admit(
      image.reader(full),
      "run-1",
      "repo",
      "run-1",
      "check",
      queue.Build,
      tasks("run-1", False),
    )
  let assert Error(layout.Full(_)) = admitted

  // A run that already exists is still found, because it is not new.
  let both = admit(start(), "run-2", False)
  let assert Ok(plan) =
    layout.admit(
      image.reader(both.store),
      "run-2",
      "repo",
      "run-2",
      "check",
      queue.Build,
      tasks("run-2", False),
    )
  assert layout.writes(plan) == []
}

pub fn a_prepared_candidate_is_admitted_only_into_a_free_lane_test() {
  let members = [queue.Member(1, "head")]
  let candidate = queue.candidate("main", "base", "head", members)
  let work = tasks("one", False)

  // The first candidate finds its lane free on both sides.
  let #(state, store) = {
    let assert Ok(#(next, _)) =
      queue.admit(
        queue.empty(),
        "one",
        "repo",
        "head",
        "check",
        queue.Queued(candidate),
        work,
      )
    let assert Ok(stored) =
      audit.admit(
        image.empty(),
        queue.empty(),
        "one",
        "repo",
        "head",
        "check",
        queue.Queued(candidate),
        work,
      )
    #(next, stored)
  }
  assert list.length(state.runs) == 1

  // The lane is held now, so both sides refuse a second candidate for it,
  // and the audit reports no difference between the refusals.
  let rival = queue.candidate("main", "base", "head-2", members)
  let assert Ok(unchanged) =
    audit.admit(
      store,
      state,
      "two",
      "repo",
      "head-2",
      "check",
      queue.Queued(rival),
      tasks("two", False),
    )
  assert image.keys(unchanged) == image.keys(store)
}

/// A task of a run with its own pool and recipe, for scenarios that need two.
fn task_in(
  id: String,
  name: String,
  recipe: String,
  pool: String,
) -> queue.Task {
  queue.Task(action(name, []), id, recipe, pool, "image")
}

fn claim_in(
  both: Both,
  worker: String,
  pool: String,
  now: Int,
) -> #(Both, option.Option(queue.Assignment)) {
  let #(next, assignment) = queue.claim(both.state, worker, pool, now)
  #(replay(both, audit.Claim(worker, pool, now), next), assignment)
}

pub fn a_lapsed_run_beyond_the_window_does_not_jump_the_ready_queue_test() {
  // One run proves the shared recipe, so the next eight runs are all reuses.
  let both = admit(start(), "s0", True)
  let #(both, first) = claim(both, "w0", 0)
  let assert Some(job) = first
  let both = finish(both, job)
  let both =
    numbers(1, 8)
    |> list.fold(both, fn(both, n) {
      admit(both, "x" <> int.to_string(n), True)
    })
  let both = admit(both, "y9", False)

  // The last run has one action in another pool, leased and then lapsed, so
  // a claim loads it for the expiry although it is far from the front.
  let work = [
    task_in("z10", "side", "z10-side", "other"),
    task_in("z10", "build", "z10-build", "pool"),
  ]
  let assert Ok(#(state, _)) =
    queue.admit(both.state, "z10", "repo", "z10", "check", queue.Build, work)
  let assert Ok(store) =
    audit.admit(
      both.store,
      both.state,
      "z10",
      "repo",
      "z10",
      "check",
      queue.Build,
      work,
    )
  let both = Both(state, store)
  let #(both, _) = claim_in(both, "wo", "other", 1)

  // The oldest ready run that no reuse consumed is y9, not z10.
  let #(_, offered) = claim_in(both, "w", "pool", 100_000)
  let assert Some(job) = offered
  assert job.run == "y9"
}

pub fn a_republished_proof_becomes_the_newest_test() {
  // Two runs share a recipe and are both leased before either finishes.
  let both =
    ["a", "b", "c"]
    |> list.fold(start(), fn(both, id) { admit(both, id, id != "c") })
  let #(both, first) = claim(both, "w1", 0)
  let #(both, second) = claim(both, "w2", 0)
  let #(both, third) = claim(both, "w3", 0)
  let assert #(Some(a), Some(b), Some(c)) = #(first, second, third)

  // The second run publishes an identical proof last, which `queue` moves to
  // the front, so retention would drop the others first.
  let both = finish(both, a) |> finish(c) |> finish(b)
  assert list.length(both.state.cache) == 2
}

pub fn replaying_a_lease_does_not_read_the_ready_index_test() {
  // A worker holds a lease on the newest run while twenty older runs are ready.
  let both =
    numbers(1, 21)
    |> list.fold(start(), fn(both, n) {
      admit(both, "r" <> int.to_string(n), False)
    })
  let both = {
    // Lease the newest run by making it the only ready run for a moment.
    let assert Ok(#(state, _)) =
      queue.admit(both.state, "late", "repo", "late", "check", queue.Build, [
        task_in("late", "build", "late", "solo"),
      ])
    let assert Ok(store) =
      audit.admit(
        both.store,
        both.state,
        "late",
        "repo",
        "late",
        "check",
        queue.Build,
        [task_in("late", "build", "late", "solo")],
      )
    Both(state, store)
  }
  let #(both, leased) = claim_in(both, "w", "solo", 0)
  let assert Some(job) = leased

  // The replay in the busy pool returns the same lease, and its plan expects
  // far fewer keys than the twenty ready runs it would otherwise load.
  let assert Ok(plan) = layout.claim(image.reader(both.store), "w", "pool", 1)
  assert layout.receipt(plan) == Some(job)
  assert list.length(layout.expects(plan)) < 20
}

pub fn an_in_flight_lease_survives_the_import_and_finishes_test() {
  // An earlier release leased one run and finished another.
  let both =
    ["done", "running", "waiting"]
    |> list.fold(start(), fn(both, id) { admit(both, id, False) })
  let #(both, first) = claim(both, "w1", 0)
  let assert Some(job) = first
  let both = finish(both, job)
  let #(both, second) = claim(both, "w2", 1)
  let assert Some(in_flight) = second

  // The new release imports that state, and the worker's result arrives.
  let imported = Both(both.state, audit.import_state(both.state))
  let finished = finish(imported, in_flight)
  assert list.map(finished.state.runs, queue.phase)
    == [queue.PhasePassed, queue.PhasePassed, queue.PhasePending]

  // The run that never started is claimed under the next serial.
  let #(_, third) = claim(finished, "w3", 2)
  let assert Some(next) = third
  assert next.run == "waiting"
  assert queue.lease_serial(next.lease) > queue.lease_serial(in_flight.lease)
}
