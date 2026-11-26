//// Queue persistence and agent/worker messages share typed codecs. Tagged
//// variants preserve the evidence a phase carries across a controller restart.
////
//// A decoder constructs only valid values. It rejects a lease serial or
//// attempt below one, a negative counter, a repeated run ID, and a repeated
//// action name inside a run. The durable image holds no derived data, so
//// `encode_state` omits the phase that `encode_run` adds for status output.
//// `phase_label` is the one spelling of a phase. The helper codecs cover one
//// action (`work_decoder`, `encode_work`), the proof index entry
//// (`remembered_decoder`, `encode_remembered`), and each tagged variant type.

import gantry_core/graph
import gantry_core/queue
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/set

/// Decode the fields of a queue artifact.
///
/// ## Examples
///
/// ```gleam
/// // protocol.artifact_decoder()
/// ```
pub fn artifact_decoder() -> decode.Decoder(queue.Artifact) {
  use path <- decode.field("path", decode.string)
  use digest <- decode.field("digest", decode.string)
  decode.success(queue.Artifact(path, digest))
}

/// Encode the fields of a queue artifact.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_artifact(value)
/// ```
pub fn encode_artifact(value: queue.Artifact) -> json.Json {
  json.object([
    #("path", json.string(value.path)),
    #("digest", json.string(value.digest)),
  ])
}

/// Decode the durable queue image.
///
/// ## Examples
///
/// ```gleam
/// // protocol.state_decoder()
/// ```
pub fn state_decoder() -> decode.Decoder(queue.State) {
  use serial <- decode.field("serial", counter_decoder(0))
  use runs <- decode.field(
    "runs",
    unique_decoder(decode.list(run_decoder()), fn(run: queue.Run) { run.id }),
  )
  use cache <- decode.optional_field(
    "cache",
    [],
    decode.list(remembered_decoder()),
  )
  decode.success(queue.State(serial, runs, cache))
}

/// Encode the durable queue image without derived fields.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_state(value)
/// ```
pub fn encode_state(value: queue.State) -> json.Json {
  json.object([
    #("serial", json.int(value.serial)),
    #("runs", json.array(value.runs, encode_stored_run)),
    #("cache", json.array(value.cache, encode_remembered)),
  ])
}

/// Decode the fields of a queue run. A `phase` field is derived and ignored.
///
/// ## Examples
///
/// ```gleam
/// // protocol.run_decoder()
/// ```
pub fn run_decoder() -> decode.Decoder(queue.Run) {
  use id <- decode.field("id", decode.string)
  use repo <- decode.field("repo", decode.string)
  use revision <- decode.field("revision", decode.string)
  use target <- decode.field("target", decode.string)

  use submission <- decode.field("submission", submission_decoder())
  use work <- decode.field(
    "work",
    unique_decoder(decode.list(work_decoder()), fn(work: queue.Work) {
      work.task.action.name
    }),
  )
  decode.success(queue.Run(id, repo, revision, target, submission, work))
}

/// Encode a run for status output, including its derived phase.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_run(value)
/// ```
pub fn encode_run(value: queue.Run) -> json.Json {
  json.object([
    #("id", json.string(value.id)),
    #("repo", json.string(value.repo)),
    #("revision", json.string(value.revision)),
    #("target", json.string(value.target)),
    #("submission", encode_submission(value.submission)),
    #("work", json.array(value.work, encode_work)),
    #("phase", json.string(phase_label(queue.phase(value)))),
  ])
}

/// Spell a phase for status output. Nothing parses this text back.
///
/// ## Examples
///
/// ```gleam
/// protocol.phase_label(queue.PhaseLanded) == "landed"
/// ```
pub fn phase_label(phase: queue.Phase) -> String {
  case phase {
    queue.PhaseWaiting -> "waiting"
    queue.PhasePending -> "pending"
    queue.PhasePassed -> "passed"
    queue.PhaseFailed -> "failed"
    queue.PhaseLanding -> "landing"
    queue.PhaseLanded -> "landed"
    queue.PhaseBlocked -> "blocked"
    queue.PhaseUnprepared -> "unprepared"
  }
}

