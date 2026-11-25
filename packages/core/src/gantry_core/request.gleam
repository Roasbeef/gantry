//// Admission requests have one owner for their rules. The controller decodes
//// an HTTP body here, and the CLI validates positional arguments, `--json`
//// payloads, and ad hoc action files here before it sends anything, so the
//// two sides cannot drift apart.
////
//// ## Flow
////
//// `parse_build` and `parse_submit` read one JSON object, reject keys the
//// request does not define, decode the typed fields, then hand them to
//// `build` or `submit`. Those smart constructors check every field and are
//// the only way to obtain a `Build` or a `Submit`. A caller holding one may
//// rely on these invariants without checking again:
////
//// | Value | Invariant |
//// | --- | --- |
//// | `Build` | ID is one path component, repository is `owner/name`, revision is a full lowercase SHA-1, target is non-empty without control characters, and any ad hoc action passes `graph.validate_action` with no dependency or ordering edges. |
//// | `Submit` | ID and repository as above, with one to sixteen distinct pull numbers in `1..9007199254740991`. |
////
//// `submit` applies the group bounds through `valid_pulls`, and
//// `parse_submit` reads its three fields through `submit_decoder`.
////
//// ## Unknown keys
////
//// Unknown keys are rejected at both levels of a build request and in a
//// submit request. A misspelled optional field, such as "pull" for "pulls"
//// or "dep" for "deps", would otherwise vanish silently and admit a request
//// the caller did not mean. The CLI schema states the same rule with
//// `additionalProperties: false`.

import gantry_core/graph
import gantry_core/job
import gleam/bool
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The largest request body, in bytes, that a controller will read.
pub const body_limit = 262_144

/// The most pull requests one ordered group may contain.
pub const pull_limit = 16

/// The largest pull number, the greatest integer JSON readers on both
/// targets represent exactly.
pub const largest_pull = 9_007_199_254_740_991

/// A validated request to plan or admit one pinned build.
pub opaque type Build {
  Build(
    id: String,
    repo: String,
    revision: String,
    target: String,
    action: Option(graph.Action),
  )
}

/// A validated request to admit an ordered group of pull requests.
pub opaque type Submit {
  Submit(id: String, repo: String, pulls: List(Int))
}

/// Why a request cannot be admitted. Each variant names the field a caller
/// must change.
pub type Rejection {
  /// The body is not a single JSON object.
  InvalidJson

  /// A field is missing or has the wrong JSON type.
  MalformedField(field: String)

  /// The object carries a key the request does not define.
  UnknownField(field: String)

  /// The run ID is not one safe path component.
  InvalidId

  /// The repository is not an `owner/name` slug.
  InvalidRepository

  /// The revision is not a full lowercase Git SHA-1.
  InvalidRevision

  /// The target is empty or contains a control character.
  InvalidTarget

  /// The ad hoc action breaks a staging rule.
  InvalidAction

  /// The ad hoc action names graph edges it has no graph to resolve.
  AdHocDependencies

  /// The pull list is empty, too long, repeated, or out of range.
  InvalidPulls
}

const build_keys = ["id", "repo", "revision", "target", "action"]

const submit_keys = ["id", "repo", "pulls"]

const action_keys = [
  "name", "argv", "inputs", "outputs", "deps", "after", "timeout", "git",
]

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Check the fields of a build request.
///
/// ## Examples
///
/// ```gleam
/// assert request.build("x", "o/p", "main", "check", None)
///   == Error(request.InvalidRevision)
/// ```
pub fn build(
  id: String,
  repo: String,
  revision: String,
  target: String,
  action: Option(graph.Action),
) -> Result(Build, Rejection) {
  use <- bool.guard(!valid_id(id), Error(InvalidId))
  use <- bool.guard(!job.valid_repository(repo), Error(InvalidRepository))
  use <- bool.guard(!job.valid_sha(revision), Error(InvalidRevision))
  use <- bool.guard(!valid_target(target), Error(InvalidTarget))

  // An isolated ad hoc action has no graph to resolve dependency edges
  // against, so an edge could only ever fail after Git work.
  use Nil <- result.try(case action {
    None -> Ok(Nil)
    Some(action) -> check_action(action)
  })

  Ok(Build(id, repo, revision, target, action))
}

/// Check the fields of an ordered group request.
///
/// ## Examples
///
/// ```gleam
/// assert request.submit("g", "o/p", [12, 12]) == Error(request.InvalidPulls)
/// ```
pub fn submit(
  id: String,
  repo: String,
  pulls: List(Int),
) -> Result(Submit, Rejection) {
  use <- bool.guard(!valid_id(id), Error(InvalidId))
  use <- bool.guard(!job.valid_repository(repo), Error(InvalidRepository))
  use <- bool.guard(!valid_pulls(pulls), Error(InvalidPulls))
  Ok(Submit(id, repo, pulls))
}

