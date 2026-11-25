//// A queue snapshot is the unit of comparison at the durable boundary.
//// The core decides claims, expiry, preparation, retention, and landing
//// intents from supplied observations. The caller performs an effect only
//// after its proposal commits. Every transition takes the snapshot it
//// expects to replace and returns a new one, so a stale controller loses
//// the compare-and-swap before any effect escapes.
////
//// ## Flow
////
//// A build is `admit`ted with a prepared graph. A submission is admitted as
//// `Waiting` with its branch and pinned PR members, and it holds no graph.
//// `preparations` names the waiting run at the head of each free lane. The
//// caller builds the candidate and graph, then `record_preparation` moves
//// exactly that run to `Queued` (or to `Unprepared` with a typed refusal).
//// A `Queued` or `Landing` run holds its lane, so a waiting run never builds
//// and no later group is prepared against a base that is about to move.
////
//// `claim` first runs `expire`, so a lease whose deadline passed returns its
//// action to `Pending` in its next attempt. The next lease takes a fresh
//// serial, so a late result for the old serial is stale. The last permitted
//// attempt fails the run with `LeaseExpired` rather than cycling a poison
//// action. A failed action turns the run's other `Pending` actions into
//// `Skipped`. `finish` accepts a result only for the live serial and worker.
//// `landings` hands each lane's intent to the reconciler and
//// `record_landing` resolves exactly that intent. `retain` drops the oldest
//// terminal runs and bounds the proof index, which keeps `cached` working.
////
//// ## Step transitions
////
//// <!-- transitions: queue.Step -->
////
//// | State | Event | Result |
//// | --- | --- | --- |
//// | `Pending` | `claim` with a ready action in the worker's pool | `Active` with a fresh serial, or `Reused` on a proof hit |
//// | `Active` | `finish` for the live serial and worker, or `expire` after the deadline | `Passed` on a matching manifest or `Failed` on a rejection. A lapsed lease becomes `Pending` with one more attempt, `Failed` at the last attempt, or `Skipped` in a failed run |
//// | `Passed` | none | terminal, indexed as a proof |
//// | `Reused` | none | terminal, a copy of an indexed proof |
//// | `Failed` | none | terminal, its run's `Pending` actions become `Skipped` |
//// | `Skipped` | none | terminal, a failure elsewhere in the run ended it |
////
//// <!-- transitions: queue.Submission -->
////
//// | State | Event | Result |
//// | --- | --- | --- |
//// | `Build` | none | never lands, terminal when its actions settle |
//// | `Waiting` | `record_preparation` for the head of a free lane | `Queued`, or `Unprepared` on a typed refusal |
//// | `Queued` | `landings` when every action passed | `Landing`, which holds the lane until resolved |
//// | `Landing` | `record_landing` for the same intent | `Landed`, or `Blocked` with a typed reason |
//// | `Landed` | none | terminal |
//// | `Blocked` | none | terminal, frees the lane |
//// | `Unprepared` | none | terminal, frees the lane |
////
//// ## Invariants
////
//// At most one run per repository and branch is `Queued` (not failed) or
//// `Landing`. A `Waiting` run has no actions. A worker holds at most one
//// `Active` lease and every lease serial is issued once. `finish` and
//// `record_landing` accept only the live generation and the exact intent.
//// Failure text is capped at `max_detail_bytes` where it is recorded.

import gantry_core/graph.{type Action}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// The most attempts an action receives before an expiry fails its run.
pub const max_attempts = 3

/// The longest externally supplied reason the core stores, in bytes.
pub const max_detail_bytes = 1024

/// Slack between an action's timeout and the lease deadline, in seconds. It
/// covers the worker's fixed work after the action exits: collecting outputs,
/// journaling, cleanup, and uploading up to the blob limit at the worker's
/// slowest accepted transfer rate. Too little slack expires a lease whose
/// valid result is still on its way.
const lease_slack = 600

/// A regular file staged by content digest.
pub type Artifact {
  Artifact(path: String, digest: String)
}

/// An action with its immutable source archive and execution policy.
pub type Task {
  Task(
    action: Action,
    source: String,
    recipe: String,
    pool: String,
    image: String,
  )
}

/// A key combines the action recipe and the resolved prerequisite files.
pub type Key {
  Key(recipe: String, dependencies: List(Artifact))
}

/// A successfully verified output manifest and its recorded diagnostics.
pub opaque type Proof {
  Proof(key: Key, files: List(Artifact), log: String)
}

/// A capability to report one action attempt.
pub opaque type Lease {
  Lease(serial: Int, worker: String, until: Int, attempt: Int, key: Key)
}

/// A placeholder that decoders return alongside a rejected lease.
pub const unleased: Lease = Lease(1, "", 0, 1, Key("", []))

