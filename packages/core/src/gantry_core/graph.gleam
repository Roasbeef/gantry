//// Compile declared targets into an ordered action closure. An ordering edge
//// gates dispatch, while an input edge also supplies upstream output bytes.

import gantry_core/sandbox
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/set
import gleam/string

/// The Git metadata an action reads from its workspace. `Shallow` stages a
/// `.git` holding the action's commit with its parents cut off. The default,
/// `NoGit`, stages none and leaves the action's cache key as it was before
/// this field existed.
pub type Metadata {
  NoGit
  Shallow
}

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
    git: Metadata,
  )
}

/// An action that stages no Git metadata.
///
/// ## Examples
///
/// ```gleam
/// graph.action("check", ["make"], ["."], [], [], [], 60).git == graph.NoGit
/// ```
pub fn action(
  name name: String,
  argv argv: List(String),
  inputs inputs: List(String),
  outputs outputs: List(String),
  dependencies dependencies: List(String),
  after after: List(String),
  timeout timeout: Int,
) -> Action {
  Action(name, argv, inputs, outputs, dependencies, after, timeout, NoGit)
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
  use git <- decode.optional_field("git", NoGit, metadata_decoder())
  decode.success(Action(
    name,
    argv,
    inputs,
    outputs,
    dependencies,
    after,
    timeout,
    git,
  ))
}

/// The text whose SHA-256 is an action's recipe, the cache key's first part.
///
/// A strict action that asks for no Git metadata hashes exactly the array it
/// did before profiles and metadata existed, so its key moves only when its
/// source or policy does. A wider sandbox profile is appended by name, so a
/// proof made under it can never satisfy a strict task. An action that asks
/// for `Shallow` also hashes the commit it is built from, since the commit
/// object (parents, message, dates) is what the staged `.git` exposes. The
/// pack bytes are not hashed, because Git may encode the same objects
/// differently from run to run.
///
/// ## Examples
///
/// ```gleam
/// // graph.identity("declared", "o/r", "linux", "img", source, action,
/// //   sandbox.Strict, commit)
/// ```
pub fn identity(
  scope: String,
  repo: String,
  pool: String,
  image: String,
  source: String,
  action: Action,
  profile: sandbox.Profile,
  commit: String,
) -> String {
  let base = [
    json.string("gantry-action-v1"),
    json.string(scope),
    json.string(repo),
    json.string(pool),
    json.string(image),
    json.string(source),
    encode_action(action),
  ]

  // A strict task keeps the identity it had before profiles existed.
  let profiled = case profile {
    sandbox.Strict -> base
    sandbox.Userns -> list.append(base, [json.string(sandbox.name(profile))])
  }

  // Only a declared metadata request makes the commit part of the identity.
  let parts = case action.git {
    NoGit -> profiled
    Shallow ->
      list.append(profiled, [
        json.string("git-shallow-v1"),
        json.string(commit),
      ])
  }

  json.to_string(json.preprocessed_array(parts))
}

/// Decode the spelling of a metadata request. Only the two known words
/// decode, so a misspelling cannot silently stage nothing.
fn metadata_decoder() -> decode.Decoder(Metadata) {
  use word <- decode.then(decode.string)

  // Only the two documented spellings name a request.
  case word {
    "none" -> decode.success(NoGit)
    "shallow" -> decode.success(Shallow)
    _ -> decode.failure(NoGit, "\"none\" or \"shallow\"")
  }
}

/// Encode an action with explicit defaults for reproducible identity. The
/// `git` key is written only when it asks for metadata, so an action that
/// does not hashes to the same recipe it did before the key existed.
///
/// ## Examples
///
/// ```gleam
/// // graph.encode_action(action) |> json.to_string
/// ```
pub fn encode_action(action: Action) -> json.Json {
  // An absent key and `NoGit` encode alike, which keeps old recipes valid.
  let git = case action.git {
    NoGit -> []
    Shallow -> [#("git", json.string("shallow"))]
  }

  json.object(list.append(
    [
      #("name", json.string(action.name)),
      #("argv", json.array(action.argv, json.string)),
      #("inputs", json.array(action.inputs, json.string)),
      #("outputs", json.array(action.outputs, json.string)),
      #("deps", json.array(action.dependencies, json.string)),
      #("after", json.array(action.after, json.string)),
      #("timeout", json.int(action.timeout)),
    ],
    git,
  ))
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
