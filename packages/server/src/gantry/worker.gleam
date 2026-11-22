//// The worker keeps one physical slot locked until the controller accepts
//// or fences its durable result. The journal separates preparation, a
//// possible Docker start, and a recorded completion.

import gantry/blobs
import gantry/internal/ffi_host
import gantry/internal/ffi_worker
import gantry/worker/controllers
import gantry/worker/custody
import gantry/worker/docker
import gantry_core/graph
import gantry_core/queue
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlight

type Slot {
  Slot(
    directory: String,
    worker: String,
    pool: String,
    db: sqlight.Connection,
    limits: docker.Limits,
  )
}

type Step {
  Idle(controllers.Controllers)
  Advance(controllers.Controllers)
}

type Fault {
  Retry(reason: String)
  Stop(reason: String)
}

/// Run a remote executor using the configured physical slot and controller list.
///
/// ## Examples
///
/// ```sh
/// gleam run -m gantry/worker
/// ```
pub fn main() -> Nil {
  case boot() {
    Ok(#(slot, network)) -> loop(slot, network)
    Error(reason) -> stop(reason)
  }
}

/// Validate the slot configuration and acquire its journal exclusively.
fn boot() -> Result(#(Slot, controllers.Controllers), String) {
  use worker <- result.try(identity("GANTRY_WORKER_ID"))
  use pool <- result.try(identity("GANTRY_POOL"))
  use endpoint <- result.try(required("GANTRY_ENDPOINT"))
  use token <- result.try(required("GANTRY_WORKER_TOKEN"))
  use network <- result.try(controllers.new(endpoint, token))
  use limits <- result.try(docker.limits())
  use raw_directory <- result.try(required("GANTRY_WORKER_DIR"))
  use directory <- result.try(worker_directory(raw_directory))
  use Nil <- result.try(ffi_worker.lock(directory <> "/slot.lock"))
  use db <- result.try(custody.open(directory <> "/custody.sqlite3", worker))
  Ok(#(Slot(directory, worker, pool, db, limits), network))
}

/// Poll the controller or advance the recorded attempt until stopped.
fn loop(slot: Slot, network: controllers.Controllers) -> Nil {
  // Only retry temporary faults. Stop when local custody cannot be trusted.
  case step(slot, network) {
    Ok(Advance(next)) -> loop(slot, next)
    Ok(Idle(next)) -> {
      process.sleep(1000)
      loop(slot, next)
    }
    Error(Retry(reason)) -> {
      io.println_error("gantry worker: " <> reason)
      process.sleep(1000)
      loop(slot, network)
    }
    Error(Stop(reason)) -> stop(reason)
  }
}

/// Choose an effect from the persisted phase before requesting any new work.
fn step(slot: Slot, network: controllers.Controllers) -> Result(Step, Fault) {
  use pending <- result.try(custody.pending(slot.db) |> result.map_error(Stop))

  // A recorded or interrupted attempt owns the slot until it is resolved.
  case pending {
    None -> claim(slot, network)
    Some(custody.Recorded(name, receipt)) ->
      publish(slot, network, name, receipt)
    Some(custody.Interrupted(name, assignment)) -> {
      use Nil <- result.try(
        docker.cleanup(slot.directory, name) |> result.map_error(cleanup_fault),
      )
      reject(
        slot,
        name,
        assignment,
        "worker interrupted before recording outcome",
      )
      |> result.replace(Advance(network))
    }
    Some(custody.Ready(name, assignment)) ->
      perform(slot, network, name, assignment)
      |> result.replace(Advance(network))
  }
}

/// Persist the controller's assignment before the next loop can execute it.
fn claim(slot: Slot, network: controllers.Controllers) -> Result(Step, Fault) {
  let request =
    json.object([
      #("worker", json.string(slot.worker)),
      #("pool", json.string(slot.pool)),
    ])
  use #(next, status, body) <- result.try(send(
    network,
    http.Post,
    "/v1/claims",
    json.to_string(request),
  ))

  // Only a successful claim response carries an assignment.
  case status {
    204 -> Ok(Idle(next))
    200 -> {
      use payload <- result.try(
        bit_array.to_string(body)
        |> result.replace_error(Stop("assignment is not UTF-8")),
      )
      use assignment <- result.try(
        custody.assignment(payload) |> result.map_error(Stop),
      )

      // The lease must name this exact capacity slot and pool.
      let owned = case
        assignment.lease.worker == slot.worker
        && assignment.task.pool == slot.pool
      {
        True -> Ok(Nil)
        False -> Error(Stop("assignment does not match this worker and pool"))
      }

      use Nil <- result.try(owned)

      let identity =
        json.array(
          [
            json.string(slot.directory),
            json.string(slot.worker),
            json.string(assignment.run),
            json.string(assignment.task.action.name),
            json.int(assignment.lease.serial),
          ],
          fn(value) { value },
        )
      let name =
        "gantry-"
        <> blobs.digest(bit_array.from_string(json.to_string(identity)))
      custody.claim(slot.db, name, assignment)
      |> result.map_error(Stop)
      |> result.replace(Advance(next))
    }
    _ -> Error(Retry("claim returned HTTP " <> int.to_string(status)))
  }
}

