//// Translate requests into prepared graph proposals at the Git and store seams.

import gantry/blobs
import gantry/config.{type Config}
import gantry/fault.{type Fault}
import gantry/prepare
import gantry/store
import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gantry_core/request
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/timestamp

/// The typed failure every request operation reports. `http_api` maps its
/// variant to an HTTP status.
pub type Error =
  Fault

/// Choose whether to admit or inspect a graph.
pub type BuildMode {
  Run
  Plan
}

/// Admit a pinned build, or return its plan.
///
/// ## Examples
///
/// ```gleam
/// // api.build(config, body, api.Run)
/// ```
pub fn build(
  cfg: Config,
  body: String,
  mode: BuildMode,
) -> Result(json.Json, Error) {
  use pinned <- result.try(
    request.parse_build(body)
    |> result.map_error(fn(rejection) {
      fault.Invalid(request.message(rejection))
    }),
  )
  use repo <- result.try(registered(cfg, request.build_repo(pinned)))
  use tasks <- result.try(prepare.build(cfg, repo, pinned))
  let id = request.build_id(pinned)
  let revision = request.revision(pinned)
  let target = request.target(pinned)

  // Planning returns the resolved graph. A run also records it in the queue.
  case mode {
    Plan ->
      Ok(
        json.object([
          #("revision", json.string(revision)),
          #(
            "actions",
            json.array(tasks, fn(task) { graph.encode_action(task.action) }),
          ),
        ]),
      )
    Run -> admit(id, repo.name, revision, target, queue.Build, tasks)
  }
}

/// Prepare an ordered group and commit its pinned graph.
///
/// ## Examples
///
/// ```gleam
/// // api.group(config, body)
/// ```
pub fn group(cfg: Config, body: String) -> Result(json.Json, Error) {
  use group <- result.try(
    request.parse_submit(body)
    |> result.map_error(fn(rejection) {
      fault.Invalid(request.message(rejection))
    }),
  )
  use repo <- result.try(registered(cfg, request.submit_repo(group)))
  use saved <- result.try(store.read())
  let id = request.submit_id(group)
  let pulls = request.pulls(group)

  // Replaying an admitted group keeps its original candidate and base.
  case queue.find(saved, id) {
    Ok(run) -> replay_group(run, repo.name, pulls)
    Error(Nil) -> {
      use #(candidate, tasks) <- result.try(prepare.group(cfg, repo, group))
      admit(
        id,
        repo.name,
        candidate.commit,
        repo.target,
        queue.Queued(candidate),
        tasks,
      )
    }
  }
}

/// Validate a repeated group request before revealing its recorded result.
///
/// ## Examples
///
/// ```gleam
/// // replay_group(run, "owner/project", [12, 13])
/// ```
fn replay_group(
  run: queue.Run,
  repo: String,
  pulls: List(Int),
) -> Result(json.Json, Error) {
  // A group retry must identify the same repository and ordered pull requests.
  case run.submission {
    queue.Build -> Error(fault.Conflict("run ID already has different inputs"))
    queue.Queued(candidate)
    | queue.Landing(candidate)
    | queue.Landed(candidate)
    | queue.Blocked(candidate, _) -> {
      use Nil <- result.try(require(
        run.repo == repo
          && list.map(candidate.members, fn(member) { member.pull }) == pulls,
        fault.Conflict("run ID already has different inputs"),
      ))
      Ok(protocol.encode_run(run))
    }
  }
}