/// Why an action ended without a verified result.
pub type Failure {
  /// The worker reported a rejection. The text comes from outside.
  Reported(detail: String)

  /// The last permitted attempt lost its lease before a result arrived.
  LeaseExpired(attempts: Int)
}

/// The state of a single graph action.
pub type Step {
  Pending(previous_attempts: Int)
  Active(lease: Lease)
  Passed(proof: Proof)
  Reused(proof: Proof)
  Failed(reason: Failure, log: String)
  Skipped
}

/// An immutable task with its current state.
pub type Work {
  Work(task: Task, step: Step)
}

/// One PR number and the exact head included in the integration commit.
pub type Member {
  Member(pull: Int, head: String)
}

/// A candidate with the expected old target and the ordered members.
pub opaque type Candidate {
  Candidate(branch: String, base: String, commit: String, members: List(Member))
}

/// Why a landing was refused after the candidate was tested.
pub type Block {
  /// The target ref moved outside the tested candidate.
  TargetAdvanced

  /// The provider's merge policy denied a member. The text comes from outside.
  PolicyDenied(detail: String)
}

/// Why a waiting group could not be turned into a candidate.
pub type PrepareFailure {
  /// A pinned member's head no longer matches the provider.
  MemberMoved(pull: Int)

  /// The members do not combine onto the target. The text comes from outside.
  Unmergeable(detail: String)

  /// The provider refused a member. The text comes from outside.
  Refused(detail: String)
}

/// Only an outstanding intent can authorize a remote mutation.
pub type Submission {
  Build
  Waiting(branch: String, members: List(Member))
  Queued(candidate: Candidate)
  Landing(candidate: Candidate)
  Landed(candidate: Candidate)
  Blocked(candidate: Candidate, reason: Block)
  Unprepared(branch: String, members: List(Member), reason: PrepareFailure)
}

/// The authority conferred by a completed build and committed lane claim.
pub opaque type Intent {
  Intent(run: String, repo: String, candidate: Candidate)
}

/// The identity of a waiting run whose candidate should be prepared now.
pub opaque type Preparation {
  Preparation(run: String, repo: String, branch: String, members: List(Member))
}

/// One run and the full history available to a reconnecting client.
/// `revision` is the tested commit and is empty while the run is `Waiting`.
pub type Run {
  Run(
    id: String,
    repo: String,
    revision: String,
    target: String,
    submission: Submission,
    work: List(Work),
  )
}

/// A proof remembered for reuse inside its repository.
pub type Remembered {
  Remembered(repo: String, proof: Proof)
}

/// A durable queue image. `serial` increases with every lease, and `cache`
/// holds proofs newest first so a reuse survives the pruning of their runs.
pub type State {
  State(serial: Int, runs: List(Run), cache: List(Remembered))
}

/// The bounds `retain` enforces.
pub type Retention {
  Retention(keep_runs: Int, keep_proofs: Int)
}

/// A committed lease and the work its worker can perform.
pub type Assignment {
  Assignment(run: String, task: Task, lease: Lease)
}

/// A worker's report after staging any outputs and its diagnostic log.
pub type Completion {
  Succeeded(files: List(Artifact), log: String)
  Rejected(reason: String, log: String)
}

/// The outcome of a run, for status output and policy only.
pub type Phase {
  PhaseWaiting
  PhasePending
  PhasePassed
  PhaseFailed
  PhaseLanding
  PhaseLanded
  PhaseBlocked
  PhaseUnprepared
}

// ---------------------------------------------------------------------------
// Constructors and accessors for opaque values
// ---------------------------------------------------------------------------

/// Build a proof. Codecs and tests construct one; the queue publishes its own.
pub fn proof(key: Key, files: List(Artifact), log: String) -> Proof {
  Proof(key, files, log)
}

/// The key a proof was produced for.
pub fn proof_key(proof: Proof) -> Key {
  proof.key
}

/// The verified output files of a proof.
pub fn proof_files(proof: Proof) -> List(Artifact) {
  proof.files
}

/// The recorded diagnostic of a proof.
pub fn proof_log(proof: Proof) -> String {
  proof.log
}

/// Build a lease. A serial or attempt below one was never issued.
pub fn lease(
  serial: Int,
  worker: String,
  until: Int,
  attempt: Int,
  key: Key,
) -> Result(Lease, Nil) {
  use <- bool.guard(serial < 1 || attempt < 1, Error(Nil))
  Ok(Lease(serial, worker, until, attempt, key))
}

/// The generation of a lease. No other lease shares it.
pub fn lease_serial(lease: Lease) -> Int {
  lease.serial
}

/// The worker that holds a lease.
pub fn lease_worker(lease: Lease) -> String {
  lease.worker
}

