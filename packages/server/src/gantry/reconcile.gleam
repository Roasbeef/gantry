//// A committed intent survives the actor and controller. An uncertain Git
//// outcome leaves that exact intent outstanding until a later observation,
//// and each unresolved intent is retried on its own backoff.
////
//// ## Flow
////
//// Every second the actor runs `maintain_queue`, then `tick` reads the
//// landing intents from the queue. For each intent that is `due`, `attempt`
//// asks `submit.reconcile` for the observed outcome and records a definite
//// one through the queue. Any error is logged, and `failed` moves the
//// intent's next attempt later. `resolved` removes an intent that reached a
//// decision, and `tick` drops an intent that another controller resolved
//// first.
////
//// | Event for an intent | Retry table |
//// | --- | --- |
//// | First failure | Retry in 1 s |
//// | Each further failure | Double the delay, up to 60 s |
//// | Resolved, or no longer outstanding | Entry removed |
////
//// The table lives in the actor, so a restart forgets it and every intent
//// is attempted once at the next tick. The supervisor restarts the actor
//// when it crashes.

import gantry/config.{type Config}
import gantry/fault.{type Fault}
import gantry/prepare
import gantry/store
import gantry/submit
import gantry_core/queue
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision
import gleam/result
import logging
import weft/actor
import weft/poll

/// The one message the reconciler's periodic timer sends.
type Message {
  Reconcile
}

/// The longest wait between attempts for one intent, in milliseconds.
const longest_delay = 60_000

const first_delay = 1000

/// When an unresolved intent may next be attempted, and how long the last
/// wait was. Times are monotonic milliseconds.
pub type Retry {
  Retry(not_before: Int, delay: Int)
}

/// The reconciler's memory. `retries` backs off landing intents,
/// `preparing` backs off waiting groups, and `next_retain` is the monotonic
/// time of the next retention pass, or `None` before the first one. Monotonic
/// time can be negative, so no integer stands for "due now".
type State {
  State(
    cfg: Config,
    retries: Dict(String, Retry),
    preparing: Dict(String, Retry),
    next_retain: Option(Int),
  )
}

/// How often the queue is trimmed to its retention bounds, in milliseconds.
const retain_every = 60_000

/// Describe a linked, periodic submission reconciler for a supervisor.
///
/// The actor owns no durable state. A restart attempts each outstanding
/// intent at its next tick, which is safe because every attempt re-observes
/// the remote before it acts.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(supervisor, reconcile.supervised(config))
/// ```
pub fn supervised(cfg: Config) -> supervision.ChildSpecification(Nil) {
  actor.new(State(cfg, dict.new(), dict.new(), None))
  |> actor.on_message(on_message)
  |> actor.periodic(every: 1000, sending: Reconcile)
  |> actor.supervised
  |> supervision.map_data(fn(_) { Nil })
}

/// Run one reconciler pass with an empty memory: maintenance first, then
/// every outstanding landing intent. The periodic actor does the same on each
/// tick, and tests drive the queue through this entry instead of waiting.
///
/// ## Examples
///
/// ```gleam
/// // reconcile.pass(config)
/// ```
pub fn pass(cfg: Config) -> Nil {
  let now = poll.monotonic().now()
  let fresh = State(cfg, dict.new(), dict.new(), None)
  let _ = tick(maintain_queue(fresh, now), now)
  Nil
}

fn on_message(state: State, _message: Message) -> actor.Next(State, Message) {
  let now = poll.monotonic().now()
  actor.continue(tick(maintain_queue(state, now), now))
}

/// Periodic queue maintenance, run before the landing step so a lane that
/// a landing freed is visible in the same tick. First every waiting group at
/// the head of a free lane is built, and then, on a schedule, finished runs
/// beyond the retention bounds are dropped. Lease expiry needs no step here,
/// because every claim runs it.
fn maintain_queue(state: State, now: Int) -> State {
  state |> prepare_waiting(now) |> retain_finished(now)
}