/// Acknowledge admission only once the exact prepared graph is durable.
///
/// ## Examples
///
/// ```gleam
/// // admit("run-1", "owner/project", sha, "check", queue.Build, tasks)
/// ```
fn admit(
  id: String,
  repo: String,
  revision: String,
  target: String,
  intent: queue.Submission,
  tasks: List(queue.Task),
) -> Result(json.Json, Error) {
  store.change(fn(state) {
    queue.admit(state, id, repo, revision, target, intent, tasks)
    |> result.map(fn(pair) { #(pair.0, protocol.encode_run(pair.1)) })
    |> result.map_error(fault.Conflict)
  })
}

/// Return the recorded state of a run for a reconnecting agent.
///
/// ## Examples
///
/// ```gleam
/// // api.get("build-1")
/// ```
pub fn get(id: String) -> Result(json.Json, Error) {
  use state <- result.try(store.read())
  queue.find(state, id)
  |> result.replace_error(fault.NotFound("unknown run"))
  |> result.map(protocol.encode_run)
}

/// Reissue the worker's lease or durably reserve one eligible action. The
/// `identity` is the worker the request's credential names. A body that
/// names any other worker is refused before the queue is read.
///
/// ## Examples
///
/// ```gleam
/// // api.claim("worker-1", "{...}")
/// ```
pub fn claim(
  identity: String,
  body: String,
) -> Result(Option(json.Json), Error) {
  use #(worker, pool) <- result.try(parse(body, claim_decoder()))
  use Nil <- result.try(bound(identity, worker))
  use Nil <- result.try(require(
    request.valid_id(pool),
    fault.Invalid("invalid identifier"),
  ))
  let #(now, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds

  store.claim(worker, pool, now)
  |> result.map(option.map(_, protocol.encode_assignment))
}

/// Accept a result only after the worker staged its log and output bytes.
/// The `identity` is the worker the request's credential names, and the
/// result must be reported under that same worker.
///
/// ## Examples
///
/// ```gleam
/// // api.finish(config, "worker-1", body)
/// ```
pub fn finish(
  cfg: Config,
  identity: String,
  body: String,
) -> Result(json.Json, Error) {
  use #(run, action, worker, serial, completion) <- result.try(parse(
    body,
    completion_decoder(),
  ))
  use Nil <- result.try(bound(identity, worker))
  use Nil <- result.try(verify_blobs(cfg.blobs, completion))

  store.change(fn(state) {
    queue.finish(state, run, action, worker, serial, completion)
    |> result.map(fn(next) {
      #(next, json.object([#("accepted", json.bool(True))]))
    })
    |> result.map_error(fault.Conflict)
  })
}

/// Check that every referenced object exists before storing references. An
/// upload was verified against its digest when it was published, and objects
/// are immutable, so a stat is enough. Re-hashing up to 64 MiB per object on
/// every result would repeat that work.
///
/// ## Examples
///
/// ```gleam
/// // verify_blobs(shared_root, completion)
/// ```
fn verify_blobs(
  root: String,
  completion: queue.Completion,
) -> Result(Nil, Error) {
  // Verify every referenced log and each output that a successful report publishes.
  let ids = case completion {
    queue.Succeeded(files, log) -> [
      log,
      ..list.map(files, fn(file) { file.digest })
    ]
    queue.Rejected(_, log) -> [log]
  }

  list.try_each(ids, blobs.require(root, _))
}

/// Resolve a repository against the operator's case-insensitive allowlist.
fn registered(
  cfg: Config,
  repository: String,
) -> Result(config.Repository, Error) {
  dict.get(cfg.repositories, string.lowercase(repository))
  |> result.replace_error(fault.NotFound("repository is not registered"))
}

/// A worker may act only as the identity its credential registered.
fn bound(identity: String, claimed: String) -> Result(Nil, Error) {
  require(
    identity == claimed,
    fault.Forbidden("worker does not match the presented credential"),
  )
}

fn require(condition: Bool, otherwise: Error) -> Result(Nil, Error) {
  case condition {
    True -> Ok(Nil)
    False -> Error(otherwise)
  }
}

fn parse(body: String, decoder: decode.Decoder(a)) -> Result(a, Error) {
  json.parse(body, decoder)
  |> result.replace_error(fault.Invalid("invalid request JSON"))
}

fn claim_decoder() {
  use worker <- decode.field("worker", decode.string)
  use pool <- decode.field("pool", decode.string)
  decode.success(#(worker, pool))
}

/// Bind a completion report to a run, action, worker and lease serial.
fn completion_decoder() {
  use run <- decode.field("run", decode.string)
  use action <- decode.field("action", decode.string)
  use worker <- decode.field("worker", decode.string)
  use serial <- decode.field("serial", decode.int)
  use completion <- decode.field("completion", protocol.completion_decoder())
  decode.success(#(run, action, worker, serial, completion))
}
