//// The worker owns one physical slot until the controller accepts or fences
//// its durable result. The journal separates preparation, a possible Docker
//// start, and a recorded completion.
////
//// ## Flow
////
//// `main` calls `boot`, which opens the journal and takes its exclusive
//// lock. `supervise` then starts the slot loop under a supervisor, and
//// `on_message` advances the slot once per tick. `poll_delay` spaces ticks
//// after an idle poll or a retryable fault.
////
//// ```text
//// main -> boot -> supervise -> on_message -> slot.step -> next Tick
//// ```
////
//// | Verdict           | Next Tick                                  | Invariant kept                          |
//// | ----------------- | ------------------------------------------ | --------------------------------------- |
//// | `Advanced`        | at once, with the idle streak reset        | work is never delayed after progress    |
//// | `Idled`           | after a jittered delay, up to 2 s          | idle polling stays below one per second |
//// | `Faulted(Retry)`  | after the same delay                       | a transient fault never spins           |
//// | `Faulted(Stop)`   | none, the VM exits                         | untrusted custody never continues       |
////
//// The slot loop is a supervised Weft actor, so a crash restarts it with the
//// same journal. The exclusive lock lives on the SQLite connection that
//// `boot` opens, which `main` keeps alive, so a restart cannot admit a
//// second worker. A custody fault does not restart: it halts the VM, since
//// a restart would resume from the same untrusted journal.

import envoy
import gantry/internal/ffi_host
import gantry/worker/controllers
import gantry/worker/custody
import gantry/worker/docker
import gantry/worker/slot
import gantry_core/graph
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import simplifile
import weft/actor

/// The first idle or retry delay ceiling, in milliseconds.
const first_delay = 500

/// The delay ceiling once a streak of idle polls has built up.
const longest_delay = 2000

/// Run a remote executor using the configured physical slot and controller list.
///
/// ## Examples
///
/// ```sh
/// gleam run -m gantry/worker
/// ```
pub fn main() -> Nil {
  case boot() {
    Ok(#(current, network)) -> supervise(current, network)
    Error(reason) -> stop(reason)
  }
}

/// Validate the slot configuration and acquire its journal exclusively.
fn boot() -> Result(#(slot.Slot, controllers.Controllers), String) {
  use worker <- result.try(identity("GANTRY_WORKER_ID"))
  use pool <- result.try(identity("GANTRY_POOL"))
  use endpoint <- result.try(required("GANTRY_ENDPOINT"))
  use token <- result.try(required("GANTRY_WORKER_TOKEN"))
  use network <- result.try(controllers.new(endpoint, token))
  use limits <- result.try(docker.limits())
  use raw_directory <- result.try(required("GANTRY_WORKER_DIR"))
  use directory <- result.try(worker_directory(raw_directory))

  // Opening the journal takes its exclusive lock before anything else runs.
  // A managed profile must preserve custody even if its journal is removed.
  use db <- result.try(case envoy.get("GANTRY_WORKER_GUARD") {
    Ok(profile) -> custody.open_managed(profile, directory, worker)
    Error(Nil) -> custody.open(directory <> "/custody.sqlite3", worker)
  })

  use Nil <- result.try(docker.preflight())

  let engine =
    slot.Engine(
      execute: fn(name, assignment, network, start, spool) {
        docker.execute(
          directory,
          name,
          assignment,
          limits,
          network,
          start,
          spool,
        )
      },
      cleanup: fn(name) { docker.cleanup(directory, name) },
    )
  Ok(#(slot.Slot(directory, worker, pool, db, engine), network))
}

/// What the slot loop receives: its own timer.
type Message {
  Tick
}

/// The slot, the loop's cursor and the count of consecutive empty polls.
type Loop {
  Loop(
    current: slot.Slot,
    cursor: slot.Cursor,
    streak: Int,
    self: process.Subject(Message),
  )
}

/// Run the slot loop under a supervisor and exit when the supervisor does.
fn supervise(current: slot.Slot, network: controllers.Controllers) -> Nil {
  let loop =
    actor.new_with_initialiser(5000, fn(self) {
      actor.initialised(Loop(current, slot.Cursor(network, None), 0, self))
      |> actor.returning(self)
      |> actor.continuing(Tick)
      |> Ok
    })
    |> actor.on_message(on_message)

  // A loop that keeps crashing exhausts the tolerance and ends the VM, so the
  // service manager restarts the worker with a clean process state.
  let tree =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.restart_tolerance(intensity: 5, period: 60)
    |> supervisor.add(actor.supervised(loop))

  // The VM exits with the supervisor, so a dead slot never idles unnoticed.
  case supervisor.start(tree) {
    Ok(started) -> {
      process.new_selector()
      |> process.select_specific_monitor(
        process.monitor(started.pid),
        fn(_down) { Nil },
      )
      |> process.selector_receive_forever
      stop("worker supervisor exited")
    }
    Error(_) -> stop("cannot start the worker supervisor")
  }
}

/// Advance the slot once and schedule the next tick from its verdict.
fn on_message(state: Loop, _message: Message) -> actor.Next(Loop, Message) {
  // An empty or failed poll waits out a jittered delay and lengthens the streak.
  let pause = fn(cursor) {
    process.send_after(
      state.self,
      poll_delay(state.streak, int.random(1000)),
      Tick,
    )
    actor.continue(Loop(..state, cursor:, streak: state.streak + 1))
  }

  // Only retry temporary faults. Stop when local custody cannot be trusted.
  case slot.step(state.current, state.cursor) {
    #(cursor, slot.Advanced) -> {
      process.send(state.self, Tick)
      actor.continue(Loop(..state, cursor:, streak: 0))
    }
    #(cursor, slot.Idled) -> pause(cursor)
    #(cursor, slot.Faulted(slot.Retry(reason))) -> {
      io.println_error("gantry worker: " <> reason)
      pause(cursor)
    }
    #(_, slot.Faulted(slot.Stop(reason))) -> {
      stop(reason)
      actor.stop()
    }
  }
}

