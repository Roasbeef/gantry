//// GitHub supplies pull request metadata. Git itself supplies and guards
//// the refs, so a change to the base between validation and push still
//// fails at the receiving server.
////
//// ## Flow
////
//// Admission reads a pull over REST and `validate_submission` checks it.
//// Landing reads the same pull over GraphQL, because GraphQL reports the
//// merge state authoritatively, and `landing_verdict` judges it. Both
//// decoders produce one `Pull`, so state and mergeability have one
//// spelling in the controller. Network and decoding failures are `Fault`s
//// that leave a landing intent open. A policy refusal is a `Verdict`, so
//// the submit reconciler can resolve the intent instead of retrying it.
////
//// | `landing_verdict` input | Result |
//// | --- | --- |
//// | closed or merged pull, moved head, other base, narrowed branch policy, draft, or a settled merge state other than clean | `Denied` |
//// | merge state GitHub has not computed yet | `Undetermined` |
//// | open, current, non-draft, clean, and allowed | `Permitted` |

import gantry/config.{type GitHubTarget, DefaultBranch, RegisteredBranch}
import gantry/fault.{type Fault}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/string

/// Whether the pull is still a candidate for merging.
pub type PullState {
  Open
  Closed
  Merged
}

/// Draft PRs can still receive build-only jobs.
pub type Readiness {
  Draft
  Ready
}

/// GitHub's merge state for a pull against its base.
pub type Mergeability {
  Clean
  Behind
  Blocked
  Dirty
  DraftState
  HasHooks
  Unstable

  /// GitHub has not computed the state yet, or the API omitted it.
  Undetermined
}

/// The pull state the queue needs before preparing or submitting a candidate.
pub type Pull {
  Pull(
    base: String,
    default_branch: String,
    head: String,
    state: PullState,
    readiness: Readiness,
    mergeability: Mergeability,
  )
}

/// The outcome of judging an observed pull against a landing intent.
pub type Verdict {
  Permitted
  Denied(reason: String)

  /// The merge state is not computed yet, so no decision is possible.
  Pending
}

/// Read one pull request over verified HTTPS without following redirects.
///
/// ## Examples
///
/// ```gleam
/// // github.read_pull(token, "owner/project", 7)
/// ```
pub fn read_pull(
  token: String,
  repository: String,
  number: Int,
) -> Result(Pull, Fault) {
  let url =
    "https://api.github.com/repos/"
    <> repository
    <> "/pulls/"
    <> int.to_string(number)
  use req <- result.try(
    request.to(url)
    |> result.replace_error(fault.Internal("invalid GitHub API URL")),
  )
  let req =
    req
    |> request.set_header("authorization", "Bearer " <> token)
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_header("user-agent", "gantry")
  use response <- result.try(
    httpc.send(req)
    |> result.replace_error(fault.Unavailable("GitHub API request failed")),
  )

  // Error response bodies may contain server-provided detail. Report the
  // status without copying an arbitrary response into the queue log.
  case response.status {
    200 ->
      json.parse(response.body, rest_decoder())
      |> result.replace_error(fault.Unavailable("invalid GitHub pull response"))
    404 -> Error(fault.NotFound("pull request not found"))
    status ->
      Error(fault.Unavailable(
        "GitHub pull request returned HTTP " <> int.to_string(status),
      ))
  }
}

/// Decode a REST pull response.
///
/// ## Examples
///
/// ```gleam
/// // github.parse_rest(body)
/// ```
pub fn parse_rest(body: String) -> Result(Pull, Nil) {
  json.parse(body, rest_decoder()) |> result.replace_error(Nil)
}

/// Decode a GraphQL pull response.
///
/// ## Examples
///
/// ```gleam
/// // github.parse_graphql(body)
/// ```
pub fn parse_graphql(body: String) -> Result(Pull, Nil) {
  json.parse(body, graphql_decoder()) |> result.replace_error(Nil)
}

/// Decode the REST fields that govern admission.
fn rest_decoder() -> decode.Decoder(Pull) {
  use head <- decode.subfield(["head", "sha"], decode.string)
  use base <- decode.subfield(["base", "ref"], decode.string)
  use default_branch <- decode.subfield(
    ["base", "repo", "default_branch"],
    decode.string,
  )
  use state <- decode.field("state", state_decoder())
  use draft <- decode.field("draft", readiness_decoder())
  use mergeability <- decode.optional_field(
    "mergeable_state",
    Undetermined,
    mergeability_decoder(),
  )
  decode.success(Pull(
    base:,
    default_branch:,
    head:,
    state:,
    readiness: draft,
    mergeability:,
  ))
}

/// Decode the GraphQL fields that govern landing.
fn graphql_decoder() -> decode.Decoder(Pull) {
  let pull = fn(field) { ["data", "repository", "pullRequest", field] }
  use default_branch <- decode.subfield(
    ["data", "repository", "defaultBranchRef", "name"],
    decode.string,
  )
  use head <- decode.subfield(pull("headRefOid"), decode.string)
  use base <- decode.subfield(pull("baseRefName"), decode.string)
  use state <- decode.subfield(pull("state"), state_decoder())
  use draft <- decode.subfield(pull("isDraft"), readiness_decoder())
  use mergeability <- decode.subfield(
    pull("mergeStateStatus"),
    mergeability_decoder(),
  )
  decode.success(Pull(
    base:,
    default_branch:,
    head:,
    state:,
    readiness: draft,
    mergeability:,
  ))
}