/// Build each group that heads a free lane, record its candidate and graph
/// or its refusal, and back off a group whose outcome is unknown.
fn prepare_waiting(state: State, now: Int) -> State {
  // A read is enough, because recording re-checks the lane under the swap.
  case store.read() {
    Error(reason) -> {
      log_failure("cannot read waiting groups", reason)
      state
    }
    Ok(snapshot) -> {
      let waiting = queue.preparations(snapshot)
      let names = list.map(waiting, queue.preparation_run)
      let kept =
        dict.filter(state.preparing, fn(name, _) { list.contains(names, name) })
      let preparing =
        list.fold(waiting, kept, fn(table, preparation) {
          prepare_attempt(state.cfg, table, preparation, now)
        })
      State(..state, preparing:)
    }
  }
}

/// Prepare one group if its backoff has elapsed and update the table.
fn prepare_attempt(
  cfg: Config,
  table: Dict(String, Retry),
  preparation: queue.Preparation,
  now: Int,
) -> Dict(String, Retry) {
  let name = queue.preparation_run(preparation)

  // A group inside its backoff window waits for a later tick.
  case due(table, name, now) {
    False -> table
    True ->
      // A recorded outcome clears the entry, and an unknown one doubles it.
      case prepare_one(cfg, preparation) {
        Ok(Nil) -> resolved(table, name)
        Error(reason) -> {
          log_failure("cannot prepare run " <> name, reason)
          failed(table, name, now)
        }
      }
  }
}

