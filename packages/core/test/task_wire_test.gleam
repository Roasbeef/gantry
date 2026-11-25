//// A task's input layout, Git metadata and sandbox profile survive the
//// durable codec together, and a task written before any of them existed
//// still decodes as a strict task with a whole blob and no metadata.

import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gantry_core/sandbox
import gleam/json
import gleam/option.{None, Some}
import gleam/string

const digest = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

fn task(source: queue.Input, git: option.Option(queue.Input)) -> queue.Task {
  profiled(source, git, sandbox.Strict)
}

fn profiled(
  source: queue.Input,
  git: option.Option(queue.Input),
  profile: sandbox.Profile,
) -> queue.Task {
  queue.Task(
    graph.action("check", ["true"], ["."], [], [], [], 60),
    source,
    git,
    "recipe",
    "linux",
    "image",
    profile,
  )
}

fn round(value: queue.Task) -> Result(queue.Task, json.DecodeError) {
  let assignment =
    queue.Assignment(
      "run",
      value,
      queue.lease(1, "w", 10, 1, queue.Key("recipe", []))
        |> result_unwrap,
    )
  protocol.encode_assignment(assignment)
  |> json.to_string
  |> json.parse(protocol.assignment_decoder())
  |> result_map_task
}

fn result_unwrap(value: Result(a, Nil)) -> a {
  let assert Ok(inner) = value
  inner
}

fn result_map_task(
  outcome: Result(queue.Assignment, json.DecodeError),
) -> Result(queue.Task, json.DecodeError) {
  case outcome {
    Ok(assignment) -> Ok(assignment.task)
    Error(error) -> Error(error)
  }
}

pub fn layouts_round_trip_test() {
  let cases = [
    task(queue.Whole(digest), None),
    task(queue.Chunked(digest), None),
    task(queue.Whole(digest), Some(queue.Whole(digest))),
    task(queue.Chunked(digest), Some(queue.Chunked(digest))),
    profiled(queue.Chunked(digest), Some(queue.Whole(digest)), sandbox.Userns),
  ]
  list_each(cases, fn(value) {
    let assert Ok(back) = round(value)
    assert back == value
  })
}

pub fn legacy_task_decodes_as_whole_blob_test() {
  let encoded =
    protocol.encode_assignment(queue.Assignment(
      "run",
      task(queue.Whole(digest), None),
      result_unwrap(queue.lease(1, "w", 10, 1, queue.Key("recipe", []))),
    ))
    |> json.to_string
  // Remove the fields that inputs and profiles added, as an older writer
  // never had them.
  let legacy =
    encoded
    |> string.replace("\"source_layout\":\"blob\",", "")
    |> string.replace("\"git\":null,", "")
    |> string.replace(",\"sandbox\":\"strict\"", "")
  assert !string.contains(legacy, "sandbox")
  assert legacy != encoded
  let assert Ok(assignment) = json.parse(legacy, protocol.assignment_decoder())
  assert assignment.task == task(queue.Whole(digest), None)
}

pub fn unknown_layout_is_refused_test() {
  let encoded =
    protocol.encode_assignment(queue.Assignment(
      "run",
      task(queue.Whole(digest), None),
      result_unwrap(queue.lease(1, "w", 10, 1, queue.Key("recipe", []))),
    ))
    |> json.to_string
    |> string.replace(
      "\"source_layout\":\"blob\"",
      "\"source_layout\":\"tape\"",
    )
  let assert Error(_) = json.parse(encoded, protocol.assignment_decoder())
}

fn list_each(items: List(a), f: fn(a) -> b) -> Nil {
  case items {
    [] -> Nil
    [item, ..rest] -> {
      f(item)
      list_each(rest, f)
    }
  }
}
