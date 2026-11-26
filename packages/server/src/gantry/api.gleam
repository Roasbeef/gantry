//// Translate requests into prepared graph proposals at the Git and store seams.

import gantry/blobs
import gantry/config.{type Config}
import gantry/fault.{type Fault}
import gantry/internal/ffi_history
import gantry/internal/ffi_presence
import gantry/prepare
import gantry/store
import gantry_core/fleet
import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gantry_core/request
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
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

/// Pin an ordered group and admit it as waiting. The controller builds its
/// candidate later, when the group heads a free lane.
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
  let id = request.submit_id(group)
  let pulls = request.pulls(group)
  use found <- result.try(store.find(id))

  // Replaying an admitted group keeps its original pins. A new group pins
  // its members' heads and waits. It is built only when it heads a free
  // lane, so a group queued behind another never builds on a stale base.
  case found {
    Some(run) -> replay_group(run, repo.name, pulls)
    None -> {
      use members <- result.try(prepare.pin(cfg, repo, group))
      admit(
        id,
        repo.name,
        "",
        repo.target,
        queue.Waiting(repo.branch, members),
        [],
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
  let members = case run.submission {
    queue.Build -> Error(Nil)
    queue.Waiting(_, members) | queue.Unprepared(_, members, _) -> Ok(members)
    queue.Queued(candidate)
    | queue.Landing(candidate)
    | queue.Landed(candidate)
    | queue.Blocked(candidate, _) -> Ok(queue.candidate_members(candidate))
  }

  // Only a run admitted as a group has members to compare.
  case members {
    Error(Nil) -> Error(fault.Conflict("run ID already has different inputs"))
    Ok(members) -> {
      use Nil <- result.try(require(
        run.repo == repo
          && list.map(members, fn(member) { member.pull }) == pulls,
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
  store.admit(id, repo, revision, target, intent, tasks)
  |> result.map(protocol.encode_run)
}

/// Return the recorded state of a run for a reconnecting agent.
///
/// ## Examples
///
/// ```gleam
/// // api.get("build-1")
/// ```
pub fn get(id: String) -> Result(json.Json, Error) {
  use found <- result.try(store.find(id))
  option.to_result(found, fault.NotFound("unknown run"))
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
  let now = unix_now()
  ffi_presence.record(worker, pool, now)
  use assignment <- result.try(store.claim(worker, pool, now))

  // Only a committed lease enters the dashboard's history, keyed by its
  // serial, so a replayed poll that returns the same lease adds nothing.
  case assignment {
    Some(granted) -> {
      let lease = granted.lease
      ffi_history.granted(
        queue.lease_serial(lease),
        granted.run,
        granted.task.action.name,
        queue.lease_worker(lease),
        granted.task.pool,
        now,
        queue.lease_until(lease),
      )
    }
    None -> Nil
  }

  Ok(option.map(assignment, protocol.encode_assignment))
}

/// Read the dashboard's snapshot: every retained run, each registered slot
/// with the latest poll this controller served for it, and the clock. It
/// changes nothing. A slot's presence is this controller's memory, so behind a
/// gateway that spreads polls over voters a slot can read as `Unseen` here.
///
/// ## Examples
///
/// ```gleam
/// // api.fleet(config)
/// ```
pub fn fleet(cfg: Config) -> Result(json.Json, Error) {
  use state <- result.try(store.read())
  let now = unix_now()

  // Each read samples the ready work, so the samples cover the times a page
  // was watching and nothing else; the page draws the gaps as unknown.
  ffi_history.sample(now, fleet.ready_by_pool(state.runs))
  ffi_history.prune(now, history_window)
  let polls =
    ffi_presence.all()
    |> list.map(fn(poll) { #(poll.0, fleet.Polled(poll.1, poll.2)) })
    |> dict.from_list
  let slots =
    list.map(cfg.workers, fn(worker) {
      let presence = dict.get(polls, worker.id) |> result.unwrap(fleet.Unseen)
      fleet.Slot(worker.id, worker.host, presence)
    })
  let grants =
    ffi_history.grants()
    |> list.map(fn(row) {
      fleet.Granted(row.0, row.1, row.2, row.3, row.4, row.5, row.6)
    })
  let settlements =
    ffi_history.settlements()
    |> list.map(fn(row) {
      let outcome = case row.1 {
        True -> fleet.Succeeded
        False -> fleet.Rejected
      }
      fleet.Settled(row.0, outcome, row.2)
    })
  let events =
    list.append(grants, settlements)
    |> list.sort(fn(a, b) { int.compare(event_time(a), event_time(b)) })
  let samples =
    ffi_history.samples()
    |> list.map(fn(row) { fleet.Sample(row.0, row.1) })
    |> list.sort(fn(a, b) { int.compare(a.at, b.at) })
  Ok(
    fleet.encode(fleet.Fleet(
      now:,
      since: int.max(ffi_history.since(), now - history_window),
      slots:,
      runs: state.runs,
      proofs: list.length(state.cache),
      events:,
      samples:,
    )),
  )
}

/// How far back the dashboard's history reaches, in seconds.
const history_window = 900

fn event_time(event: fleet.Event) -> Int {
  case event {
    fleet.Granted(at:, ..) | fleet.Settled(at:, ..) -> at
  }
}

fn unix_now() -> Int {
  let #(now, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  now
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

  use Nil <- result.try(store.finish(run, action, worker, serial, completion))

  // The result is durable now, so the dashboard's history may show it.
  ffi_history.settled(
    serial,
    case completion {
      queue.Succeeded(_, _) -> True
      queue.Rejected(_, _) -> False
    },
    unix_now(),
  )
  Ok(json.object([#("accepted", json.bool(True))]))
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
    queue.Interrupted -> []
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
