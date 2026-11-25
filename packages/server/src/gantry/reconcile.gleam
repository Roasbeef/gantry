//// A committed intent survives the actor and controller. An uncertain Git
//// outcome leaves that exact intent outstanding until a later observation,
//// and each unresolved intent is retried on its own backoff.
////
//// ## Flow
////
//// Every second the actor runs `maintain_queue`, then reads the landing
//// intents from the queue. For each intent that is due it asks
//// `submit.reconcile` for the observed outcome and records a definite one
//// through the queue. Any error is logged and moves the intent's next
//// attempt later. A resolved intent leaves the table, and so does an intent
//// that another controller resolved first.
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
import gantry/store
import gantry/submit
import gantry_core/queue
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
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

type State {
  State(cfg: Config, retries: Dict(String, Retry))
}

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
  actor.new(State(cfg, dict.new()))
  |> actor.on_message(on_message)
  |> actor.periodic(every: 1000, sending: Reconcile)
  |> actor.supervised
  |> supervision.map_data(fn(_) { Nil })
}

fn on_message(state: State, _message: Message) -> actor.Next(State, Message) {
  actor.continue(tick(maintain_queue(state), poll.monotonic().now()))
}

/// The place where periodic queue maintenance runs once the core queue
/// exposes it: lease expiry, terminal skipping and retention. Each will be
/// one committed transition through `store.change`, run before the landing
/// step so a freed lane is visible in the same tick. Nothing is scheduled
/// yet.
fn maintain_queue(state: State) -> State {
  state
}

/// Reconcile faults outside the HTTP path. Unknown outcomes retain authority.
fn tick(state: State, now: Int) -> State {
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
  case due(retries, name, now) {
    False -> retries
    True ->
      case reconcile_one(cfg, intent) {
        Ok(Nil) -> resolved(retries, name)
        Error(reason) -> {
          log_failure("cannot reconcile run " <> intent.run, reason)
          failed(retries, name, now)
        }
      }
  }
}

/// The retry table's identity for an intent. The candidate commit is part
/// of it, so a replaced candidate never inherits another's backoff.
fn key(intent: queue.Intent) -> String {
  intent.run <> "@" <> intent.candidate.commit
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
    dict.get(cfg.repositories, intent.repo)
    |> result.replace_error(fault.Internal(
      "repository configuration unavailable",
    )),
  )
  use outcome <- result.try(submit.reconcile(cfg, repo, intent))

  // A refusal is a durable block, so the lane is released with its reason.
  let recorded = case outcome {
    submit.Landed -> Ok(Nil)
    submit.Refused(reason) -> Error(reason)
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
  let level = case reason {
    fault.Unavailable(_) | fault.Conflict(_) -> logging.Warning
    _ -> logging.Error
  }
  logging.log(level, "reconciler: " <> context <> ": " <> fault.detail(reason))
}