/// Decode the fields of a queue assignment.
///
/// ## Examples
///
/// ```gleam
/// // protocol.assignment_decoder()
/// ```
pub fn assignment_decoder() -> decode.Decoder(queue.Assignment) {
  use run <- decode.field("run", decode.string)
  use task <- decode.field("task", task_decoder())
  use lease <- decode.field("lease", lease_decoder())
  decode.success(queue.Assignment(run, task, lease))
}

/// Encode the fields of a queue assignment.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_assignment(value)
/// ```
pub fn encode_assignment(value: queue.Assignment) -> json.Json {
  json.object([
    #("run", json.string(value.run)),
    #("task", encode_task(value.task)),
    #("lease", encode_lease(value.lease)),
  ])
}

/// Decode a tagged queue completion.
///
/// ## Examples
///
/// ```gleam
/// // protocol.completion_decoder()
/// ```
pub fn completion_decoder() -> decode.Decoder(queue.Completion) {
  use kind <- decode.field("kind", decode.string)

  // A successful report includes output files. A rejection carries its
  // diagnostic. An interruption carries nothing, since no outcome exists.
  case kind {
    "succeeded" -> {
      use files <- decode.field("files", decode.list(artifact_decoder()))
      use log <- decode.field("log", decode.string)
      decode.success(queue.Succeeded(files, log))
    }
    "rejected" -> {
      use reason <- decode.field("reason", decode.string)
      use log <- decode.field("log", decode.string)
      decode.success(queue.Rejected(reason, log))
    }
    "interrupted" -> decode.success(queue.Interrupted)
    _ ->
      decode.failure(
        queue.Rejected("invalid result", ""),
        "known completion tag",
      )
  }
}