/// The time after which `expire` returns the action to `Pending`.
pub fn lease_until(lease: Lease) -> Int {
  lease.until
}

/// The attempt number of a lease, starting at one.
pub fn lease_attempt(lease: Lease) -> Int {
  lease.attempt
}

/// The input key a lease was granted for.
pub fn lease_key(lease: Lease) -> Key {
  lease.key
}

/// Build a candidate pinned to a base, a commit, and ordered members.
pub fn candidate(
  branch: String,
  base: String,
  commit: String,
  members: List(Member),
) -> Candidate {
  Candidate(branch, base, commit, members)
}

/// The target branch a candidate lands on.
pub fn candidate_branch(candidate: Candidate) -> String {
  candidate.branch
}

/// The expected old target of the landing push.
pub fn candidate_base(candidate: Candidate) -> String {
  candidate.base
}

/// The integration commit that was tested.
pub fn candidate_commit(candidate: Candidate) -> String {
  candidate.commit
}

/// The ordered PR members included in the commit.
pub fn candidate_members(candidate: Candidate) -> List(Member) {
  candidate.members
}

/// The run an intent belongs to.
pub fn intent_run(intent: Intent) -> String {
  intent.run
}

/// The repository an intent belongs to.
pub fn intent_repo(intent: Intent) -> String {
  intent.repo
}

/// The exact candidate an intent authorizes.
pub fn intent_candidate(intent: Intent) -> Candidate {
  intent.candidate
}

/// The waiting run to prepare.
pub fn preparation_run(preparation: Preparation) -> String {
  preparation.run
}

/// The repository of the waiting run.
pub fn preparation_repo(preparation: Preparation) -> String {
  preparation.repo
}

/// The branch the candidate must target.
pub fn preparation_branch(preparation: Preparation) -> String {
  preparation.branch
}

/// The PR members the candidate must include, with their pinned heads.
pub fn preparation_members(preparation: Preparation) -> List(Member) {
  preparation.members
}

// ---------------------------------------------------------------------------
// Admission and lookup
// ---------------------------------------------------------------------------

/// An empty queue image.
///
/// ## Examples
///
/// ```gleam
/// queue.empty().runs == []
/// ```
pub fn empty() -> State {
  State(0, [], [])
}

