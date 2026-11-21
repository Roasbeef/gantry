//// Queue persistence and agent/worker messages share typed codecs. Tagged
//// variants preserve the evidence a phase carries across a controller restart.

import gantry_core/graph
import gantry_core/queue
import gleam/dynamic/decode
import gleam/json

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

/// Decode the fields of a queue task.
///
/// ## Examples
///
/// ```gleam
/// // protocol.task_decoder()
/// ```
fn task_decoder() -> decode.Decoder(queue.Task) {
  use action <- decode.field("action", graph.action_decoder())
  use source <- decode.field("source", decode.string)
  use recipe <- decode.field("recipe", decode.string)
  use pool <- decode.field("pool", decode.string)

  use image <- decode.field("image", decode.string)
  decode.success(queue.Task(action, source, recipe, pool, image))
}

/// Encode the fields of a queue task.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_task(value)
/// ```
fn encode_task(value: queue.Task) -> json.Json {
  json.object([
    #("action", graph.encode_action(value.action)),
    #("source", json.string(value.source)),
    #("recipe", json.string(value.recipe)),
    #("pool", json.string(value.pool)),
    #("image", json.string(value.image)),
  ])
}

/// Decode the fields of a queue key.
///
/// ## Examples
///
/// ```gleam
/// // protocol.key_decoder()
/// ```
fn key_decoder() -> decode.Decoder(queue.Key) {
  use recipe <- decode.field("recipe", decode.string)
  use dependencies <- decode.field(
    "dependencies",
    decode.list(artifact_decoder()),
  )
  decode.success(queue.Key(recipe, dependencies))
}

/// Encode the fields of a queue key.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_key(value)
/// ```
fn encode_key(value: queue.Key) -> json.Json {
  json.object([
    #("recipe", json.string(value.recipe)),
    #("dependencies", json.array(value.dependencies, encode_artifact)),
  ])
}

/// Decode the fields of a queue proof.
///
/// ## Examples
///
/// ```gleam
/// // protocol.proof_decoder()
/// ```
fn proof_decoder() -> decode.Decoder(queue.Proof) {
  use key <- decode.field("key", key_decoder())
  use files <- decode.field("files", decode.list(artifact_decoder()))
  use log <- decode.field("log", decode.string)
  decode.success(queue.Proof(key, files, log))
}

/// Encode the fields of a queue proof.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_proof(value)
/// ```
fn encode_proof(value: queue.Proof) -> json.Json {
  json.object([
    #("key", encode_key(value.key)),
    #("files", json.array(value.files, encode_artifact)),
    #("log", json.string(value.log)),
  ])
}

/// Decode the fields of a queue lease.
///
/// ## Examples
///
/// ```gleam
/// // protocol.lease_decoder()
/// ```
fn lease_decoder() -> decode.Decoder(queue.Lease) {
  use serial <- decode.field("serial", decode.int)
  use worker <- decode.field("worker", decode.string)
  use until <- decode.field("until", decode.int)
  use attempt <- decode.field("attempt", decode.int)

  use key <- decode.field("key", key_decoder())
  decode.success(queue.Lease(serial, worker, until, attempt, key))
}

/// Encode the fields of a queue lease.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_lease(value)
/// ```
fn encode_lease(value: queue.Lease) -> json.Json {
  json.object([
    #("serial", json.int(value.serial)),
    #("worker", json.string(value.worker)),
    #("until", json.int(value.until)),
    #("attempt", json.int(value.attempt)),
    #("key", encode_key(value.key)),
  ])
}

/// Decode the fields of a queue work.
///
/// ## Examples
///
/// ```gleam
/// // protocol.work_decoder()
/// ```
fn work_decoder() -> decode.Decoder(queue.Work) {
  use task <- decode.field("task", task_decoder())
  use step <- decode.field("step", step_decoder())
  decode.success(queue.Work(task, step))
}

/// Encode the fields of a queue work.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_work(value)
/// ```
fn encode_work(value: queue.Work) -> json.Json {
  json.object([
    #("task", encode_task(value.task)),
    #("step", encode_step(value.step)),
  ])
}

