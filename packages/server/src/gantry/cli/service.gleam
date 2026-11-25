//// One supervised child process: the local controller or a worker started
//// by onboarding. A Weft actor owns the child's port, so every event about
//// the child, its output, its exit, and a request to stop it, is handled
//// in one place and in order.
////
//// ## Flow
////
//// `start` opens the port inside the actor's initialiser, so the actor is
//// the port owner from the first byte. The child runs as
//// `setpriv --pdeathsig TERM PROGRAM` under the env tool, which applies the
//// variable changes and execs in place, as `open` builds it. Each port child
//// starts in a session of its own, so its pid is its process group ID, and
//// the death signal ends it if this VM disappears without a teardown, such
//// as on SIGINT, SIGTERM, or a crash.
////
//// `handle` appends output to the log, records the exit and answers anyone
//// waiting in `await_first` or asking `running`, which reads `is_running`. `stop` is the graceful teardown:
//// SIGTERM to the group, then SIGKILL to the group after ten seconds if the
//// child is still running, and a final SIGKILL sweep once it exits so no
//// grandchild outlives the group.
////
//// | State | Event | Next |
//// | --- | --- | --- |
//// | `Running` | output | `Running`, bytes appended to the log |
//// | `Running` | exit | `Exited`, waiters answered |
//// | `Running` | stop | `Stopping`, group sent SIGTERM, deadline armed |
//// | `Stopping` | deadline | `Stopping`, group sent SIGKILL |
//// | `Stopping` | exit | `Exited`, group swept, stop callers answered |
//// | `Exited` | stop | `Exited`, answered at once |

import gantry/internal/ffi_host.{type ServicePort}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/result
import simplifile
import weft/actor

