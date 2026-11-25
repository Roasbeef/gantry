//// The worker keeps one physical slot locked until the controller accepts
//// or fences its durable result. The journal separates preparation, a
//// possible Docker start, and a recorded completion.

import envoy
import gantry/internal/ffi_host
import gantry/internal/ffi_worker
import gantry/worker/controllers
import gantry/worker/custody
import gantry/worker/docker
import gantry/worker/slot
import gantry_core/graph
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import simplifile

/// Run a remote executor using the configured physical slot and controller list.
///
/// ## Examples
///
/// ```sh
/// gleam run -m gantry/worker
/// ```
pub fn main() -> Nil {
  case boot() {
    Ok(#(current, network)) -> loop(current, slot.Cursor(network, None))
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
  use Nil <- result.try(docker.preflight())
  use raw_directory <- result.try(required("GANTRY_WORKER_DIR"))
  use directory <- result.try(worker_directory(raw_directory))
  use Nil <- result.try(ffi_worker.lock(directory <> "/slot.lock"))

  // A managed profile must preserve custody even if its journal is removed.
  use db <- result.try(case envoy.get("GANTRY_WORKER_GUARD") {
    Ok(profile) -> custody.open_managed(profile, directory, worker)
    Error(Nil) -> custody.open(directory <> "/custody.sqlite3", worker)
  })

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

/// Poll the controller or advance the recorded attempt until stopped.
fn loop(current: slot.Slot, cursor: slot.Cursor) -> Nil {
  // Only retry temporary faults. Stop when local custody cannot be trusted.
  case slot.step(current, cursor) {
    #(next, slot.Advanced) -> loop(current, next)
    #(next, slot.Idled) -> {
      process.sleep(1000)
      loop(current, next)
    }
    #(next, slot.Faulted(slot.Retry(reason))) -> {
      io.println_error("gantry worker: " <> reason)
      process.sleep(1000)
      loop(current, next)
    }
    #(_, slot.Faulted(slot.Stop(reason))) -> stop(reason)
  }
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
