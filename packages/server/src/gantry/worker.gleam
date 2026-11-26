//// The worker owns one physical slot until the controller accepts or fences
//// its durable result. The journal separates preparation, a possible Docker
//// start, and a recorded completion.
////
//// ## Flow
////
//// `main` calls `boot`, which opens the journal and takes its exclusive
//// lock. `supervise` then starts the slot loop under a supervisor, and
//// `on_message` advances the slot once per tick. `poll_delay` spaces ticks
//// after an idle poll or a retryable fault. SIGTERM reaches `supervise` as a
//// message, which `await_ending` tells apart from the supervisor's exit, and
//// `drain` takes over from there.
////
//// ```text
//// main -> boot -> supervise -> on_message -> slot.step -> next Tick
////                     |
////           await_ending: SIGTERM -> drain -> Drain -> idle journal -> exit 0
////                                 \-- deadline -> release -> exit
//// ```
////
//// | Verdict           | Next Tick                                  | Invariant kept                          |
//// | ----------------- | ------------------------------------------ | --------------------------------------- |
//// | `Advanced`        | at once, with the idle streak reset        | work is never delayed after progress    |
//// | `Idled`           | after a jittered delay, up to 2 s          | idle polling stays below one per second |
//// | `Faulted(Retry)`  | after the same delay                       | a transient fault never spins           |
//// | `Faulted(Stop)`   | none, the VM exits                         | untrusted custody never continues       |
////
//// ## Drain
////
//// On SIGTERM the loop stops claiming. It finishes the attempt its journal
//// holds, records and publishes it, and reports an idle journal, and the VM
//// exits 0. `drain` waits for that as a Weft task with the drain deadline,
//// `GANTRY_WORKER_DRAIN` seconds (60 by default). Past the deadline it kills
//// the supervisor, which ends the loop and, through the Weft scope of
//// `docker start`, removes the container. `release` then records the
//// attempt `Interrupted` and publishes it, retrying transient faults 15
//// times a second apart, so the controller reassigns the action at once instead of
//// failing the run. A release that cannot reach a controller leaves the
//// receipt in the journal for the next start.
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
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import simplifile
import weft
import weft/actor

/// The first idle or retry delay ceiling, in milliseconds.
const first_delay = 500

/// The delay ceiling once a streak of idle polls has built up.
const longest_delay = 2000

/// How long a drain waits for the current attempt by default, in seconds.
const default_drain = 60

/// How long the drain deadline waits for the stopped loop to exit.
const stop_wait = 5000

/// How many times, a second apart, the drain deadline tries to release the
/// attempt. Docker may still be removing the container the Weft scope began
/// removing, and a controller may be briefly unreachable.
const release_tries = 15

