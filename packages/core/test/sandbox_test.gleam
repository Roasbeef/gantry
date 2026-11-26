//// The sandbox profile decodes totally, defaults to strict, and survives the
//// wire unchanged.

import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gantry_core/sandbox
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

fn assignment(profile: sandbox.Profile) -> queue.Assignment {
  let action = graph.Action("check", ["true"], [], [], [], [], 1)
  queue.Assignment(
    "run-1",
    queue.Task(action, "source", "recipe", "pool", "image", profile),
    queue.unleased,
  )
}

fn round_trip(value: queue.Assignment) -> Result(queue.Assignment, Nil) {
  json.to_string(protocol.encode_assignment(value))
  |> json.parse(protocol.assignment_decoder())
  |> result.replace_error(Nil)
}

/// Replace the encoded task's strict sandbox field with other text.
fn with_sandbox(text: String, replacement: String) -> String {
  string.replace(text, "\"sandbox\":\"strict\"", replacement)
}

pub fn every_profile_survives_the_wire_test() {
  list.each([sandbox.Strict, sandbox.Userns], fn(profile) {
    let value = assignment(profile)
    assert round_trip(value) == Ok(value)
  })
}

pub fn names_parse_back_to_their_profile_test() {
  list.each([sandbox.Strict, sandbox.Userns], fn(profile) {
    assert sandbox.parse(sandbox.name(profile)) == Ok(profile)
  })
}

pub fn a_task_written_before_profiles_decodes_as_strict_test() {
  let text =
    json.to_string(protocol.encode_assignment(assignment(sandbox.Strict)))
  // The field sits between the image and the end of the task object.
  let old = with_sandbox(text, "") |> string.replace(",}", "}")
  assert !string.contains(old, "sandbox")
  let assert Ok(decoded) = json.parse(old, protocol.assignment_decoder())
  assert decoded.task.sandbox == sandbox.Strict
}

pub fn an_unknown_profile_is_rejected_not_widened_test() {
  let text =
    json.to_string(protocol.encode_assignment(assignment(sandbox.Strict)))
  list.each(["\"unconfined\"", "\"USERNS\"", "\"\"", "1", "null"], fn(name) {
    let bad = with_sandbox(text, "\"sandbox\":" <> name)
    let assert Error(_) = json.parse(bad, protocol.assignment_decoder())
  })
}

pub fn the_decoder_accepts_only_the_closed_set_test() {
  assert decode.run(dynamic_string("userns"), sandbox.decoder())
    == Ok(sandbox.Userns)
  let assert Error(_) = decode.run(dynamic_string("seccomp"), sandbox.decoder())
}

fn dynamic_string(text: String) {
  let assert Ok(value) = json.parse("\"" <> text <> "\"", decode.dynamic)
  value
}