/// Decode the fields of a queue member.
///
/// ## Examples
///
/// ```gleam
/// // protocol.member_decoder()
/// ```
fn member_decoder() -> decode.Decoder(queue.Member) {
  use pull <- decode.field("pull", decode.int)
  use head <- decode.field("head", decode.string)
  decode.success(queue.Member(pull, head))
}

/// Encode the fields of a queue member.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_member(value)
/// ```
fn encode_member(value: queue.Member) -> json.Json {
  json.object([
    #("pull", json.int(value.pull)),
    #("head", json.string(value.head)),
  ])
}

/// Decode the fields of a queue candidate.
///
/// ## Examples
///
/// ```gleam
/// // protocol.candidate_decoder()
/// ```
fn candidate_decoder() -> decode.Decoder(queue.Candidate) {
  use branch <- decode.field("branch", decode.string)
  use base <- decode.field("base", decode.string)
  use commit <- decode.field("commit", decode.string)
  use members <- decode.field("members", decode.list(member_decoder()))
  decode.success(queue.Candidate(branch, base, commit, members))
}

/// Encode the fields of a queue candidate.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_candidate(value)
/// ```
fn encode_candidate(value: queue.Candidate) -> json.Json {
  json.object([
    #("branch", json.string(value.branch)),
    #("base", json.string(value.base)),
    #("commit", json.string(value.commit)),
    #("members", json.array(value.members, encode_member)),
  ])
}

/// Decode the fields of a queue run.
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
  use work <- decode.field("work", decode.list(work_decoder()))
  decode.success(queue.Run(id, repo, revision, target, submission, work))
}

/// Encode the fields of a queue run.
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
    #("phase", json.string(queue.phase(value))),
  ])
}

/// Decode the fields of a queue state.
///
/// ## Examples
///
/// ```gleam
/// // protocol.state_decoder()
/// ```
pub fn state_decoder() -> decode.Decoder(queue.State) {
  use serial <- decode.field("serial", decode.int)
  use runs <- decode.field("runs", decode.list(run_decoder()))
  decode.success(queue.State(serial, runs))
}

/// Encode the fields of a queue state.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_state(value)
/// ```
pub fn encode_state(value: queue.State) -> json.Json {
  json.object([
    #("serial", json.int(value.serial)),
    #("runs", json.array(value.runs, encode_run)),
  ])
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

/// Decode a tagged queue step.
///
/// ## Examples
///
/// ```gleam
/// // protocol.step_decoder()
/// ```
fn step_decoder() -> decode.Decoder(queue.Step) {
  use kind <- decode.field("kind", decode.string)

  // The stored tag determines which evidence must accompany the step.
  case kind {
    "pending" -> {
      use attempts <- decode.field("attempts", decode.int)
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
      decode.success(queue.Failed(reason, log))
    }
    _ -> decode.failure(queue.Failed("invalid phase", ""), "known step tag")
  }
}

/// Encode a tagged queue step.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_step(value)
/// ```
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
    queue.Failed(reason, log) ->
      json.object([
        #("kind", json.string("failed")),
        #("reason", json.string(reason)),
        #("log", json.string(log)),
      ])
  }
}

/// Decode a tagged queue submission.
///
/// ## Examples
///
/// ```gleam
/// // protocol.submission_decoder()
/// ```
fn submission_decoder() -> decode.Decoder(queue.Submission) {
  use kind <- decode.field("kind", decode.string)

  // Each submission phase carries the candidate and any phase-specific outcome.
  case kind {
    "build" -> decode.success(queue.Build)
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
      use reason <- decode.field("reason", decode.string)
      decode.success(queue.Blocked(candidate, reason))
    }
    _ -> decode.failure(queue.Build, "known submission tag")
  }
}

/// Encode a tagged queue submission.
///
/// ## Examples
///
/// ```gleam
/// // protocol.encode_submission(value)
/// ```
fn encode_submission(value: queue.Submission) -> json.Json {
  case value {
    queue.Build ->
      json.object([
        #("kind", json.string("build")),
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
        #("reason", json.string(reason)),
      ])
  }
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

  // A successful report includes output files. A rejection carries its diagnostic.
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
  }
}