/// Run the assigned action and durably record its outcome after cleanup.
fn perform(
  slot: Slot,
  network: controllers.Controllers,
  name: String,
  assignment: queue.Assignment,
) -> Result(Nil, Fault) {
  let result =
    docker.execute(
      slot.directory,
      name,
      assignment,
      slot.limits,
      network,
      fn() { custody.mark_started(slot.db, name) },
      fn(bytes) { custody.spool(slot.db, bytes) },
    )

  // Release Docker resources before recording a successful attempt result.
  case result {
    Ok(completion) -> {
      use Nil <- result.try(
        docker.cleanup(slot.directory, name) |> result.map_error(cleanup_fault),
      )
      custody.record(slot.db, name, assignment, completion)
      |> result.map_error(Stop)
    }
    Error(docker.Rejected(reason)) -> {
      use Nil <- result.try(
        docker.unstage(slot.directory, name) |> result.map_error(cleanup_fault),
      )
      reject(slot, name, assignment, reason)
    }
    Error(docker.Unavailable(reason)) -> Error(Retry(reason))
    Error(docker.JournalFault(reason)) -> Error(Stop(reason))
  }
}

/// Stage the reason as a log before making the failure publishable.
fn reject(
  slot: Slot,
  name: String,
  assignment: queue.Assignment,
  reason: String,
) -> Result(Nil, Fault) {
  use log <- result.try(
    custody.spool(slot.db, bit_array.from_string(reason))
    |> result.map_error(Stop),
  )
  custody.record(slot.db, name, assignment, queue.Rejected(reason, log))
  |> result.map_error(Stop)
}

/// Send journaled bytes before publishing the receipt that refers to them.
fn publish(
  slot: Slot,
  network: controllers.Controllers,
  name: String,
  receipt: String,
) -> Result(Step, Fault) {
  use digests <- result.try(custody.digests(slot.db) |> result.map_error(Stop))
  use next <- result.try(
    list.try_fold(digests, network, fn(network, digest) {
      use bytes <- result.try(
        custody.blob(slot.db, digest) |> result.map_error(Stop),
      )
      use #(next, status, _) <- result.try(
        controllers.call(
          network,
          http.Put,
          "/v1/blobs/" <> digest,
          bytes,
          "application/octet-stream",
        )
        |> result.map_error(network_fault),
      )

      // Advance publication only after the blob is acknowledged.
      case status {
        200 -> Ok(next)
        _ -> Error(Retry("blob upload returned HTTP " <> int.to_string(status)))
      }
    }),
  )
  use #(next, status, _) <- result.try(send(
    next,
    http.Post,
    "/v1/results",
    receipt,
  ))

  // An accepted or fenced receipt releases this slot for its next claim.
  case status {
    200 | 409 ->
      custody.acknowledge(slot.db, name)
      |> result.map_error(Stop)
      |> result.replace(Advance(next))
    _ -> Error(Retry("completion returned HTTP " <> int.to_string(status)))
  }
}

/// Send one JSON request with the slot's controller credential.
fn send(
  network: controllers.Controllers,
  method: http.Method,
  path: String,
  payload: String,
) -> Result(#(controllers.Controllers, Int, BitArray), Fault) {
  controllers.call(
    network,
    method,
    path,
    bit_array.from_string(payload),
    "application/json",
  )
  |> result.map_error(network_fault)
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
  case ffi_host.getenv(key) {
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

fn network_fault(fault: controllers.Fault) -> Fault {
  case fault {
    controllers.Offline(reason) -> Retry(reason)
    controllers.Invalid(reason) -> Stop(reason)
  }
}

fn cleanup_fault(fault: docker.Fault) -> Fault {
  case fault {
    docker.Unavailable(reason) -> Retry(reason)
    docker.Rejected(reason) | docker.JournalFault(reason) -> Stop(reason)
  }
}

fn stop(reason: String) -> Nil {
  io.println_error("gantry worker: " <> reason)
  ffi_host.exit_failure()
}