/// Run a remote executor using the configured physical slot and controller list.
///
/// ## Examples
///
/// ```sh
/// gleam run -m gantry/worker
/// ```
pub fn main() -> Nil {
  case boot() {
    Ok(#(current, network, drain)) -> supervise(current, network, drain)
    Error(reason) -> stop(reason)
  }
}

/// Validate the slot configuration and acquire its journal exclusively.
fn boot() -> Result(#(slot.Slot, controllers.Controllers, Int), String) {
  use worker <- result.try(identity("GANTRY_WORKER_ID"))
  use pool <- result.try(identity("GANTRY_POOL"))
  use endpoint <- result.try(required("GANTRY_ENDPOINT"))
  use token <- result.try(required("GANTRY_WORKER_TOKEN"))
  use network <- result.try(controllers.new(endpoint, token))
  use limits <- result.try(docker.limits())
  use drain <- result.try(drain_deadline())
  use raw_directory <- result.try(required("GANTRY_WORKER_DIR"))
  use directory <- result.try(worker_directory(raw_directory))

  // Opening the journal takes its exclusive lock before anything else runs.
  // A managed profile must preserve custody even if its journal is removed.
  use db <- result.try(case envoy.get("GANTRY_WORKER_GUARD") {
    Ok(profile) -> custody.open_managed(profile, directory, worker)
    Error(Nil) -> custody.open(directory <> "/custody.sqlite3", worker)
  })

  use Nil <- result.try(docker.preflight())
  use Nil <- result.try(docker.check_sandboxes(limits))
  use Nil <- result.try(docker.try_sandboxes(limits))

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
  Ok(#(slot.Slot(directory, worker, pool, db, engine), network, drain))
}

/// Read the drain deadline in seconds and return it in milliseconds.
fn drain_deadline() -> Result(Int, String) {
  case envoy.get("GANTRY_WORKER_DRAIN") {
    Error(Nil) -> Ok(default_drain * 1000)
    Ok(raw) ->
      case int.parse(raw) {
        Ok(seconds) if seconds >= 0 -> Ok(seconds * 1000)
        _ -> Error("GANTRY_WORKER_DRAIN must be a whole number of seconds")
      }
  }
}

/// What the slot loop receives: its own timer, or a request to drain that
/// is answered once the journal holds no attempt.
type Message {
  Tick
  Drain(drained: process.Subject(Nil))
}

/// The slot, the loop's cursor, the count of consecutive empty polls, and
/// where to report an idle journal once a drain has begun.
type Loop {
  Loop(
    current: slot.Slot,
    cursor: slot.Cursor,
    streak: Int,
    self: process.Subject(Message),
    draining: Option(process.Subject(Nil)),
  )
}

/// What ends the wait in `supervise`.
type Ending {
  SupervisorExited
  Terminated
  Unrelated
}

/// Run the slot loop under a supervisor and exit when the supervisor does,
/// or drain when the VM receives SIGTERM.
fn supervise(
  current: slot.Slot,
  network: controllers.Controllers,
  drain_ms: Int,
) -> Nil {
  let name = process.new_name("gantry_worker_slot")
  let loop =
    actor.new_with_initialiser(5000, fn(self) {
      actor.initialised(Loop(current, slot.Cursor(network, None), 0, self, None))
      |> actor.returning(self)
      |> actor.continuing(Tick)
      |> Ok
    })
    |> actor.named(name)
    |> actor.on_message(on_message)

  // A loop that keeps crashing exhausts the tolerance and ends the VM, so the
  // service manager restarts the worker with a clean process state.
  let tree =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.restart_tolerance(intensity: 5, period: 60)
    |> supervisor.add(actor.supervised(loop))

  // The VM exits with the supervisor, so a dead slot never idles unnoticed.
  // SIGTERM arrives here as a message once the loop is running.
  case supervisor.start(tree) {
    Ok(started) -> {
      ffi_host.forward_terminate()
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(
          process.monitor(started.pid),
          fn(_down) { SupervisorExited },
        )
        |> process.select_other(fn(message) {
          case ffi_host.terminate_signal(message) {
            Ok(Nil) -> Terminated
            Error(Nil) -> Unrelated
          }
        })

      // Only these two endings leave `await_ending`.
      case await_ending(selector) {
        SupervisorExited | Unrelated -> stop("worker supervisor exited")
        Terminated -> drain(current, network, name, started.pid, drain_ms)
      }
    }
    Error(_) -> stop("cannot start the worker supervisor")
  }
}

/// Wait for the supervisor to exit or for SIGTERM, ignoring other messages.
fn await_ending(selector: process.Selector(Ending)) -> Ending {
  case process.selector_receive_forever(selector) {
    Unrelated -> await_ending(selector)
    SupervisorExited -> SupervisorExited
    Terminated -> Terminated
  }
}

/// Let the loop finish its attempt and stop claiming, within the deadline.
/// Past it, stop the loop and give the attempt up as `Interrupted`.
fn drain(
  current: slot.Slot,
  network: controllers.Controllers,
  name: process.Name(Message),
  supervisor: process.Pid,
  within: Int,
) -> Nil {
  io.println_error(
    "gantry worker: draining for up to " <> int.to_string(within / 1000) <> " s",
  )
  let outcomes =
    weft.new([
      fn() -> Result(Nil, Nil) {
        // A loop that exits, even to be restarted, forgets the drain, so its
        // exit ends the wait early and the attempt is released.
        use pid <- result.try(process.named(name))
        let monitor = process.monitor(pid)
        let drained = process.new_subject()
        process.send(process.named_subject(name), Drain(drained))
        process.new_selector()
        |> process.select_map(drained, Ok)
        |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
        |> process.selector_receive_forever
      },
    ])
    |> weft.deadline(within)
    |> weft.start

  // A drained journal holds nothing, so the VM can stop at once.
  case outcomes {
    [weft.Completed(_, Nil)] -> {
      io.println_error("gantry worker: drained")
      ffi_host.exit(0)
    }
    _ -> {
      io.println_error("gantry worker: drain deadline passed, releasing")

      // A loop still alive may still write the journal, so leave it alone.
      case halt_loop(name, supervisor) {
        Ok(Nil) -> release(current, network, release_tries)
        Error(Nil) -> stop("slot loop did not exit; the next start releases")
      }
    }
  }
}

/// Give the attempt up with `slot.release`, retrying transient faults a
/// bounded number of times. An unpublished receipt stays in the journal for
/// the next start.
fn release(
  current: slot.Slot,
  network: controllers.Controllers,
  tries: Int,
) -> Nil {
  // Each retry waits a second, as the slot loop does after a fault.
  case slot.release(current, slot.Cursor(network, None)) {
    Ok(Nil) -> ffi_host.exit(0)
    Error(slot.Retry(reason)) if tries > 1 -> {
      io.println_error("gantry worker: " <> reason)
      process.sleep(1000)
      release(current, network, tries - 1)
    }
    Error(slot.Retry(reason)) | Error(slot.Stop(reason)) -> stop(reason)
  }
}

/// Unlink and kill the supervisor, then wait for the loop to exit, so
/// `slot.release` reads a journal nothing else is writing. Killing the loop
/// also ends the Weft scope of a running `docker start`, which removes the
/// container.
fn halt_loop(
  name: process.Name(Message),
  supervisor: process.Pid,
) -> Result(Nil, Nil) {
  let loop = process.named(name) |> result.map(process.monitor)

  // The supervisor is linked to this process, which must outlive it.
  process.unlink(supervisor)
  process.kill(supervisor)

  // A loop that already exited leaves nothing to wait for. One that does
  // not exit in time may still write the journal, so nothing is released.
  case loop {
    Error(Nil) -> Ok(Nil)
    Ok(monitor) ->
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(_down) { Nil })
      |> process.selector_receive(stop_wait)
  }
}

/// Advance the slot once and schedule the next tick from its verdict. While
/// draining, an idle journal is reported instead of claiming more work.
fn on_message(state: Loop, message: Message) -> actor.Next(Loop, Message) {
  case message, state.draining {
    // The tick already in flight comes next, so a drain schedules nothing.
    Drain(drained), _ -> actor.continue(Loop(..state, draining: Some(drained)))
    Tick, None -> advance(state)
    Tick, Some(drained) ->
      case custody.pending(state.current.db) {
        Ok(None) -> {
          process.send(drained, Nil)
          actor.continue(state)
        }
        Ok(Some(_)) -> advance(state)
        Error(reason) -> {
          stop(reason)
          actor.stop()
        }
      }
  }
}

/// Run one slot step and schedule the next tick from its verdict.
fn advance(state: Loop) -> actor.Next(Loop, Message) {
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