/// Encode a tagged queue completion.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_completion(value)
/// ```
pub fn encode_completion(value: queue.Completion) -> json.Json {
  case value {
    queue.Succeeded(files, log) ->
      json.object([
        #("kind", json.string("succeeded")),
        #("files", json.array(files, encode_artifact)),
        #("log", json.string(log)),
      ])
    queue.Rejected(reason, log) ->
      json.object([
        #("kind", json.string("rejected")),
        #("reason", json.string(reason)),
        #("log", json.string(log)),
      ])
    queue.Interrupted -> json.object([#("kind", json.string("interrupted"))])
  }
}

/// Encode a run exactly as the durable image stores it.
pub fn encode_stored_run(value: queue.Run) -> json.Json {
  json.object([
    #("id", json.string(value.id)),
    #("repo", json.string(value.repo)),
    #("revision", json.string(value.revision)),
    #("target", json.string(value.target)),
    #("submission", encode_submission(value.submission)),
    #("work", json.array(value.work, encode_work)),
  ])
}

/// Decode an integer that is at least `least`.
fn counter_decoder(least: Int) -> decode.Decoder(Int) {
  use number <- decode.then(decode.int)

  // A counter below its minimum names a value that was never issued.
  case number >= least {
    True -> decode.success(number)
    False -> decode.failure(least, "an integer that is not below the minimum")
  }
}

/// Decode a list and refuse a repeated key.
fn unique_decoder(
  decoder: decode.Decoder(List(a)),
  key: fn(a) -> String,
) -> decode.Decoder(List(a)) {
  use items <- decode.then(decoder)

  // The first repeated key makes the whole list invalid.
  case distinct(list.map(items, key), set.new()) {
    True -> decode.success(items)
    False -> decode.failure([], "a list without repeated names")
  }
}

/// Check that no key appears twice, stopping at the first repeat.
fn distinct(keys: List(String), seen: set.Set(String)) -> Bool {
  case keys {
    [] -> True
    [key, ..rest] ->
      !set.contains(seen, key) && distinct(rest, set.insert(seen, key))
  }
}

/// Decode one queue action with its step.
fn work_decoder() -> decode.Decoder(queue.Work) {
  use task <- decode.field("task", task_decoder())
  use step <- decode.field("step", step_decoder())
  decode.success(queue.Work(task, step))
}

/// Encode one queue action with its step.
fn encode_work(value: queue.Work) -> json.Json {
  json.object([
    #("task", encode_task(value.task)),
    #("step", encode_step(value.step)),
  ])
}

/// Decode a tagged queue submission.
fn submission_decoder() -> decode.Decoder(queue.Submission) {
  use kind <- decode.field("kind", decode.string)

  // Each submission phase carries the evidence its transition needs.
  case kind {
    "build" -> decode.success(queue.Build)
    "waiting" -> {
      use branch <- decode.field("branch", decode.string)
      use members <- decode.field("members", decode.list(member_decoder()))
      decode.success(queue.Waiting(branch, members))
    }
    "queued" -> {
      use candidate <- decode.field("candidate", candidate_decoder())
      decode.success(queue.Queued(candidate))
    }
    "landing" -> {
      use candidate <- decode.field("candidate", candidate_decoder())
      decode.success(queue.Landing(candidate))
    }
    "landed" -> {
      use candidate <- decode.field("candidate", candidate_decoder())
      decode.success(queue.Landed(candidate))
    }
    "blocked" -> {
      use candidate <- decode.field("candidate", candidate_decoder())
      use reason <- decode.field("reason", block_decoder())
      decode.success(queue.Blocked(candidate, reason))
    }
    "unprepared" -> {
      use branch <- decode.field("branch", decode.string)
      use members <- decode.field("members", decode.list(member_decoder()))
      use reason <- decode.field("reason", prepare_failure_decoder())
      decode.success(queue.Unprepared(branch, members, reason))
    }
    _ -> decode.failure(queue.Build, "known submission tag")
  }
}

/// Encode a tagged queue submission.
fn encode_submission(value: queue.Submission) -> json.Json {
  case value {
    queue.Build -> json.object([#("kind", json.string("build"))])
    queue.Waiting(branch, members) ->
      json.object([
        #("kind", json.string("waiting")),
        #("branch", json.string(branch)),
        #("members", json.array(members, encode_member)),
      ])
    queue.Queued(candidate) ->
      json.object([
        #("kind", json.string("queued")),
        #("candidate", encode_candidate(candidate)),
      ])
    queue.Landing(candidate) ->
      json.object([
        #("kind", json.string("landing")),
        #("candidate", encode_candidate(candidate)),
      ])
    queue.Landed(candidate) ->
      json.object([
        #("kind", json.string("landed")),
        #("candidate", encode_candidate(candidate)),
      ])
    queue.Blocked(candidate, reason) ->
      json.object([
        #("kind", json.string("blocked")),
        #("candidate", encode_candidate(candidate)),
        #("reason", encode_block(reason)),
      ])
    queue.Unprepared(branch, members, reason) ->
      json.object([
        #("kind", json.string("unprepared")),
        #("branch", json.string(branch)),
        #("members", json.array(members, encode_member)),
        #("reason", encode_prepare_failure(reason)),
      ])
  }
}

/// Decode a landing block reason.
fn block_decoder() -> decode.Decoder(queue.Block) {
  use kind <- decode.field("kind", decode.string)

  // Each reason carries only the evidence its variant needs.
  case kind {
    "target_advanced" -> decode.success(queue.TargetAdvanced)
    "policy_denied" -> {
      use detail <- decode.field("detail", decode.string)
      decode.success(queue.PolicyDenied(detail))
    }
    _ -> decode.failure(queue.TargetAdvanced, "known block tag")
  }
}

/// Encode a landing block reason.
fn encode_block(value: queue.Block) -> json.Json {
  case value {
    queue.TargetAdvanced ->
      json.object([#("kind", json.string("target_advanced"))])
    queue.PolicyDenied(detail) ->
      json.object([
        #("kind", json.string("policy_denied")),
        #("detail", json.string(detail)),
      ])
  }
}

/// Decode a preparation refusal.
fn prepare_failure_decoder() -> decode.Decoder(queue.PrepareFailure) {
  use kind <- decode.field("kind", decode.string)

  // Each refusal carries only the evidence its variant needs.
  case kind {
    "member_moved" -> {
      use pull <- decode.field("pull", decode.int)
      decode.success(queue.MemberMoved(pull))
    }
    "unmergeable" -> {
      use detail <- decode.field("detail", decode.string)
      decode.success(queue.Unmergeable(detail))
    }
    "refused" -> {
      use detail <- decode.field("detail", decode.string)
      decode.success(queue.Refused(detail))
    }
    _ -> decode.failure(queue.MemberMoved(0), "known preparation tag")
  }
}

/// Encode a preparation refusal.
fn encode_prepare_failure(value: queue.PrepareFailure) -> json.Json {
  case value {
    queue.MemberMoved(pull) ->
      json.object([
        #("kind", json.string("member_moved")),
        #("pull", json.int(pull)),
      ])
    queue.Unmergeable(detail) ->
      json.object([
        #("kind", json.string("unmergeable")),
        #("detail", json.string(detail)),
      ])
    queue.Refused(detail) ->
      json.object([
        #("kind", json.string("refused")),
        #("detail", json.string(detail)),
      ])
  }
}

/// Decode a candidate and its ordered members.
fn candidate_decoder() -> decode.Decoder(queue.Candidate) {
  use branch <- decode.field("branch", decode.string)
  use base <- decode.field("base", decode.string)
  use commit <- decode.field("commit", decode.string)
  use members <- decode.field("members", decode.list(member_decoder()))
  decode.success(queue.candidate(branch, base, commit, members))
}

/// Encode a candidate and its ordered members.
fn encode_candidate(value: queue.Candidate) -> json.Json {
  json.object([
    #("branch", json.string(queue.candidate_branch(value))),
    #("base", json.string(queue.candidate_base(value))),
    #("commit", json.string(queue.candidate_commit(value))),
    #("members", json.array(queue.candidate_members(value), encode_member)),
  ])
}

/// Decode one PR number and its pinned head.
fn member_decoder() -> decode.Decoder(queue.Member) {
  use pull <- decode.field("pull", decode.int)
  use head <- decode.field("head", decode.string)
  decode.success(queue.Member(pull, head))
}

/// Encode one PR number and its pinned head.
fn encode_member(value: queue.Member) -> json.Json {
  json.object([
    #("pull", json.int(value.pull)),
    #("head", json.string(value.head)),
  ])
}

/// Decode a tagged queue step.
fn step_decoder() -> decode.Decoder(queue.Step) {
  use kind <- decode.field("kind", decode.string)

  // The stored tag determines which evidence must accompany the step.
  case kind {
    "pending" -> {
      use attempts <- decode.field("attempts", counter_decoder(0))
      decode.success(queue.Pending(attempts))
    }
    "active" -> {
      use lease <- decode.field("lease", lease_decoder())
      decode.success(queue.Active(lease))
    }
    "passed" -> {
      use proof <- decode.field("proof", proof_decoder())
      decode.success(queue.Passed(proof))
    }
    "reused" -> {
      use proof <- decode.field("proof", proof_decoder())
      decode.success(queue.Reused(proof))
    }
    "failed" -> {
      use reason <- decode.field("reason", decode.string)
      use log <- decode.field("log", decode.string)
      decode.success(queue.Failed(queue.Reported(reason), log))
    }
    "expired" -> {
      use attempts <- decode.field("attempts", counter_decoder(1))
      use log <- decode.field("log", decode.string)
      decode.success(queue.Failed(queue.LeaseExpired(attempts), log))
    }
    "skipped" -> decode.success(queue.Skipped)
    _ -> decode.failure(queue.Skipped, "known step tag")
  }
}

/// Encode a tagged queue step.
fn encode_step(value: queue.Step) -> json.Json {
  case value {
    queue.Pending(attempts) ->
      json.object([
        #("kind", json.string("pending")),
        #("attempts", json.int(attempts)),
      ])
    queue.Active(lease) ->
      json.object([
        #("kind", json.string("active")),
        #("lease", encode_lease(lease)),
      ])
    queue.Passed(proof) ->
      json.object([
        #("kind", json.string("passed")),
        #("proof", encode_proof(proof)),
      ])
    queue.Reused(proof) ->
      json.object([
        #("kind", json.string("reused")),
        #("proof", encode_proof(proof)),
      ])
    queue.Failed(queue.Reported(reason), log) ->
      json.object([
        #("kind", json.string("failed")),
        #("reason", json.string(reason)),
        #("log", json.string(log)),
      ])
    queue.Failed(queue.LeaseExpired(attempts), log) ->
      json.object([
        #("kind", json.string("expired")),
        #("attempts", json.int(attempts)),
        #("log", json.string(log)),
      ])
    queue.Skipped -> json.object([#("kind", json.string("skipped"))])
  }
}

/// Decode a verified proof of an action.
fn proof_decoder() -> decode.Decoder(queue.Proof) {
  use key <- decode.field("key", key_decoder())
  use files <- decode.field("files", decode.list(artifact_decoder()))
  use log <- decode.field("log", decode.string)
  decode.success(queue.proof(key, files, log))
}

/// Encode a verified proof of an action.
fn encode_proof(value: queue.Proof) -> json.Json {
  json.object([
    #("key", encode_key(queue.proof_key(value))),
    #("files", json.array(queue.proof_files(value), encode_artifact)),
    #("log", json.string(queue.proof_log(value))),
  ])
}

/// Decode a proof remembered for one repository.
pub fn remembered_decoder() -> decode.Decoder(queue.Remembered) {
  use repo <- decode.field("repo", decode.string)
  use proof <- decode.field("proof", proof_decoder())
  decode.success(queue.Remembered(repo, proof))
}

/// Encode a proof remembered for one repository.
pub fn encode_remembered(value: queue.Remembered) -> json.Json {
  json.object([
    #("repo", json.string(value.repo)),
    #("proof", encode_proof(value.proof)),
  ])
}

/// Decode a lease and refuse a serial or attempt that was never issued.
fn lease_decoder() -> decode.Decoder(queue.Lease) {
  use serial <- decode.field("serial", decode.int)
  use worker <- decode.field("worker", decode.string)
  use until <- decode.field("until", decode.int)
  use attempt <- decode.field("attempt", decode.int)
  use key <- decode.field("key", key_decoder())

  // The constructor refuses a serial or attempt that was never issued.
  case queue.lease(serial, worker, until, attempt, key) {
    Ok(lease) -> decode.success(lease)
    Error(Nil) ->
      decode.failure(
        queue.unleased,
        "a lease with a positive serial and attempt",
      )
  }
}

/// Encode a lease.
fn encode_lease(value: queue.Lease) -> json.Json {
  json.object([
    #("serial", json.int(queue.lease_serial(value))),
    #("worker", json.string(queue.lease_worker(value))),
    #("until", json.int(queue.lease_until(value))),
    #("attempt", json.int(queue.lease_attempt(value))),
    #("key", encode_key(queue.lease_key(value))),
  ])
}

/// Decode the recipe and resolved prerequisite files of an input key.
fn key_decoder() -> decode.Decoder(queue.Key) {
  use recipe <- decode.field("recipe", decode.string)
  use dependencies <- decode.field(
    "dependencies",
    decode.list(artifact_decoder()),
  )
  decode.success(queue.Key(recipe, dependencies))
}

/// Encode the recipe and resolved prerequisite files of an input key.
fn encode_key(value: queue.Key) -> json.Json {
  json.object([
    #("recipe", json.string(value.recipe)),
    #("dependencies", json.array(value.dependencies, encode_artifact)),
  ])
}

/// Decode an immutable task.
fn task_decoder() -> decode.Decoder(queue.Task) {
  use action <- decode.field("action", graph.action_decoder())
  use source <- decode.field("source", decode.string)
  use recipe <- decode.field("recipe", decode.string)
  use pool <- decode.field("pool", decode.string)

  use image <- decode.field("image", decode.string)
  decode.success(queue.Task(action, source, recipe, pool, image))
}

/// Encode an immutable task.
fn encode_task(value: queue.Task) -> json.Json {
  json.object([
    #("action", graph.encode_action(value.action)),
    #("source", json.string(value.source)),
    #("recipe", json.string(value.recipe)),
    #("pool", json.string(value.pool)),
    #("image", json.string(value.image)),
  ])
}