/// The wait after `streak` consecutive idle or failed polls.
///
/// The ceiling is 500 ms, then 1 s, then 2 s for every later poll, and the
/// wait is somewhere in the upper half of that ceiling. `entropy` is a
/// number from 0 to 999 that spreads slots so they do not poll in step.
///
/// ## Examples
///
/// ```gleam
/// worker.poll_delay(0, 0)
/// // -> 250
/// ```
pub fn poll_delay(streak: Int, entropy: Int) -> Int {
  // The ceiling doubles once, then stays at its cap.
  let ceiling = case streak {
    0 -> first_delay
    1 -> first_delay * 2
    _ -> longest_delay
  }

  let half = ceiling / 2
  half + half * int.clamp(entropy, 0, 999) / 1000
}

/// Resolve and protect the directory shared with the Docker mount adapter.
fn worker_directory(raw: String) -> Result(String, String) {
  use Nil <- result.try(check_directory(raw))
  use Nil <- result.try(
    simplifile.create_directory_all(raw)
    |> result.replace_error("could not create worker directory"),
  )
  use #(status, resolved) <- result.try(ffi_host.run(
    "realpath",
    ["--", raw],
    [],
    5000,
  ))
  let path = string.drop_end(resolved, 1)

  // Mount sources must remain valid after resolving symlinks.
  use Nil <- result.try(case status, path {
    0, "/" -> Error("worker directory cannot be the filesystem root")
    0, _ -> check_directory(path)
    _, _ -> Error("could not resolve worker directory")
  })

  simplifile.set_permissions_octal(path, 448)
  |> result.replace_error("could not restrict worker directory permissions")
  |> result.replace(path)
}

/// Reject paths Docker's mount grammar would parse as options.
fn check_directory(path: String) -> Result(Nil, String) {
  case
    string.starts_with(path, "/")
    && !list.any([",", "\n", "\r"], string.contains(path, _))
  {
    True -> Ok(Nil)
    False -> Error("GANTRY_WORKER_DIR must be an absolute Docker mount path")
  }
}

fn required(key: String) -> Result(String, String) {
  case envoy.get(key) {
    Ok(value) if value != "" -> Ok(value)
    _ -> Error("set " <> key)
  }
}

/// Use the same identifier grammar as the controller's claim endpoint.
fn identity(key: String) -> Result(String, String) {
  use value <- result.try(required(key))

  // A worker or pool name is a single component.
  case graph.valid_path(value) && !string.contains(value, "/") {
    True -> Ok(value)
    False -> Error(key <> " must be a valid worker or pool identifier")
  }
}

fn stop(reason: String) -> Nil {
  io.println_error("gantry worker: " <> reason)
  ffi_host.exit_failure()
}