/// Admit a build, a waiting group, or a prepared candidate whose lane is free.
/// A `Waiting` submission carries no tasks. A retry with the same ID returns
/// the stored run only when its inputs are the same.
///
/// ## Examples
///
/// ```gleam
/// // queue.admit(state, "trial", "owner/project", sha, "check", queue.Build, tasks)
/// ```
pub fn admit(
  state: State,
  id: String,
  repo: String,
  revision: String,
  target: String,
  submission: Submission,
  tasks: List(Task),
) -> Result(#(State, Run), String) {
  case find(state, id) {
    // A retry may recover only the run with the original inputs.
    Ok(prior) ->
      case same_request(prior, repo, revision, target, submission, tasks) {
        True -> Ok(#(state, prior))
        False -> Error("run ID already has different inputs")
      }
    Error(Nil) -> {
      let invalid = "empty build or candidate does not match revision"

      // A waiting group carries no graph. A prepared candidate needs its lane.
      case submission, tasks {
        Build, [_, ..] ->
          Ok(append(state, id, repo, revision, target, submission, tasks))
        Waiting(_, [_, ..]), [] ->
          Ok(append(state, id, repo, "", target, submission, []))
        Queued(candidate), [_, ..] if candidate.commit == revision ->
          prepared_at_admission(state, id, repo, target, candidate, tasks)
        _, _ -> Error(invalid)
      }
    }
  }
}

/// A prepared candidate enters through the same path as a recorded preparation.
fn prepared_at_admission(
  state: State,
  id: String,
  repo: String,
  target: String,
  candidate: Candidate,
  tasks: List(Task),
) -> Result(#(State, Run), String) {
  let waiting = Waiting(candidate.branch, candidate.members)
  let #(state, run) = append(state, id, repo, "", target, waiting, [])
  use state <- result.try(prepared(state, run, candidate, tasks))
  find(state, id)
  |> result.map(fn(run) { #(state, run) })
  |> result.replace_error("unknown run")
}

/// Append one new run in enrollment order.
fn append(
  state: State,
  id: String,
  repo: String,
  revision: String,
  target: String,
  submission: Submission,
  tasks: List(Task),
) -> #(State, Run) {
  let run =
    Run(
      id,
      repo,
      revision,
      target,
      submission,
      list.map(tasks, fn(task) { Work(task, Pending(0)) }),
    )
  #(State(..state, runs: list.append(state.runs, [run])), run)
}

/// Compare a retry with the stored run. The pins and candidate survive every
/// later phase, so a retry after preparation or landing still matches.
fn same_request(
  prior: Run,
  repo: String,
  revision: String,
  target: String,
  submission: Submission,
  tasks: List(Task),
) -> Bool {
  prior.repo == repo
  && prior.target == target
  && case submission {
    Build ->
      prior.submission == Build
      && prior.revision == revision
      && list.map(prior.work, fn(work) { work.task }) == tasks
    Waiting(branch, members) ->
      pins(prior.submission) == Some(#(branch, members))
    Queued(candidate) ->
      prior.revision == revision
      && candidate_of(prior.submission) == Some(candidate)
      && list.map(prior.work, fn(work) { work.task }) == tasks
    Landing(_) | Landed(_) | Blocked(_, _) | Unprepared(_, _, _) -> False
  }
}

/// The branch and members a submission was admitted with.
fn pins(submission: Submission) -> Option(#(String, List(Member))) {
  case submission {
    Build -> None
    Waiting(branch, members) | Unprepared(branch, members, _) ->
      Some(#(branch, members))
    Queued(candidate)
    | Landing(candidate)
    | Landed(candidate)
    | Blocked(candidate, _) -> Some(#(candidate.branch, candidate.members))
  }
}

/// The candidate of a prepared submission.
fn candidate_of(submission: Submission) -> Option(Candidate) {
  case submission {
    Build | Waiting(_, _) | Unprepared(_, _, _) -> None
    Queued(candidate)
    | Landing(candidate)
    | Landed(candidate)
    | Blocked(candidate, _) -> Some(candidate)
  }
}

/// Look up a prior run by its stable request ID.
///
/// ## Examples
///
/// ```gleam
/// queue.find(queue.empty(), "unknown") == Error(Nil)
/// ```
pub fn find(state: State, id: String) -> Result(Run, Nil) {
  list.find(state.runs, fn(run) { run.id == id })
}

// ---------------------------------------------------------------------------
// Preparation of waiting groups
// ---------------------------------------------------------------------------

/// The waiting run at the head of each free lane, in queue order. The caller
/// builds each candidate and graph and records it with `record_preparation`.
/// A lane held by a queued or landing run offers nothing, so a group is never
/// prepared against a base that is about to move.
///
/// ## Examples
///
/// ```gleam
/// queue.preparations(queue.empty()) == []
/// ```
pub fn preparations(state: State) -> List(Preparation) {
  let held =
    list.fold(state.runs, set.new(), fn(lanes, run) {
      case holder_branch(run) {
        Ok(branch) -> set.insert(lanes, #(run.repo, branch))
        Error(Nil) -> lanes
      }
    })
  let #(_, found) =
    list.fold(state.runs, #(held, []), fn(acc, run) {
      case run.submission {
        Waiting(branch, members) -> head_of_lane(acc, run, branch, members)
        Build
        | Queued(_)
        | Landing(_)
        | Landed(_)
        | Blocked(_, _)
        | Unprepared(_, _, _) -> acc
      }
    })
  list.reverse(found)
}

/// Offer the first waiting run of a lane that no earlier run holds or heads.
fn head_of_lane(
  acc: #(Set(#(String, String)), List(Preparation)),
  run: Run,
  branch: String,
  members: List(Member),
) -> #(Set(#(String, String)), List(Preparation)) {
  let lane = #(run.repo, branch)

  // The first waiting run of a free lane heads it, so later ones keep waiting.
  case set.contains(acc.0, lane) {
    True -> acc
    False -> #(set.insert(acc.0, lane), [
      Preparation(run.id, run.repo, branch, members),
      ..acc.1
    ])
  }
}

/// Record the prepared candidate and graph, or a typed refusal, for exactly
/// the waiting run the caller was offered. A repeat or a run that is no
/// longer at the head of a free lane is refused.
///
/// ## Examples
///
/// ```gleam
/// // queue.record_preparation(state, preparation, Ok(#(candidate, tasks)))
/// ```
pub fn record_preparation(
  state: State,
  preparation: Preparation,
  outcome: Result(#(Candidate, List(Task)), PrepareFailure),
) -> Result(State, String) {
  use run <- result.try(
    find(state, preparation.run) |> result.replace_error("unknown run"),
  )
  let expected = Waiting(preparation.branch, preparation.members)
  use <- bool.guard(
    run.repo != preparation.repo || run.submission != expected,
    Error("preparation already recorded"),
  )

  // A prepared candidate starts the graph. A refusal ends the run's wait.
  case outcome {
    Ok(#(candidate, tasks)) -> prepared(state, run, candidate, tasks)
    Error(failure) -> {
      let submission =
        Unprepared(
          preparation.branch,
          preparation.members,
          cap_prepare(failure),
        )
      Ok(replace_run(state, Run(..run, submission:)))
    }
  }
}

/// Move a head-of-lane waiting run to `Queued` with its candidate and graph.
fn prepared(
  state: State,
  run: Run,
  candidate: Candidate,
  tasks: List(Task),
) -> Result(State, String) {
  // The candidate must carry exactly the members and branch that were pinned.
  let matches = case run.submission {
    Waiting(branch, members) ->
      candidate.branch == branch
      && candidate.members == members
      && tasks != []
      && candidate.commit != ""
    Build
    | Queued(_)
    | Landing(_)
    | Landed(_)
    | Blocked(_, _)
    | Unprepared(_, _, _) -> False
  }

  use <- bool.guard(
    !matches,
    Error("candidate does not match the pinned members"),
  )
  use <- bool.guard(
    !list.any(preparations(state), fn(p) { p.run == run.id }),
    Error("lane is not free for this preparation"),
  )
  Ok(replace_run(
    state,
    Run(
      ..run,
      revision: candidate.commit,
      submission: Queued(candidate),
      work: list.map(tasks, fn(task) { Work(task, Pending(0)) }),
    ),
  ))
}

/// The branch a run reserves while it is queued with live work or landing.
fn holder_branch(run: Run) -> Result(String, Nil) {
  case run.submission {
    Queued(candidate) ->
      case run_failed(run) {
        True -> Error(Nil)
        False -> Ok(candidate.branch)
      }
    Landing(candidate) -> Ok(candidate.branch)
    Build | Waiting(_, _) | Landed(_) | Blocked(_, _) | Unprepared(_, _, _) ->
      Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Claims, expiry, and results
// ---------------------------------------------------------------------------

/// Determine whether any worker could still change this snapshot: an action
/// holds a lease, or a run that `claim` serves has a pending action.
///
/// ## Examples
///
/// ```gleam
/// queue.quiescent(queue.empty())
/// ```
pub fn quiescent(state: State) -> Bool {
  !list.any(state.runs, fn(run) {
    list.any(run.work, fn(work) {
      case work.step {
        Active(_) -> True
        Pending(_) -> servable(run)
        Passed(_) | Reused(_) | Failed(_, _) | Skipped -> False
      }
    })
  })
}

/// Expire lapsed leases, then resolve a pending action, reuse a proof, or
/// reserve a free worker.
///
/// ## Examples
///
/// ```gleam
/// queue.claim(queue.empty(), "worker", "linux", 0).1
/// ```
pub fn claim(
  state: State,
  worker: String,
  pool: String,
  now: Int,
) -> #(State, Option(Assignment)) {
  let state = expire(state, now)

  // A replay of a poll returns the existing lease and spends no capacity.
  case existing_assignment(state, worker) {
    Ok(assignment) -> #(state, Some(assignment))
    Error(Nil) -> offer(state, state.runs, Ask(worker, pool, now))
  }
}

/// Return each action whose lease deadline passed to `Pending` in its next
/// attempt. The last permitted attempt fails the run with `LeaseExpired`, and
/// an action in an already failed run is skipped. A result for the lapsed
/// serial is stale from this transition on.
///
/// ## Examples
///
/// ```gleam
/// queue.expire(queue.empty(), 0) == queue.empty()
/// ```
pub fn expire(state: State, now: Int) -> State {
  State(..state, runs: list.map(state.runs, expire_run(_, now)))
}

/// Apply every lapsed lease of one run, then skip what a new failure strands.
fn expire_run(run: Run, now: Int) -> Run {
  let lapsed = fn(step) {
    case step {
      Active(lease) -> now > lease.until
      Pending(_) | Passed(_) | Reused(_) | Failed(_, _) | Skipped -> False
    }
  }

  // A run without a lapsed lease is left alone, which keeps the state equal.
  case list.any(run.work, fn(work) { lapsed(work.step) }) {
    False -> run
    True -> {
      let failed = run_failed(run)
      let work =
        list.map(run.work, fn(work) {
          case work.step {
            Active(lease) if now > lease.until ->
              Work(..work, step: case failed, lease.attempt >= max_attempts {
                True, _ -> Skipped
                False, True -> Failed(LeaseExpired(lease.attempt), "")
                False, False -> Pending(lease.attempt)
              })
            Pending(_)
            | Active(_)
            | Passed(_)
            | Reused(_)
            | Failed(_, _)
            | Skipped -> work
          }
        })
      skip_pending(Run(..run, work:))
    }
  }
}

/// A worker identity, pool, and time for one poll.
type Ask {
  Ask(worker: String, pool: String, now: Int)
}

/// A pending action whose inputs are resolved.
type Ready {
  Ready(work: Work, key: Key, attempts: Int)
}

/// Find an existing assignment so repeated delivery reuses its identity.
fn existing_assignment(
  state: State,
  worker: String,
) -> Result(Assignment, Nil) {
  use run <- list.find_map(state.runs)
  use work <- list.find_map(run.work)

  // Only an active lease for this worker can be replayed.
  case work.step {
    Active(lease) if lease.worker == worker ->
      Ok(Assignment(run.id, work.task, lease))
    Pending(_) | Active(_) | Passed(_) | Reused(_) | Failed(_, _) | Skipped ->
      Error(Nil)
  }
}

/// Scan enrollment order. Cache hits become durable before the next claim.
fn offer(
  state: State,
  remaining: List(Run),
  ask: Ask,
) -> #(State, Option(Assignment)) {
  case remaining {
    [] -> #(state, None)
    [run, ..rest] -> {
      case next_work(run, ask.pool) {
        Error(Nil) -> offer(state, rest, ask)
        Ok(ready) -> allocate(state, run, ready, ask)
      }
    }
  }
}

/// Reuse a verified result only inside the same project and trust class.
fn allocate(
  state: State,
  run: Run,
  ready: Ready,
  ask: Ask,
) -> #(State, Option(Assignment)) {
  let task = ready.work.task

  // A cache hit advances the graph. A miss spends this worker's slot.
  case cached(state, run.repo, ready.key) {
    Ok(proof) -> {
      let state = replace_work(state, run, task.action.name, Reused(proof))
      offer(state, state.runs, ask)
    }
    Error(Nil) -> {
      let serial = state.serial + 1
      let until = ask.now + task.action.timeout + lease_slack
      let lease =
        Lease(serial, ask.worker, until, ready.attempts + 1, ready.key)
      let state =
        replace_work(
          State(..state, serial:),
          run,
          task.action.name,
          Active(lease),
        )
      #(state, Some(Assignment(run.id, task, lease)))
    }
  }
}

/// Whether `claim` can lease or reuse this run's pending actions.
fn servable(run: Run) -> Bool {
  case run.submission {
    Build | Queued(_) -> !run_failed(run)
    Waiting(_, _)
    | Landing(_)
    | Landed(_)
    | Blocked(_, _)
    | Unprepared(_, _, _) -> False
  }
}

/// Find a ready action without treating ordering-only edges as inputs.
fn next_work(run: Run, pool: String) -> Result(Ready, Nil) {
  use <- bool.guard(!servable(run), Error(Nil))
  use work <- list.find_map(run.work)

  // Only pending work in the requested pool can acquire a fresh lease.
  case work.step {
    Pending(attempts) if work.task.pool == pool -> {
      let action = work.task.action
      use dependencies <- result.try(
        list.try_map(action.dependencies, artifacts(run, _)),
      )
      use _ <- result.try(list.try_map(action.after, artifacts(run, _)))
      let files =
        list.flatten(dependencies)
        |> list.unique
        |> list.sort(fn(a, b) { string.compare(a.path, b.path) })
      Ok(Ready(work, Key(work.task.recipe, files), attempts))
    }
    Pending(_) | Active(_) | Passed(_) | Reused(_) | Failed(_, _) | Skipped ->
      Error(Nil)
  }
}

/// Look up a passing result for the same repository and input key.
fn cached(state: State, repo: String, key: Key) -> Result(Proof, Nil) {
  list.find(state.cache, fn(entry) {
    entry.repo == repo && entry.proof.key == key
  })
  |> result.map(fn(entry) { entry.proof })
}

/// Index a published proof ahead of older entries for the same key.
fn remember(state: State, repo: String, proof: Proof) -> State {
  let others =
    list.filter(state.cache, fn(entry) {
      entry.repo != repo || entry.proof.key != proof.key
    })
  State(..state, cache: [Remembered(repo, proof), ..others])
}

/// Collect the named dependency's output files after it finishes successfully.
fn artifacts(run: Run, name: String) -> Result(List(Artifact), Nil) {
  use work <- result.try(
    list.find(run.work, fn(work) { work.task.action.name == name }),
  )

  // Successors may consume files after a passing result or verified reuse.
  case work.step {
    Passed(proof) | Reused(proof) -> Ok(proof.files)
    Pending(_) | Active(_) | Failed(_, _) | Skipped -> Error(Nil)
  }
}

/// Accept a worker report against the exact live generation. A lease that
/// lapsed but was not yet expired still accepts its own result.
///
/// ## Examples
///
/// ```gleam
/// // queue.finish(state, run_id, action_id, worker, serial, completion)
/// ```
pub fn finish(
  state: State,
  id: String,
  action: String,
  worker: String,
  serial: Int,
  completion: Completion,
) -> Result(State, String) {
  use run <- result.try(find(state, id) |> result.replace_error("unknown run"))
  use work <- result.try(
    list.find(run.work, fn(w) { w.task.action.name == action })
    |> result.replace_error("unknown action"),
  )

  // Only the active lease can publish bytes or unlock its successors.
  case work.step {
    Active(lease) if lease.serial == serial && lease.worker == worker ->
      settled(state, run, work, lease, completion)
    Pending(_) | Active(_) | Passed(_) | Reused(_) | Failed(_, _) | Skipped ->
      Error("attempt is no longer active")
  }
}

/// Bind a verified manifest to the leased key, or record the failed outcome.
fn settled(
  state: State,
  run: Run,
  work: Work,
  lease: Lease,
  completion: Completion,
) -> Result(State, String) {
  let action = work.task.action

  // Verify successful output paths before publishing a proof. Preserve rejected logs.
  case completion {
    Succeeded(files, log) -> {
      let expected = list.sort(action.outputs, string.compare)
      let actual =
        list.map(files, fn(file) { file.path }) |> list.sort(string.compare)
      use <- bool.guard(
        expected != actual,
        Error("output manifest does not match declared paths"),
      )
      let proof = Proof(lease.key, files, log)
      Ok(
        replace_work(state, run, action.name, Passed(proof))
        |> remember(run.repo, proof),
      )
    }
    Rejected(reason, log) -> {
      let failed = Failed(Reported(cap_text(reason)), log)
      Ok(replace_run(state, fail_run(run, action.name, failed)))
    }
  }
}

/// Record a terminal failure and skip the run's other pending actions.
fn fail_run(run: Run, action: String, failed: Step) -> Run {
  let work =
    list.map(run.work, fn(work) {
      case work.task.action.name == action {
        True -> Work(..work, step: failed)
        False -> work
      }
    })
  skip_pending(Run(..run, work:))
}

/// A failed run never starts another action.
fn skip_pending(run: Run) -> Run {
  case run_failed(run) {
    False -> run
    True ->
      Run(
        ..run,
        work: list.map(run.work, fn(work) {
          case work.step {
            Pending(_) -> Work(..work, step: Skipped)
            Active(_) | Passed(_) | Reused(_) | Failed(_, _) | Skipped -> work
          }
        }),
      )
  }
}

// ---------------------------------------------------------------------------
// Landing
// ---------------------------------------------------------------------------

/// Collect each lane's intent. A queued run whose actions all passed becomes
/// `Landing` and is returned with the intents already outstanding. Each lane
/// has at most one such run, so a lane never holds two intents.
///
/// ## Examples
///
/// ```gleam
/// queue.landings(queue.empty()).1 == []
/// ```
pub fn landings(state: State) -> #(State, List(Intent)) {
  let #(runs, intents) =
    list.fold(state.runs, #([], []), fn(acc, run) {
      case run.submission {
        Landing(candidate) -> #([run, ..acc.0], [
          Intent(run.id, run.repo, candidate),
          ..acc.1
        ])
        Queued(candidate) ->
          case all_passed(run) {
            True -> #([Run(..run, submission: Landing(candidate)), ..acc.0], [
              Intent(run.id, run.repo, candidate),
              ..acc.1
            ])
            False -> #([run, ..acc.0], acc.1)
          }
        Build
        | Waiting(_, _)
        | Landed(_)
        | Blocked(_, _)
        | Unprepared(_, _, _) -> #([run, ..acc.0], acc.1)
      }
    })
  #(State(..state, runs: list.reverse(runs)), list.reverse(intents))
}

