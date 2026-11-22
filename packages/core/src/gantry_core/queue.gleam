//// A queue snapshot is the unit of comparison at the durable boundary.
//// The core decides claims, retries, and landing intents with supplied
//// observations. The caller performs an effect after its proposal commits.

import gantry_core/graph.{type Action}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

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
pub type Proof {
  Proof(key: Key, files: List(Artifact), log: String)
}

/// A capability to report one action attempt.
pub type Lease {
  Lease(serial: Int, worker: String, until: Int, attempt: Int, key: Key)
}

/// The state of a single graph action.
pub type Step {
  Pending(previous_attempts: Int)
  Active(lease: Lease)
  Passed(proof: Proof)
  Reused(proof: Proof)
  Failed(reason: String, log: String)
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
pub type Candidate {
  Candidate(branch: String, base: String, commit: String, members: List(Member))
}

/// Only an outstanding intent can authorize a remote mutation.
pub type Submission {
  Build
  Queued(candidate: Candidate)
  Landing(candidate: Candidate)
  Landed(candidate: Candidate)
  Blocked(candidate: Candidate, reason: String)
}

/// The authority conferred by a completed build and committed lane claim.
pub type Intent {
  Intent(run: String, repo: String, candidate: Candidate)
}

/// One run and the full history available to a reconnecting client.
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

/// A durable queue image with a monotonically increasing lease counter.
pub type State {
  State(serial: Int, runs: List(Run))
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

/// An empty queue image.
///
/// ## Examples
///
/// ```gleam
/// queue.empty().runs == []
/// ```
pub fn empty() -> State {
  State(0, [])
}

/// Admit a complete, prepared graph and assign initial phases.
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
  use Nil <- result.try(
    require(tasks != [] && valid_admission(submission, revision))
    |> result.replace_error("empty build or candidate does not match revision"),
  )

  // A retry with the same ID may recover only the run with the original inputs.
  case find(state, id) {
    Ok(prior)
      if prior.repo == repo
      && prior.revision == revision
      && prior.target == target
    -> {
      case
        submission_identity(prior.submission) == submission_identity(submission)
        && list.map(prior.work, fn(work) { work.task }) == tasks
      {
        True -> Ok(#(state, prior))
        False -> Error("run ID already has different inputs")
      }
    }

    // The client chooses the ID, but a retry cannot replace earlier work.
    Ok(_) -> Error("run ID already has different inputs")
    Error(Nil) -> {
      let run =
        Run(
          id,
          repo,
          revision,
          target,
          submission,
          list.map(tasks, fn(task) { Work(task, Pending(0)) }),
        )
      Ok(#(State(..state, runs: list.append(state.runs, [run])), run))
    }
  }
}

/// Accept ordinary builds and queued candidates pinned to their recorded revision.
fn valid_admission(submission: Submission, revision: String) -> Bool {
  case submission {
    Build -> True
    Queued(candidate) -> candidate.commit == revision && candidate.members != []
    Landing(_) | Landed(_) | Blocked(_, _) -> False
  }
}

/// Recover the original candidate identity across subsequent landing phases.
fn submission_identity(submission: Submission) -> Option(Candidate) {
  case submission {
    Build -> None
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

/// Determine whether a worker could receive a lease from this snapshot.
///
/// ## Examples
///
/// ```gleam
/// queue.quiescent(queue.empty())
/// ```
pub fn quiescent(state: State) -> Bool {
  list.all(state.runs, fn(run) {
    list.all(run.work, fn(work) {
      case work.step {
        Pending(_) | Active(_) -> False
        Passed(_) | Reused(_) | Failed(_, _) -> True
      }
    })
  })
}

/// Resolve a pending action, reuse a proof, or reserve a free worker.
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
  // A replay of a poll returns the existing lease and spends no capacity.
  case existing_assignment(state, worker) {
    Ok(assignment) -> #(state, Some(assignment))
    Error(Nil) -> offer(state, state.runs, worker, pool, now)
  }
}

/// Find an existing assignment so repeated delivery reuses its identity.
///
/// ## Examples
///
/// ```gleam
/// // existing_assignment(state, worker)
/// ```
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
    Pending(_) | Active(_) | Passed(_) | Reused(_) | Failed(_, _) -> Error(Nil)
  }
}

/// Scan enrollment order. Cache hits become durable before the next claim.
///
/// ## Examples
///
/// ```gleam
/// // offer(state, state.runs, worker, pool, now)
/// ```
fn offer(
  state: State,
  remaining: List(Run),
  worker: String,
  pool: String,
  now: Int,
) -> #(State, Option(Assignment)) {
  case remaining {
    [] -> #(state, None)
    [run, ..rest] -> {
      case next_work(state, run, pool) {
        Error(Nil) -> offer(state, rest, worker, pool, now)
        Ok(#(work, key, attempts)) -> {
          allocate(state, run, work, key, attempts, worker, pool, now)
        }
      }
    }
  }
}

/// Reuse a verified result only inside the same project and trust class.
///
/// ## Examples
///
/// ```gleam
/// // allocate(state, run, work, key, attempts, worker, pool, now)
/// ```
fn allocate(
  state: State,
  run: Run,
  work: Work,
  key: Key,
  attempts: Int,
  worker: String,
  pool: String,
  now: Int,
) -> #(State, Option(Assignment)) {
  // A cache hit advances the graph. A miss spends this worker's slot.
  case cached(state, run.repo, key) {
    Ok(proof) -> {
      let state = replace_work(state, run, work.task.action.name, Reused(proof))
      offer(state, state.runs, worker, pool, now)
    }
    Error(Nil) -> {
      let serial = state.serial + 1
      let lease =
        Lease(
          serial,
          worker,
          now + work.task.action.timeout + 150,
          attempts + 1,
          key,
        )
      let state =
        replace_work(
          State(..state, serial:),
          run,
          work.task.action.name,
          Active(lease),
        )
      #(state, Some(Assignment(run.id, work.task, lease)))
    }
  }
}