/// REST spells states in lowercase and GraphQL in uppercase.
fn state_decoder() -> decode.Decoder(PullState) {
  use text <- decode.then(decode.string)
  case string.lowercase(text) {
    "open" -> decode.success(Open)
    "closed" -> decode.success(Closed)
    "merged" -> decode.success(Merged)
    _ -> decode.failure(Open, "PullState")
  }
}

/// Convert the wire boolean into a domain variant at the boundary.
fn readiness_decoder() -> decode.Decoder(Readiness) {
  use draft <- decode.then(decode.bool)
  case draft {
    True -> decode.success(Draft)
    False -> decode.success(Ready)
  }
}

/// REST spells merge states in lowercase and GraphQL in uppercase.
fn mergeability_decoder() -> decode.Decoder(Mergeability) {
  use text <- decode.then(decode.string)
  case string.lowercase(text) {
    "clean" -> decode.success(Clean)
    "behind" -> decode.success(Behind)
    "blocked" -> decode.success(Blocked)
    "dirty" -> decode.success(Dirty)
    "draft" -> decode.success(DraftState)
    "has_hooks" -> decode.success(HasHooks)
    "unstable" -> decode.success(Unstable)
    "unknown" -> decode.success(Undetermined)
    _ -> decode.failure(Undetermined, "Mergeability")
  }
}

/// Require the operator-selected branch and exact pinned head.
///
/// ## Examples
///
/// ```gleam
/// // github.validate_submission(pull, pinned_head, "main")
/// ```
pub fn validate_submission(
  pull: Pull,
  head: String,
  branch: String,
) -> Result(String, Fault) {
  case
    pull.state == Open,
    pull.base == branch,
    pull.head == head,
    pull.readiness
  {
    False, _, _, _ -> Error(fault.Invalid("pull request is closed"))
    True, False, _, _ ->
      Error(fault.Invalid("pull request does not target the allowed branch"))
    True, True, False, _ ->
      Error(fault.Invalid(
        "pull request head changed; enqueue the current revision",
      ))
    True, True, True, Draft ->
      Error(fault.Invalid("draft pull requests can only be built"))
    True, True, True, Ready -> Ok(pull.base)
  }
}

/// Judge an observed pull against the branch, head and target policy that a
/// landing intent was tested under. A pull the policy refuses is `Denied`,
/// and one whose merge state GitHub is still computing is `Pending`.
///
/// ## Examples
///
/// ```gleam
/// // github.landing_verdict(pull, "main", pinned_head, DefaultBranch)
/// ```
pub fn landing_verdict(
  pull: Pull,
  branch: String,
  head: String,
  target: GitHubTarget,
) -> Verdict {
  // A policy change can narrow the authority of an outstanding intent.
  let allowed = case target {
    DefaultBranch -> branch == pull.default_branch
    RegisteredBranch -> True
  }

  // Check the facts that cannot recover before the merge state.
  case pull.state, pull.head == head, pull.base == branch, allowed {
    Closed, _, _, _ | Merged, _, _, _ ->
      Denied("pull request is no longer open")
    Open, False, _, _ -> Denied("pull request head moved after testing")
    Open, True, False, _ ->
      Denied("pull request no longer targets the registered branch")
    Open, True, True, False ->
      Denied("registered branch is no longer the repository default")
    Open, True, True, True ->
      case pull.readiness, pull.mergeability {
        Draft, _ -> Denied("pull request is a draft")
        Ready, Clean -> Permitted
        Ready, Undetermined -> Pending
        Ready, state ->
          Denied("GitHub merge state is " <> mergeability_name(state))
      }
  }
}

/// The GitHub spelling of a merge state, for operator-facing reasons.
fn mergeability_name(state: Mergeability) -> String {
  case state {
    Clean -> "clean"
    Behind -> "behind"
    Blocked -> "blocked"
    Dirty -> "dirty"
    DraftState -> "draft"
    HasHooks -> "has_hooks"
    Unstable -> "unstable"
    Undetermined -> "unknown"
  }
}

/// Read the pull's current state over GraphQL, where GitHub reports its
/// merge state authoritatively.
///
/// ## Examples
///
/// ```gleam
/// // github.read_landing_pull(token, "owner/project", 7)
/// ```
pub fn read_landing_pull(
  token: String,
  repo: String,
  number: Int,
) -> Result(Pull, Fault) {
  // GraphQL takes the owner and repository as separate variables.
  use #(owner, name) <- result.try(case string.split(repo, "/") {
    [owner, name] -> Ok(#(owner, name))
    _ -> Error(fault.Internal("invalid GitHub repository"))
  })

  let variables =
    json.object([
      #("owner", json.string(owner)),
      #("name", json.string(name)),
      #("number", json.int(number)),
    ])
  let body =
    json.object([
      #(
        "query",
        json.string(
          "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){defaultBranchRef{name} pullRequest(number:$number){headRefOid baseRefName state isDraft mergeStateStatus}}}",
        ),
      ),
      #("variables", variables),
    ])
    |> json.to_string

  use req <- result.try(
    request.to("https://api.github.com/graphql")
    |> result.replace_error(fault.Internal("invalid GitHub API URL")),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer " <> token)
    |> request.set_header("user-agent", "gantry")
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use response <- result.try(
    httpc.send(req)
    |> result.replace_error(fault.Unavailable("GitHub policy request failed")),
  )

  // Only a successful HTTP exchange can convey a merge policy observation.
  use Nil <- result.try(case response.status {
    200 -> Ok(Nil)
    status ->
      Error(fault.Unavailable(
        "GitHub policy returned HTTP " <> int.to_string(status),
      ))
  })

  parse_graphql(response.body)
  |> result.replace_error(fault.Unavailable("GitHub policy unavailable"))
}
