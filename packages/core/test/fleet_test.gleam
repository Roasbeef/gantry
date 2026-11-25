//// The fleet snapshot round-trips through its codec, and its decoder refuses
//// values no controller produces.

import gantry_core/fleet
import gantry_core/graph
import gantry_core/queue
import gantry_core/sandbox
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn task(name: String, dependencies: List(String)) -> queue.Task {
  let action = graph.action(name, [name], [], [], dependencies, [], 30)
  queue.whole_task(
    action,
    "source",
    "recipe-" <> name,
    "linux",
    "image",
    sandbox.Strict,
  )
}

/// A snapshot with one leased action, one pending dependent, a polled slot
/// and an unseen one.
fn sample() -> fleet.Fleet {
  let assert Ok(#(state, _)) =
    queue.admit(queue.empty(), "r", "repo", "rev", "check", queue.Build, [
      task("build", []),
      task("test", ["build"]),
    ])
  let assert #(state, Some(_)) = queue.claim(state, "w1", "linux", 100)
  fleet.Fleet(
    now: 120,
    slots: [
      fleet.Slot("w1", Some("gilgamesh"), fleet.Polled("linux", 100)),
      fleet.Slot("w2", None, fleet.Unseen),
    ],
    runs: state.runs,
    since: 40,
    events: [
      fleet.Granted(1, "r", "build", "w1", "linux", 100, 760),
      fleet.Settled(1, fleet.Succeeded, 110),
      fleet.Settled(2, fleet.Rejected, 115),
    ],
    samples: [fleet.Sample(100, [#("linux", 1)]), fleet.Sample(102, [])],
  )
}

pub fn snapshot_round_trips_test() {
  let value = sample()
  let text = json.to_string(fleet.encode(value))
  assert json.parse(text, fleet.decoder()) == Ok(value)
}

pub fn grant_time_follows_from_the_deadline_test() {
  let assert [run] = sample().runs
  let assert [queue.Work(task, queue.Active(lease)), _] = run.work
  assert fleet.granted(lease, task.action.timeout) == 100
}

pub fn decoder_refuses_a_negative_clock_test() {
  let text =
    json.to_string(fleet.encode(sample()))
    |> string.replace("\"now\":120", "\"now\":-1")
  let assert Error(_) = json.parse(text, fleet.decoder())
}

pub fn decoder_refuses_a_repeated_slot_test() {
  let value =
    fleet.Fleet(..sample(), slots: [
      fleet.Slot("w1", None, fleet.Unseen),
      fleet.Slot("w1", None, fleet.Unseen),
    ])
  let assert Error(_) =
    json.parse(json.to_string(fleet.encode(value)), fleet.decoder())
}

pub fn decoder_refuses_an_unknown_presence_test() {
  let text =
    json.to_string(fleet.encode(sample()))
    |> string.replace("\"kind\":\"unseen\"", "\"kind\":\"asleep\"")
  let assert Error(_) = json.parse(text, fleet.decoder())
}

pub fn decoder_refuses_an_unknown_outcome_test() {
  let text =
    json.to_string(fleet.encode(sample()))
    |> string.replace("\"outcome\":\"rejected\"", "\"outcome\":\"maybe\"")
  let assert Error(_) = json.parse(text, fleet.decoder())
}

pub fn ready_follows_the_claim_rule_test() {
  // The leased root holds its leaf back, so nothing is ready.
  let assert [run] = sample().runs
  assert fleet.ready(run) == []
  assert fleet.ready_by_pool(sample().runs) == []
  // Once the root passes, the leaf is ready in its pool.
  let assert Ok(#(state, _)) =
    queue.admit(queue.empty(), "r", "repo", "rev", "check", queue.Build, [
      task("build", []),
      task("test", ["build"]),
      task("lint", []),
    ])
  assert fleet.ready_by_pool(state.runs) == [#("linux", 2)]
  let assert #(state, Some(job)) = queue.claim(state, "w1", "linux", 0)
  let assert Ok(state) =
    queue.finish(
      state,
      "r",
      job.task.action.name,
      "w1",
      queue.lease_serial(job.lease),
      queue.Rejected("no", "log"),
    )
  // A failed run offers nothing.
  assert fleet.ready_by_pool(state.runs) == []
}

/// The pools `fleet.ready` names for a run, as a sorted set.
fn ready_pools(run: queue.Run) -> List(String) {
  fleet.ready(run)
  |> list.map(fn(work) { work.task.pool })
  |> list.unique
  |> list.sort(string.compare)
}

/// Check every run of a state against the core's own claim rule.
fn agrees(state: queue.State) -> Bool {
  list.all(state.runs, fn(run) {
    ready_pools(run) == list.sort(queue.ready_pools(run), string.compare)
  })
}

pub fn ready_agrees_with_the_core_claim_rule_test() {
  let pooled = fn(name, needs, pool) {
    let action = graph.action(name, [name], [], [], needs, [], 30)
    queue.whole_task(
      action,
      "source",
      "recipe-" <> name,
      pool,
      "image",
      sandbox.Strict,
    )
  }
  let assert Ok(#(state, _)) =
    queue.admit(queue.empty(), "fan", "repo", "rev", "check", queue.Build, [
      pooled("root", [], "linux"),
      pooled("a", ["root"], "linux"),
      pooled("b", ["root"], "gpu"),
      pooled("c", ["a", "b"], "linux"),
    ])
  let assert Ok(#(state, _)) =
    queue.admit(
      state,
      "group",
      "repo",
      "",
      "check",
      queue.Waiting("main", [queue.Member(1, "head")]),
      [],
    )
  assert agrees(state)

  // Walk the fan-out to its end, checking after every claim and result.
  let step = fn(state: queue.State, worker, pool, outcome) {
    let assert #(state, Some(job)) = queue.claim(state, worker, pool, 0)
    assert agrees(state)
    let assert Ok(state) =
      queue.finish(
        state,
        job.run,
        job.task.action.name,
        worker,
        queue.lease_serial(job.lease),
        outcome,
      )
    assert agrees(state)
    state
  }
  let state = step(state, "w1", "linux", queue.Succeeded([], "log"))
  let state = step(state, "w1", "linux", queue.Succeeded([], "log"))
  let state = step(state, "w2", "gpu", queue.Rejected("no", "log"))
  assert agrees(state)
  assert fleet.ready_by_pool(state.runs) == []
}