/// Record the outcome for the exact committed intent. A denial carries a
/// typed block, and any text from the provider is capped.
///
/// ## Examples
///
/// ```gleam
/// // queue.record_landing(state, intent, Ok(Nil))
/// ```
pub fn record_landing(
  state: State,
  intent: Intent,
  outcome: Result(Nil, Block),
) -> Result(State, String) {
  use run <- result.try(
    find(state, intent.run) |> result.replace_error("unknown submit run"),
  )
  use <- bool.guard(
    run.repo != intent.repo || run.submission != Landing(intent.candidate),
    Error("submit intent already reconciled"),
  )

  // Persist the observed landing outcome against this candidate.
  let submission = case outcome {
    Ok(Nil) -> Landed(intent.candidate)
    Error(TargetAdvanced) -> Blocked(intent.candidate, TargetAdvanced)
    Error(PolicyDenied(detail)) ->
      Blocked(intent.candidate, PolicyDenied(cap_text(detail)))
  }

  Ok(replace_run(state, Run(..run, submission:)))
}

// ---------------------------------------------------------------------------
// Retention and status
// ---------------------------------------------------------------------------

/// Whether a run can change no further and holds no lane.
///
/// ## Examples
///
/// ```gleam
/// // queue.terminal(run)
/// ```
pub fn terminal(run: Run) -> Bool {
  case run.submission {
    Landed(_) | Blocked(_, _) | Unprepared(_, _, _) -> True
    Waiting(_, _) | Landing(_) -> False
    Build -> !has_active(run) && { run_failed(run) || all_passed(run) }
    Queued(_) -> !has_active(run) && run_failed(run)
  }
}