/// Build one group's candidate and record exactly what the queue offered. A
/// moved pin, a conflict and a refusal are durable outcomes. A Git or GitHub
/// failure is an error, so the group stays waiting and is retried.
fn prepare_one(
  cfg: Config,
  preparation: queue.Preparation,
) -> Result(Nil, Fault) {
  // A controller that does not know the repository leaves the group alone.
  // During a rollout another controller may already have it configured.
  use repo <- result.try(
    dict.get(cfg.repositories, queue.preparation_repo(preparation))
    |> result.replace_error(fault.Internal(
      "repository configuration unavailable",
    )),
  )
  use outcome <- result.try(prepare.candidate(cfg, repo, preparation))

  // A built candidate and a refusal are both durable outcomes.
  let recorded = case outcome {
    prepare.Ready(candidate, tasks) -> Ok(#(candidate, tasks))
    prepare.Refusal(failure) -> Error(failure)
  }

  store.change(fn(state) {
    queue.record_preparation(state, preparation, recorded)
    |> result.map(fn(next) { #(next, Nil) })
    |> result.map_error(fault.Conflict)
  })
}

/// Drop finished runs and proofs beyond the configured bounds once per
/// interval. An unchanged snapshot is confirmed and not rewritten, so a
/// queue within its bounds costs one read.
fn retain_finished(state: State, now: Int) -> State {
  // Before the first pass nothing is scheduled, so a pass is due at once.
  let due = case state.next_retain {
    Some(at) -> now >= at
    None -> True
  }

  // Between passes the queue is left alone.
  case due {
    False -> state
    True -> {
      let outcome =
        store.change(fn(snapshot) {
          Ok(#(queue.retain(snapshot, state.cfg.retention), Nil))
        })

      // A failed pass is logged and tried again at the next interval.
      case outcome {
        Ok(Nil) -> Nil
        Error(reason) -> log_failure("cannot apply retention", reason)
      }

      State(..state, next_retain: Some(now + retain_every))
    }
  }
}

/// Reconcile faults outside the HTTP path. Unknown outcomes retain authority.
fn tick(state: State, now: Int) -> State {
  // An unreadable queue changes nothing. Otherwise each due intent gets an
  // attempt, and intents that left the queue lose their retry entries.
  case store.change(fn(snapshot) { Ok(queue.landings(snapshot)) }) {
    Error(reason) -> {
      log_failure("cannot read landing intents", reason)
      state
    }
    Ok(intents) -> {
      let keys = list.map(intents, key)
      let kept = dict.filter(state.retries, fn(k, _) { list.contains(keys, k) })
      let retries =
        list.fold(intents, kept, fn(retries, intent) {
          attempt(state.cfg, retries, intent, now)
        })
      State(..state, retries:)
    }
  }
}

/// Reconcile one intent if its backoff has elapsed and update the table.
fn attempt(
  cfg: Config,
  retries: Dict(String, Retry),
  intent: queue.Intent,
  now: Int,
) -> Dict(String, Retry) {
  let name = key(intent)

  // An intent inside its backoff window waits for a later tick.
  case due(retries, name, now) {
    False -> retries
    True ->
      // A decision clears the entry, and an error doubles the wait.
      case reconcile_one(cfg, intent) {
        Ok(Nil) -> resolved(retries, name)
        Error(reason) -> {
          log_failure(
            "cannot reconcile run " <> queue.intent_run(intent),
            reason,
          )
          failed(retries, name, now)
        }
      }
  }
}

/// The retry table's identity for an intent. The candidate commit is part
/// of it, so a replaced candidate never inherits another's backoff.
fn key(intent: queue.Intent) -> String {
  queue.intent_run(intent)
  <> "@"
  <> queue.candidate_commit(queue.intent_candidate(intent))
}

/// Whether an intent may be attempted now.
///
/// ## Examples
///
/// ```gleam
/// assert reconcile.due(dict.new(), "run@abc", 0)
/// ```
pub fn due(retries: Dict(String, Retry), name: String, now: Int) -> Bool {
  case dict.get(retries, name) {
    Ok(retry) -> now >= retry.not_before
    Error(Nil) -> True
  }
}

/// Record a failed attempt and delay the next one, doubling the previous
/// wait up to the longest delay.
///
/// ## Examples
///
/// ```gleam
/// let retries = reconcile.failed(dict.new(), "run@abc", 5000)
/// assert !reconcile.due(retries, "run@abc", 5999)
/// ```
pub fn failed(
  retries: Dict(String, Retry),
  name: String,
  now: Int,
) -> Dict(String, Retry) {
  // A first failure waits the base delay. Later ones double the last wait.
  let delay = case dict.get(retries, name) {
    Ok(previous) -> int.min(previous.delay * 2, longest_delay)
    Error(Nil) -> first_delay
  }

  dict.insert(retries, name, Retry(not_before: now + delay, delay:))
}

/// Forget an intent whose attempt reached a decision.
///
/// ## Examples
///
/// ```gleam
/// let retries = reconcile.failed(dict.new(), "run@abc", 0)
/// assert reconcile.resolved(retries, "run@abc") == dict.new()
/// ```
pub fn resolved(
  retries: Dict(String, Retry),
  name: String,
) -> Dict(String, Retry) {
  dict.delete(retries, name)
}

/// Replay the exact effect for one target, keeping ambiguous outcomes durable.
fn reconcile_one(cfg: Config, intent: queue.Intent) -> Result(Nil, Fault) {
  use repo <- result.try(
    dict.get(cfg.repositories, queue.intent_repo(intent))
    |> result.replace_error(fault.Internal(
      "repository configuration unavailable",
    )),
  )
  use outcome <- result.try(submit.reconcile(cfg, repo, intent))

  // A refusal is a durable block, so the lane is released with its reason.
  let recorded = case outcome {
    submit.Landed -> Ok(Nil)
    submit.Refused(block) -> Error(block)
  }

  store.change(fn(state) {
    queue.record_landing(state, intent, recorded)
    |> result.map(fn(next) { #(next, Nil) })
    |> result.map_error(fault.Conflict)
  })
}

/// Log one reconcile failure at the level its kind deserves. A dependency
/// that is down, or a record another controller already wrote, is a
/// warning. Anything else needs an operator.
fn log_failure(context: String, reason: Fault) -> Nil {
  // Dependency failures clear themselves, and the fault kinds below describe
  // a request or durable state that an operator must look at.
  let level = case reason {
    fault.Unavailable(_) | fault.Conflict(_) -> logging.Warning
    fault.Invalid(_)
    | fault.Unauthorized(_)
    | fault.Forbidden(_)
    | fault.NotFound(_)
    | fault.Internal(_) -> logging.Error
  }

  logging.log(level, "reconciler: " <> context <> ": " <> fault.detail(reason))
}