/// How to start one child.
pub type Spec {
  Spec(
    /// A name for messages and logs, such as "controller".
    name: String,
    /// The program to supervise.
    program: String,
    /// Arguments after the program.
    arguments: List(String),
    /// Variables to set, then variables to remove, for the child only.
    set: List(#(String, String)),
    unset: List(String),
    /// The child's working directory.
    directory: String,
    /// The private log file that receives the child's output.
    log: String,
  )
}

/// A running supervised child.
pub opaque type Service {
  Service(name: String, subject: Subject(Message))
}

/// Which child exited first, and its status.
pub type Exit {
  Exit(name: String, status: Int)
}

type Life {
  Running
  Stopping
  Exited(status: Int)
}

type State {
  State(
    name: String,
    port: ServicePort,
    group: Int,
    log: String,
    life: Life,
    self: Subject(Message),
    waiting: List(Subject(Exit)),
    stopping: List(Subject(Nil)),
  )
}

type Message {
  Event(ffi_host.ServiceEvent)
  Await(reply: Subject(Exit))
  Stop(reply: Subject(Nil))
  Deadline
  Alive(reply: Subject(Life))
  Ignored
}

/// How long a group has to exit after SIGTERM before it is killed.
const grace_milliseconds = 10_000

/// Start a child under its own actor.
///
/// ## Examples
///
/// ```gleam
/// // service.start(service.Spec("controller", bin, [], env, [], dir, log))
/// ```
pub fn start(spec: Spec) -> Result(Service, String) {
  let opened =
    actor.new_with_initialiser(5000, fn(subject) {
      use port <- result.try(open(spec))
      use group <- result.try(
        ffi_host.service_pid(port)
        |> result.map_error(fn(_) { "cannot read the pid of " <> spec.name }),
      )
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_other(fn(message) {
          case ffi_host.service_event(message) {
            Ok(event) -> Event(event)
            Error(Nil) -> Ignored
          }
        })
      State(spec.name, port, group, spec.log, Running, subject, [], [])
      |> actor.initialised
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start

  // A start failure names the child, so the caller can report it.
  case opened {
    Ok(started) -> Ok(Service(spec.name, started.data))
    Error(_) -> Error("could not start the " <> spec.name)
  }
}

/// Open the child's port after truncating its private log.
fn open(spec: Spec) -> Result(ServicePort, String) {
  use Nil <- result.try(
    simplifile.write_bits(spec.log, <<>>)
    |> result.try(fn(_) { simplifile.set_permissions_octal(spec.log, 0o600) })
    |> result.map_error(fn(_) { "cannot create " <> spec.log }),
  )
  let arguments =
    list.flatten([
      list.flat_map(spec.unset, fn(key) { ["-u", key] }),
      ["setpriv", "--pdeathsig", "TERM", spec.program],
      spec.arguments,
    ])

  // Values, credentials among them, travel in the port environment so they
  // never appear on an argument list in /proc. The env tool only removes.
  ffi_host.open_service("env", arguments, spec.set, spec.directory)
}

/// Apply one event to the child's state. See the transition table.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message, state.life {
    Event(ffi_host.Output(bytes)), _ -> {
      let _ = simplifile.append_bits(state.log, bytes)
      actor.continue(state)
    }

    // The leader is gone. Sweep the rest of its group, then answer.
    Event(ffi_host.Exited(status)), _ -> {
      signal(state.group, "KILL")
      list.each(state.waiting, process.send(_, Exit(state.name, status)))
      list.each(state.stopping, process.send(_, Nil))
      actor.continue(
        State(..state, life: Exited(status), waiting: [], stopping: []),
      )
    }

    Await(reply), Exited(status) -> {
      process.send(reply, Exit(state.name, status))
      actor.continue(state)
    }
    Await(reply), Running | Await(reply), Stopping ->
      actor.continue(State(..state, waiting: [reply, ..state.waiting]))

    Stop(reply), Exited(_) -> {
      process.send(reply, Nil)
      actor.continue(state)
    }

    // A first stop asks the group to exit and arms the kill deadline.
    Stop(reply), Running -> {
      signal(state.group, "TERM")
      process.send_after(state.self, grace_milliseconds, Deadline)
      actor.continue(
        State(..state, life: Stopping, stopping: [reply, ..state.stopping]),
      )
    }
    Stop(reply), Stopping ->
      actor.continue(State(..state, stopping: [reply, ..state.stopping]))

    Deadline, Stopping -> {
      signal(state.group, "KILL")
      actor.continue(state)
    }
    Deadline, Running | Deadline, Exited(_) -> actor.continue(state)

    Alive(reply), life -> {
      process.send(reply, life)
      actor.continue(state)
    }
    Ignored, _ -> actor.continue(state)
  }
}

fn is_running(life: Life) -> Bool {
  case life {
    Running | Stopping -> True
    Exited(_) -> False
  }
}

/// Signal every process in a group. A group that is already empty is
/// the outcome a teardown wants, so a failed signal is ignored.
fn signal(group: Int, name: String) -> Nil {
  let _ =
    ffi_host.run(
      "kill",
      ["-" <> name, "--", "-" <> int.to_string(group)],
      [],
      5000,
    )
  Nil
}

/// Whether the child is still running.
///
/// ## Examples
///
/// ```gleam
/// // service.running(controller)
/// ```
pub fn running(service: Service) -> Bool {
  is_running(process.call(service.subject, 5000, Alive))
}

/// Wait for the first of several children to exit.
///
/// ## Examples
///
/// ```gleam
/// // service.await_first([controller, worker])
/// ```
pub fn await_first(services: List(Service)) -> Exit {
  let reply = process.new_subject()
  list.each(services, fn(service) {
    process.send(service.subject, Await(reply))
  })
  process.receive_forever(reply)
}

/// Stop a child and its process group, waiting until the leader has exited.
///
/// ## Examples
///
/// ```gleam
/// // service.stop(worker)
/// ```
pub fn stop(service: Service) -> Nil {
  let reply = process.new_subject()
  process.send(service.subject, Stop(reply))

  // The deadline inside the actor kills the group, so the wait is bounded
  // by the grace period plus the time a killed process takes to be reaped.
  let _ = process.receive(reply, grace_milliseconds + 15_000)
  Nil
}