/// Check an ad hoc action against the staging rules and the edge rule.
///
/// ## Examples
///
/// ```gleam
/// // request.check_action(graph.action("a", ["make"], ["."], [], ["b"], [], 60))
/// // -> Error(request.AdHocDependencies)
/// ```
pub fn check_action(action: graph.Action) -> Result(Nil, Rejection) {
  use Nil <- result.try(
    graph.validate_action(action) |> result.replace_error(InvalidAction),
  )

  // Both edge kinds need a resolved graph to mean anything.
  case action.dependencies, action.after {
    [], [] -> Ok(Nil)
    _, _ -> Error(AdHocDependencies)
  }
}

/// Check a run ID, worker ID, or pool name: one path component without
/// a `.`, `..`, or `.git` spelling.
///
/// ## Examples
///
/// ```gleam
/// assert request.valid_id("../x") == False
/// ```
pub fn valid_id(id: String) -> Bool {
  graph.valid_path(id) && !string.contains(id, "/")
}

/// Check that a target name is non-empty and free of control characters.
fn valid_target(target: String) -> Bool {
  target != ""
  && list.all(string.to_utf_codepoints(target), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    n >= 32 && n != 127
  })
}

/// Check the group bounds: one to sixteen distinct positive pull numbers
/// that both JSON targets represent exactly.
fn valid_pulls(pulls: List(Int)) -> Bool {
  pulls != []
  && list.drop(pulls, pull_limit) == []
  && list.unique(pulls) == pulls
  && list.all(pulls, fn(pull) { pull >= 1 && pull <= largest_pull })
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Read a build request body.
///
/// ## Examples
///
/// ```gleam
/// assert request.parse_build("[]") == Error(request.InvalidJson)
/// ```
pub fn parse_build(body: String) -> Result(Build, Rejection) {
  use value <- result.try(object(body))
  use Nil <- result.try(closed(value, build_keys, ""))
  use #(id, repo, revision, target, action) <- result.try(
    decode.run(value, build_decoder()) |> result.map_error(malformed("")),
  )

  // The nested action object is closed under the same rule as the request.
  use action <- result.try(case action {
    None -> Ok(None)
    Some(raw) -> decode_action(raw, "action.") |> result.map(Some)
  })

  build(id, repo, revision, target, action)
}

/// Read a submit request body.
///
/// ## Examples
///
/// ```gleam
/// assert request.parse_submit("{\"id\":\"g\",\"repo\":\"o/p\",\"pulls\":[]}")
///   == Error(request.InvalidPulls)
/// ```
pub fn parse_submit(body: String) -> Result(Submit, Rejection) {
  use value <- result.try(object(body))
  use Nil <- result.try(closed(value, submit_keys, ""))
  use #(id, repo, pulls) <- result.try(
    decode.run(value, submit_decoder()) |> result.map_error(malformed("")),
  )
  submit(id, repo, pulls)
}

/// Read an ad hoc action file, such as the CLI's fifth positional argument.
///
/// ## Examples
///
/// ```gleam
/// assert request.parse_action("{\"name\":\"a\",\"argv\":[\"true\"],\"x\":1}")
///   == Error(request.UnknownField("x"))
/// ```
pub fn parse_action(body: String) -> Result(graph.Action, Rejection) {
  use value <- result.try(object(body))
  use action <- result.try(decode_action(value, ""))
  use Nil <- result.try(check_action(action))
  Ok(action)
}

/// Parse a body that must hold exactly one JSON object.
fn object(body: String) -> Result(Dynamic, Rejection) {
  use value <- result.try(
    json.parse(body, decode.dynamic) |> result.replace_error(InvalidJson),
  )
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.replace(value)
  |> result.replace_error(InvalidJson)
}

/// Close an object over its defined keys. The first unknown key in sorted
/// order is reported, so the same body always yields the same rejection.
fn closed(
  value: Dynamic,
  allowed: List(String),
  prefix: String,
) -> Result(Nil, Rejection) {
  use fields <- result.try(
    decode.run(value, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) {
      case prefix {
        "" -> InvalidJson
        _ -> MalformedField(string.drop_end(prefix, 1))
      }
    }),
  )
  let unknown =
    dict.keys(fields)
    |> list.filter(fn(key) { !list.contains(allowed, key) })
    |> list.sort(string.compare)

  // Report the field with its path so a nested typo is easy to locate.
  case unknown {
    [] -> Ok(Nil)
    [key, ..] -> Error(UnknownField(prefix <> key))
  }
}

/// Decode an action object after closing it over its defined keys.
fn decode_action(
  value: Dynamic,
  prefix: String,
) -> Result(graph.Action, Rejection) {
  use Nil <- result.try(closed(value, action_keys, prefix))
  decode.run(value, graph.action_decoder())
  |> result.map_error(malformed(prefix))
}