/// Find a ready action without treating ordering-only edges as inputs.
///
/// ## Examples
///
/// ```gleam
/// // next_work(state, run, "linux")
/// ```
fn next_work(
  state: State,
  run: Run,
  pool: String,
) -> Result(#(Work, Key, Int), Nil) {
  use Nil <- result.try(eligible(state, run))
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
      Ok(#(work, Key(work.task.recipe, files), attempts))
    }
    Pending(_) | Active(_) | Passed(_) | Reused(_) | Failed(_, _) -> Error(Nil)
  }
}

/// Look up a passing result for the same repository and input key.
fn cached(state: State, repo: String, key: Key) -> Result(Proof, Nil) {
  use run <- list.find_map(state.runs)
  use Nil <- result.try(require(run.repo == repo))
  use work <- list.find_map(run.work)

  // Only an originally passed action can supply a proof for this key.
  case work.step {
    Passed(proof) if proof.key == key -> Ok(proof)
    Pending(_) | Active(_) | Passed(_) | Reused(_) | Failed(_, _) -> Error(Nil)
  }
}

/// Collect the named dependency's output files after it finishes successfully.
fn artifacts(run: Run, name: String) -> Result(List(Artifact), Nil) {
  use work <- result.try(
    list.find(run.work, fn(work) { work.task.action.name == name }),
  )

  // Successors may consume files after a passing result or verified reuse.
  case work.step {
    Passed(proof) | Reused(proof) -> Ok(proof.files)
    Pending(_) | Active(_) | Failed(_, _) -> Error(Nil)
  }
}

/// Accept a worker report against the exact live generation.
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
    Pending(_) | Active(_) | Passed(_) | Reused(_) | Failed(_, _) ->
      Error("attempt is no longer active")
  }
}

/// Bind a verified manifest to the leased key, or record the failed outcome.
///
/// ## Examples
///
/// ```gleam
/// // settled(state, run, work, lease, completion)
/// ```
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
      use Nil <- result.try(
        require(expected == actual)
        |> result.replace_error("output manifest does not match declared paths"),
      )
      Ok(replace_work(
        state,
        run,
        action.name,
        Passed(Proof(lease.key, files, log)),
      ))
    }
    Rejected(reason, log) ->
      Ok(replace_work(state, run, action.name, Failed(reason, log)))
  }
}

/// Report the outcome independently of the submission effect.
///
/// ## Examples
///
/// ```gleam
/// // queue.phase(run)
/// ```
pub fn phase(run: Run) -> String {
  case run.submission {
    Landed(_) -> "landed"
    Blocked(_, _) -> "blocked"
    Landing(_) -> "landing"
    Build | Queued(_) -> {
      case run_failed(run), all_passed(run) {
        True, _ -> "failed"
        False, True -> "passed"
        False, False -> "pending"
      }
    }
  }
}