/// Drop the oldest terminal runs beyond `keep_runs` and the oldest proofs
/// beyond `keep_proofs`. A run that is not terminal, holds a lane, or waits
/// for one is never dropped. Reuse keeps working from the proof index.
///
/// ## Examples
///
/// ```gleam
/// queue.retain(queue.empty(), queue.Retention(100, 1000)) == queue.empty()
/// ```
pub fn retain(state: State, retention: Retention) -> State {
  let excess =
    int.max(
      0,
      list.count(state.runs, terminal) - int.max(0, retention.keep_runs),
    )
  let #(_, kept) =
    list.fold(state.runs, #(excess, []), fn(acc, run) {
      case acc.0 > 0 && terminal(run) {
        True -> #(acc.0 - 1, acc.1)
        False -> #(acc.0, [run, ..acc.1])
      }
    })
  State(
    ..state,
    runs: list.reverse(kept),
    cache: list.take(state.cache, int.max(0, retention.keep_proofs)),
  )
}

/// Report the outcome independently of the submission effect.
///
/// ## Examples
///
/// ```gleam
/// // queue.phase(run)
/// ```
pub fn phase(run: Run) -> Phase {
  case run.submission {
    Landed(_) -> PhaseLanded
    Blocked(_, _) -> PhaseBlocked
    Landing(_) -> PhaseLanding
    Waiting(_, _) -> PhaseWaiting
    Unprepared(_, _, _) -> PhaseUnprepared
    Build | Queued(_) -> {
      case run_failed(run), all_passed(run) {
        True, _ -> PhaseFailed
        False, True -> PhasePassed
        False, False -> PhasePending
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Shared predicates and updates
// ---------------------------------------------------------------------------

/// Check that every action has passed or reused a verified result.
fn all_passed(run: Run) -> Bool {
  list.all(run.work, fn(work) {
    case work.step {
      Passed(_) | Reused(_) -> True
      Pending(_) | Active(_) | Failed(_, _) | Skipped -> False
    }
  })
}

/// Detect a terminal action failure that prevents the run from landing.
fn run_failed(run: Run) -> Bool {
  list.any(run.work, fn(work) {
    case work.step {
      Failed(_, _) -> True
      Pending(_) | Active(_) | Passed(_) | Reused(_) | Skipped -> False
    }
  })
}

/// Check whether some action still holds a lease.
fn has_active(run: Run) -> Bool {
  list.any(run.work, fn(work) {
    case work.step {
      Active(_) -> True
      Pending(_) | Passed(_) | Reused(_) | Failed(_, _) | Skipped -> False
    }
  })
}

/// Replace the identified run while preserving queue order.
fn replace_run(state: State, updated: Run) -> State {
  State(
    ..state,
    runs: list.map(state.runs, fn(run) {
      case run.id == updated.id {
        True -> updated
        False -> run
      }
    }),
  )
}

/// Advance one named action while retaining the other actions in the run.
fn replace_work(state: State, run: Run, action: String, step: Step) -> State {
  let work =
    list.map(run.work, fn(work) {
      case work.task.action.name == action {
        True -> Work(..work, step:)
        False -> work
      }
    })
  replace_run(state, Run(..run, work:))
}

/// Cap external text inside a preparation refusal.
fn cap_prepare(failure: PrepareFailure) -> PrepareFailure {
  case failure {
    MemberMoved(pull) -> MemberMoved(pull)
    Unmergeable(detail) -> Unmergeable(cap_text(detail))
    Refused(detail) -> Refused(cap_text(detail))
  }
}

/// Keep at most `max_detail_bytes` of text without splitting a grapheme.
fn cap_text(text: String) -> String {
  case string.byte_size(text) <= max_detail_bytes {
    True -> text
    False ->
      string.slice(text, 0, max_detail_bytes)
      |> string.to_graphemes
      |> take_bytes(0, [])
  }
}

/// Accumulate graphemes while their bytes fit the cap.
fn take_bytes(
  graphemes: List(String),
  used: Int,
  kept: List(String),
) -> String {
  // Stop at the first grapheme that would pass the byte cap.
  case graphemes {
    [grapheme, ..rest] -> {
      let size = used + string.byte_size(grapheme)

      // The grapheme fits, so keep it and continue.
      case size <= max_detail_bytes {
        True -> take_bytes(rest, size, [grapheme, ..kept])
        False -> string.concat(list.reverse(kept))
      }
    }
    [] -> string.concat(list.reverse(kept))
  }
}
