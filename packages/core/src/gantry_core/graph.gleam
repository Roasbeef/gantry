//// Compile declared targets into an ordered action closure. An ordering edge
//// gates dispatch, while an input edge also supplies upstream output bytes.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/set
import gleam/string

/// An action before source inputs and executor policy have been resolved.
pub type Action {
  Action(
    name: String,
    argv: List(String),
    inputs: List(String),
    outputs: List(String),
    dependencies: List(String),
    after: List(String),
    timeout: Int,
  )
}

/// Compile the closure of a named target from a manifest.
///
/// ## Examples
///
/// ```gleam
/// graph.compile("{}", "check") == Error("invalid build manifest")
/// ```
pub fn compile(
  manifest: String,
  target: String,
) -> Result(List(Action), String) {
  use #(actions, targets) <- result.try(
    json.parse(manifest, manifest_decoder())
    |> result.replace_error("invalid build manifest"),
  )
  use roots <- result.try(
    dict.get(targets, target) |> result.replace_error("unknown target"),
  )
  use Nil <- result.try(validate(actions, roots))
  use ordered <- result.try(order(actions, [], set.new()))

  // Walk from dependents to prerequisites so each newly selected edge is
  // encountered later in the same pass.
  let selected =
    list.fold(list.reverse(ordered), set.from_list(roots), fn(seen, action) {
      case set.contains(seen, action.name) {
        True -> list.fold(edges(action), seen, set.insert)
        False -> seen
      }
    })
  Ok(list.filter(ordered, fn(action) { set.contains(selected, action.name) }))
}

/// Check a path before it can be staged into an executor workspace.
///
/// ## Examples
///
/// ```gleam
/// graph.valid_path("../secret") == False
/// ```
pub fn valid_path(path: String) -> Bool {
  string.byte_size(path) <= 240
  && list.all(string.split(path, "/"), fn(part) {
    part != ""
    && part != "."
    && part != ".."
    && part != ".git"
    && list.all(string.to_utf_codepoints(part), fn(point) {
      let n = string.utf_codepoint_to_int(point)
      { n >= 48 && n <= 57 }
      || { n >= 65 && n <= 90 }
      || { n >= 97 && n <= 122 }
      || n == 45
      || n == 46
      || n == 95
    })
  })
}

/// Validate an ad hoc action using the same staging rules as a manifest.
///
/// ## Examples
///
/// ```gleam
/// // graph.validate_action(graph.Action("adhoc", ["make"], ["."], [], [], [], 60))
/// ```
pub fn validate_action(action: Action) -> Result(Nil, String) {
  let valid_inputs =
    action.inputs == ["."] || list.all(action.inputs, valid_path)
  let valid_outputs = list.all(action.outputs, valid_path)
  let valid_names =
    valid_path(action.name) && !string.contains(action.name, "/")

  // Only complete path components cross into Git and the filesystem.
  case
    valid_inputs
    && valid_outputs
    && valid_names
    && action.argv != []
    && list.all(action.argv, fn(arg) { !string.contains(arg, "\u{0000}") })
    && action.timeout > 0
    && action.timeout <= 3600
  {
    True -> Ok(Nil)
    False -> Error("invalid action name, argv, paths, or timeout")
  }
}

/// Decode both indexes before constructing an action graph.
///
/// ## Examples
///
/// ```gleam
/// // json.parse(manifest, manifest_decoder())
/// ```
fn manifest_decoder() {
  use actions <- decode.field("actions", decode.list(action_decoder()))
  use targets <- decode.field(
    "targets",
    decode.dict(decode.string, decode.list(decode.string)),
  )
  decode.success(#(actions, targets))
}

/// Decode the representation used by the manifest and durable queue.
///
/// ## Examples
///
/// ```gleam
/// // json.parse(body, graph.action_decoder())
/// ```
pub fn action_decoder() -> decode.Decoder(Action) {
  use name <- decode.field("name", decode.string)
  use argv <- decode.field("argv", decode.list(decode.string))
  use inputs <- decode.optional_field(
    "inputs",
    ["."],
    decode.list(decode.string),
  )
  use outputs <- decode.optional_field(
    "outputs",
    [],
    decode.list(decode.string),
  )

  use dependencies <- decode.optional_field(
    "deps",
    [],
    decode.list(decode.string),
  )
  use after <- decode.optional_field("after", [], decode.list(decode.string))
  use timeout <- decode.optional_field("timeout", 300, decode.int)
  decode.success(Action(
    name,
    argv,
    inputs,
    outputs,
    dependencies,
    after,
    timeout,
  ))
}

/// Encode an action with explicit defaults for reproducible identity.
///
/// ## Examples
///
/// ```gleam
/// // graph.encode_action(action) |> json.to_string
/// ```
pub fn encode_action(action: Action) -> json.Json {
  json.object([
    #("name", json.string(action.name)),
    #("argv", json.array(action.argv, json.string)),
    #("inputs", json.array(action.inputs, json.string)),
    #("outputs", json.array(action.outputs, json.string)),
    #("deps", json.array(action.dependencies, json.string)),
    #("after", json.array(action.after, json.string)),
    #("timeout", json.int(action.timeout)),
  ])
}

/// Reject ambiguous ownership and references before topological sorting.
///
/// ## Examples
///
/// ```gleam
/// // validate(actions, ["check"])
/// ```
fn validate(actions: List(Action), roots: List(String)) -> Result(Nil, String) {
  let names = list.map(actions, fn(action) { action.name })
  let known = set.from_list(names)
  let outputs = list.flat_map(actions, fn(action) { action.outputs })
  use _ <- result.try(list.try_map(actions, validate_action))

  let missing =
    list.append(roots, list.flat_map(actions, edges))
    |> list.any(fn(name) { !set.contains(known, name) })

  // A logical path names one producer, including directory prefixes.
  case
    !missing
    && roots != []
    && list.unique(names) == names
    && !overlapping(
      list.sort(outputs, fn(a, b) { string.compare(a <> "/", b <> "/") }),
    )
  {
    True -> Ok(Nil)
    False ->
      Error(
        "empty target, unknown action, duplicate action or overlapping output",
      )
  }
}

/// Detect duplicate paths and file-directory collisions in sorted output paths.
fn overlapping(paths: List(String)) -> Bool {
  case paths {
    [first, second, ..rest] ->
      first == second
      || string.starts_with(second, first <> "/")
      || overlapping([second, ..rest])
    [] | [_] -> False
  }
}

fn edges(action: Action) -> List(String) {
  list.append(action.dependencies, action.after)
}

/// Remove ready nodes in declaration order until only a cycle remains.
///
/// ## Examples
///
/// ```gleam
/// // order(actions, [], set.new())
/// ```
fn order(
  remaining: List(Action),
  ordered: List(Action),
  known: set.Set(String),
) -> Result(List(Action), String) {
  let #(ready, blocked) =
    list.partition(remaining, fn(action) {
      list.all(edges(action), fn(name) { set.contains(known, name) })
    })

  // No node can become ready after a pass that resolves no edge.
  case ready, blocked {
    [], [] -> Ok(ordered)
    [], [_, ..] -> Error("cycle in action graph")
    [_, ..], _ -> {
      let known =
        list.fold(ready, known, fn(seen, action) {
          set.insert(seen, action.name)
        })
      order(blocked, list.append(ordered, ready), known)
    }
  }
}
