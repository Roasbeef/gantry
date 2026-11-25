//// A committed intent survives the actor and controller. An uncertain Git
//// outcome leaves that exact intent outstanding until a later observation.

import gantry/config.{type Config}
import gantry/fault.{type Fault}
import gantry/store
import gantry/submit
import gantry_core/queue
import gleam/dict
import gleam/list
import gleam/result
import weft/actor

type Message {
  Reconcile
}

/// Start a linked and periodic submission reconciler.
///
/// ## Examples
///
/// ```gleam
/// // reconcile.start(config)
/// ```
pub fn start(cfg: Config) -> Result(Nil, String) {
  actor.new(cfg)
  |> actor.on_message(on_message)
  |> actor.periodic(every: 1000, sending: Reconcile)
  |> actor.start
  |> result.replace_error("cannot start submit reconciler")
  |> result.map(fn(_) { Nil })
}

fn on_message(cfg: Config, _message: Message) -> actor.Next(Config, Message) {
  let _ = tick(cfg)
  actor.continue(cfg)
}

/// Reconcile faults outside the HTTP path. Unknown outcomes retain authority.
///
/// ## Examples
///
/// ```gleam
/// // tick(config)
/// ```
fn tick(cfg: Config) -> Result(Nil, Fault) {
  use intents <- result.try(
    store.change(fn(state) { Ok(queue.landings(state)) }),
  )
  list.each(intents, fn(intent) {
    let _ = reconcile_one(cfg, intent)
    Nil
  })
  Ok(Nil)
}

/// Replay the exact effect for one target, keeping ambiguous outcomes durable.
///
/// ## Examples
///
/// ```gleam
/// // reconcile_one(config, intent)
/// ```
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
