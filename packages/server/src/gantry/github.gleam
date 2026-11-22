//// GitHub supplies pull request metadata. Git itself supplies and guards
//// the refs, so a change to the base between validation and push still
//// fails at the receiving server.

import gantry/config.{type GitHubTarget, DefaultBranch, RegisteredBranch}
import gantry_core/job.{type Request}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/string

/// The pull state the queue needs before preparing or submitting a candidate.
pub type Pull {
  Pull(
    branch: String,
    default_branch: String,
    head: String,
    state: String,
    readiness: Readiness,
  )
}

/// Draft PRs can still receive build-only jobs.
pub type Readiness {
  Draft
  Ready
}

/// Read one pull request over verified HTTPS without following redirects.
///
/// ## Examples
///
/// ```gleam
/// // github.read_pull(token, request)
/// ```
pub fn read_pull(token: String, pull: Request) -> Result(Pull, String) {
  let url =
    "https://api.github.com/repos/"
    <> pull.repository
    <> "/pulls/"
    <> job.pull_number(pull)
  use req <- result.try(
    request.to(url) |> result.replace_error("invalid GitHub API URL"),
  )
  let req =
    req
    |> request.set_header("authorization", "Bearer " <> token)
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_header("user-agent", "gantry")
  use response <- result.try(
    httpc.send(req) |> result.replace_error("GitHub API request failed"),
  )

  // Error response bodies may contain server-provided detail. Report the
  // status without copying an arbitrary response into the queue log.
  case response.status {
    200 ->
      json.parse(response.body, pull_decoder())
      |> result.replace_error("invalid GitHub pull response")
    status ->
      Error("GitHub pull request returned HTTP " <> int.to_string(status))
  }
}

/// Decode the handful of GitHub fields that govern admission and submission.
///
/// ## Examples
///
/// ```gleam
/// // json.parse(body, pull_decoder())
/// ```
fn pull_decoder() -> decode.Decoder(Pull) {
  use head <- decode.subfield(["head", "sha"], decode.string)
  use branch <- decode.subfield(["base", "ref"], decode.string)
  use default_branch <- decode.subfield(
    ["base", "repo", "default_branch"],
    decode.string,
  )
  use state <- decode.field("state", decode.string)
  use draft <- decode.field("draft", decode.bool)

  // Convert the wire boolean at the boundary.
  case draft {
    True -> decode.success(Pull(branch, default_branch, head, state, Draft))
    False -> decode.success(Pull(branch, default_branch, head, state, Ready))
  }
}

/// Require the operator-selected branch and exact pinned head.
///
/// ## Examples
///
/// ```gleam
/// // github.validate_pull(pull, request, "main")
/// ```
pub fn validate_pull(
  pull: Pull,
  request: Request,
  branch: String,
) -> Result(String, String) {
  case
    pull.state == "open",
    pull.branch == branch,
    pull.head == request.head,
    request.mode,
    pull.readiness
  {
    False, _, _, _, _ -> Error("pull request is closed")
    True, False, _, _, _ ->
      Error("pull request does not target the allowed branch")
    True, True, False, _, _ ->
      Error("pull request head changed; enqueue the current revision")
    True, True, True, job.Submit, Draft ->
      Error("draft pull requests can only be built")
    True, True, True, job.Submit, Ready | True, True, True, job.Build, _ ->
      Ok(pull.branch)
  }
}

/// Ask GitHub to evaluate the source pull against its configured branch
/// policy. Unknown or blocked decisions leave the landing intent unresolved.
///
/// ## Examples
///
/// ```gleam
/// // github.can_land(token, "owner/project", "main", DefaultBranch, 7, pinned_head)
/// ```
pub fn can_land(
  token: String,
  repo: String,
  branch: String,
  target: GitHubTarget,
  number: Int,
  head: String,
) -> Result(Nil, String) {
  // GraphQL takes the owner and repository as separate variables.
  use #(owner, name) <- result.try(case string.split(repo, "/") {
    [owner, name] -> Ok(#(owner, name))
    _ -> Error("invalid GitHub repository")
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
    |> result.replace_error("invalid GitHub API URL"),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer " <> token)
    |> request.set_header("user-agent", "gantry")
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use response <- result.try(
    httpc.send(req) |> result.replace_error("GitHub policy request failed"),
  )

  // Only a successful HTTP exchange can convey a merge policy observation.
  use Nil <- result.try(case response.status {
    200 -> Ok(Nil)
    status -> Error("GitHub policy returned HTTP " <> int.to_string(status))
  })

  let decoder = {
    use oid <- decode.field("headRefOid", decode.string)
    use base <- decode.field("baseRefName", decode.string)
    use state <- decode.field("state", decode.string)
    use draft <- decode.field("isDraft", decode.bool)
    use status <- decode.field("mergeStateStatus", decode.string)
    decode.success(#(oid, base, state, draft, status))
  }
  let envelope = {
    use default_branch <- decode.subfield(
      ["data", "repository", "defaultBranchRef", "name"],
      decode.string,
    )
    use pull <- decode.subfield(["data", "repository", "pullRequest"], decoder)
    decode.success(#(default_branch, pull))
  }
  use #(default_branch, observed) <- result.try(
    json.parse(response.body, envelope)
    |> result.replace_error("GitHub policy unavailable"),
  )

  // A policy change can narrow the authority of an outstanding intent.
  let allowed = case target {
    DefaultBranch -> branch == default_branch
    RegisteredBranch -> True
  }

  // Bind GitHub’s decision to the same pull state and tested head.
  case allowed && observed == #(head, branch, "OPEN", False, "CLEAN") {
    True -> Ok(Nil)
    False ->
      Error(
        "source pull revision or GitHub merge policy does not permit landing",
      )
  }
}