/// Name the first field a decoder could not read.
fn malformed(prefix: String) -> fn(List(decode.DecodeError)) -> Rejection {
  fn(errors) {
    case errors {
      [decode.DecodeError(path: [field, ..], ..), ..] ->
        MalformedField(prefix <> field)
      [decode.DecodeError(path: [], ..), ..] | [] ->
        MalformedField(string.drop_end(prefix, 1))
    }
  }
}

/// Read the typed fields of a build request, keeping the action raw so its
/// keys can be closed before decoding.
fn build_decoder() -> decode.Decoder(
  #(String, String, String, String, Option(Dynamic)),
) {
  use id <- decode.field("id", decode.string)
  use repo <- decode.field("repo", decode.string)
  use revision <- decode.field("revision", decode.string)
  use target <- decode.field("target", decode.string)
  use action <- decode.optional_field(
    "action",
    None,
    decode.optional(decode.dynamic),
  )
  decode.success(#(id, repo, revision, target, action))
}

fn submit_decoder() -> decode.Decoder(#(String, String, List(Int))) {
  use id <- decode.field("id", decode.string)
  use repo <- decode.field("repo", decode.string)
  use pulls <- decode.field("pulls", decode.list(decode.int))
  decode.success(#(id, repo, pulls))
}

// ---------------------------------------------------------------------------
// Encoding and accessors
// ---------------------------------------------------------------------------

/// Encode a build request with the action's defaults made explicit. The
/// encoding parses back to the same request.
///
/// ## Examples
///
/// ```gleam
/// // request.encode_build(build) |> json.to_string
/// ```
pub fn encode_build(request: Build) -> json.Json {
  json.object([
    #("id", json.string(request.id)),
    #("repo", json.string(request.repo)),
    #("revision", json.string(request.revision)),
    #("target", json.string(request.target)),
    #("action", json.nullable(request.action, graph.encode_action)),
  ])
}

/// Encode a submit request. The encoding parses back to the same request.
///
/// ## Examples
///
/// ```gleam
/// // request.encode_submit(group) |> json.to_string
/// ```
pub fn encode_submit(request: Submit) -> json.Json {
  json.object([
    #("id", json.string(request.id)),
    #("repo", json.string(request.repo)),
    #("pulls", json.array(request.pulls, json.int)),
  ])
}

/// The run ID of a build request.
pub fn build_id(request: Build) -> String {
  request.id
}

/// The repository slug of a build request, as the caller spelled it.
pub fn build_repo(request: Build) -> String {
  request.repo
}

/// The pinned revision of a build request.
pub fn revision(request: Build) -> String {
  request.revision
}

/// The declared target of a build request.
pub fn target(request: Build) -> String {
  request.target
}

/// The validated ad hoc action of a build request, if it has one.
pub fn action(request: Build) -> Option(graph.Action) {
  request.action
}

/// The run ID of a submit request.
pub fn submit_id(request: Submit) -> String {
  request.id
}

/// The repository slug of a submit request, as the caller spelled it.
pub fn submit_repo(request: Submit) -> String {
  request.repo
}

/// The ordered pull numbers of a submit request.
pub fn pulls(request: Submit) -> List(Int) {
  request.pulls
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

/// Describe a rejection for an HTTP error body or a CLI error envelope.
///
/// ## Examples
///
/// ```gleam
/// assert request.message(request.InvalidId) == "invalid identifier"
/// ```
pub fn message(rejection: Rejection) -> String {
  case rejection {
    InvalidJson -> "invalid request JSON"
    MalformedField(field) -> "missing or mistyped request field: " <> field
    UnknownField(field) -> "unknown request field: " <> field
    InvalidId -> "invalid identifier"
    InvalidRepository -> "expected an owner/name repository"
    InvalidRevision -> "expected a full lowercase Git SHA"
    InvalidTarget -> "expected a target without control characters"
    InvalidAction -> "invalid action name, argv, paths, or timeout"
    AdHocDependencies -> "ad hoc actions cannot reference graph dependencies"
    InvalidPulls ->
      "expected one to "
      <> int.to_string(pull_limit)
      <> " distinct positive PR numbers"
  }
}

/// Name the request field a rejection is about, for a CLI error envelope.
///
/// ## Examples
///
/// ```gleam
/// assert request.field(request.InvalidPulls) == "pulls"
/// ```
pub fn field(rejection: Rejection) -> String {
  case rejection {
    InvalidJson -> "body"
    MalformedField(field) | UnknownField(field) -> field
    InvalidId -> "id"
    InvalidRepository -> "repo"
    InvalidRevision -> "revision"
    InvalidTarget -> "target"
    InvalidAction | AdHocDependencies -> "action"
    InvalidPulls -> "pulls"
  }
}