/// Commit a lane's next intent or return the existing one for reconciliation.
///
/// ## Examples
///
/// ```gleam
/// queue.landing(queue.empty()).1 == None
/// ```
pub fn landing(state: State) -> #(State, Option(Intent)) {
  let next = list.find(state.runs, can_land(state, _))

  // A ready or outstanding intent can be handed to the reconciler.
  case next {
    Error(Nil) -> #(state, None)
    Ok(run) -> landing_run(state, run)
  }
}

/// Collect intents in separate lanes so one uncertain remote cannot starve another.
///
/// ## Examples
///
/// ```gleam
/// queue.landings(queue.empty()).1 == []
/// ```
pub fn landings(state: State) -> #(State, List(Intent)) {
  let #(next, intents) =
    list.fold(state.runs, #(state, []), fn(acc, run) {
      let #(current, intents) = acc

      // The current snapshot already holds any earlier claim in this lane.
      case can_land(current, run) {
        False -> acc
        True -> {
          let #(next, intent) = landing_run(current, run)
          #(
            next,
            option.map(intent, fn(value) { [value, ..intents] })
              |> option.unwrap(intents),
          )
        }
      }
    })
  #(next, list.reverse(intents))
}

/// Check whether this run can supply the existing or next intent.
fn can_land(state: State, run: Run) -> Bool {
  case run.submission {
    Landing(_) -> True
    Queued(_) -> all_passed(run) && eligible(state, run) == Ok(Nil)
    Build | Landed(_) | Blocked(_, _) -> False
  }
}

/// Return the durable intent for a candidate that owns its landing lane.
fn landing_run(state: State, run: Run) -> #(State, Option(Intent)) {
  // Reuse an outstanding intent or record the queued candidate's first landing attempt.
  case run.submission {
    Landing(candidate) -> #(state, Some(Intent(run.id, run.repo, candidate)))
    Queued(candidate) -> {
      let next = replace_run(state, Run(..run, submission: Landing(candidate)))
      #(next, Some(Intent(run.id, run.repo, candidate)))
    }
    Build | Landed(_) | Blocked(_, _) -> #(state, None)
  }
}

/// Record the outcome for the exact committed intent.
///
/// ## Examples
///
/// ```gleam
/// // queue.record_landing(state, intent, Ok(Nil))
/// ```
pub fn record_landing(
  state: State,
  intent: Intent,
  outcome: Result(Nil, String),
) -> Result(State, String) {
  use run <- result.try(
    find(state, intent.run) |> result.replace_error("unknown submit run"),
  )
  use Nil <- result.try(
    require(
      run.repo == intent.repo && run.submission == Landing(intent.candidate),
    )
    |> result.replace_error("submit intent already reconciled"),
  )

  // Persist the observed landing outcome against this candidate.
  let submission = case outcome {
    Ok(Nil) -> Landed(intent.candidate)
    Error(reason) -> Blocked(intent.candidate, reason)
  }

  Ok(replace_run(state, Run(..run, submission:)))
}

/// Determine whether an earlier unfinished candidate still owns the lane.
///
/// ## Examples
///
/// ```gleam
/// // eligible(state, run)
/// ```
fn eligible(state: State, run: Run) -> Result(Nil, Nil) {
  use Nil <- result.try(require(!run_failed(run)))

  // Ordinary builds run independently. Queued submissions wait for their branch.
  case run.submission {
    Build -> Ok(Nil)
    Queued(candidate) -> {
      let ahead = list.take_while(state.runs, fn(other) { other.id != run.id })
      require(
        !list.any(ahead, fn(other) {
          other.repo == run.repo && holds_lane(other, candidate.branch)
        }),
      )
    }
    Landing(_) | Landed(_) | Blocked(_, _) -> Error(Nil)
  }
}

/// Check whether an earlier unfinished submission reserves this branch.
fn holds_lane(run: Run, branch: String) -> Bool {
  case run.submission {
    Queued(candidate) -> candidate.branch == branch && !run_failed(run)
    Landing(candidate) -> candidate.branch == branch
    Build | Landed(_) | Blocked(_, _) -> False
  }
}

/// Check that every action has passed or reused a verified result.
fn all_passed(run: Run) -> Bool {
  list.all(run.work, fn(work) {
    case work.step {
      Passed(_) | Reused(_) -> True
      Pending(_) | Active(_) | Failed(_, _) -> False
    }
  })
}

/// Detect a terminal action failure that prevents the run from landing.
fn run_failed(run: Run) -> Bool {
  list.any(run.work, fn(work) {
    case work.step {
      Failed(_, _) -> True
      Pending(_) | Active(_) | Passed(_) | Reused(_) -> False
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

fn require(condition: Bool) -> Result(Nil, Nil) {
  case condition {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}
