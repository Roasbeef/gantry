//// The fleet snapshot round-trips through its codec, and its decoder refuses
//// values no controller produces.

import gantry_core/fleet
import gantry_core/graph
import gantry_core/queue
import gleam/json
import gleam/option.{None, Some}
import gleam/string

fn task(name: String, dependencies: List(String)) -> queue.Task {
  let action = graph.Action(name, [name], [], [], dependencies, [], 30)
  queue.Task(action, "source", "recipe-" <> name, "linux", "image")
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
    proofs: 0,
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
