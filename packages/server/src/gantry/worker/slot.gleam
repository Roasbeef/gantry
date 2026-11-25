//// One physical slot advances its journaled attempt one effect at a time.
//// `step` reads the persisted phase before it requests any new work, so a
//// restart resumes the same attempt and never claims a second one.
////
//// ## Flow
////
//// ```text
//// idle --claim 200--> Ready --execute--> Recorded --cleanup--> publish
////                                          |                     |
////  Interrupted --cleanup, reject---------->+        results 200/409
////                                                    acknowledge: idle
//// ```
////
//// | Phase       | Effect                                   | Invariant kept                                   |
//// | ----------- | ---------------------------------------- | ------------------------------------------------ |
//// | idle        | claim, then journal the assignment        | no second attempt exists while one is pending    |
//// | Ready       | clean by name, stage, mark started, run   | the start marker precedes the container start    |
//// | Interrupted | clean by name, record a rejection         | an action that may have run never runs again     |
//// | Recorded    | clean once, upload blobs, post the receipt | the result is durable before Docker is touched   |
////
//// A finished result is journaled before its Docker resources are removed.
//// Cleanup is idempotent and runs in the Recorded phase, so a cleanup fault
//// retries without discarding the result. The infrastructure faults that
//// still reach users as a failed action are the Interrupted rejection after
//// a restart or Docker fault once the container may have started, and
//// staging faults the worker classifies as the action's own (a bad archive
//// or an unsafe path). Everything before the start marker retries.

import gantry/blobs
import gantry/worker/controllers
import gantry/worker/custody
import gantry/worker/docker
import gantry_core/queue
import gleam/bit_array
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

/// The Docker effects a slot performs. Tests substitute a fake.
pub type Engine {
  Engine(
    execute: fn(
      String,
      queue.Assignment,
      controllers.Controllers,
      fn() -> Result(Nil, String),
      fn(BitArray) -> Result(String, String),
    ) -> Result(queue.Completion, docker.Fault),
    cleanup: fn(String) -> Result(Nil, docker.Fault),
  )
}

/// The slot's fixed identity, journal and Docker effects.
pub type Slot {
  Slot(
    directory: String,
    worker: String,
    pool: String,
    db: sqlight.Connection,
    engine: Engine,
  )
}

/// What the loop carries between steps: the preferred controller and the
/// attempt whose Docker resources are already removed.
pub type Cursor {
  Cursor(network: controllers.Controllers, cleaned: Option(String))
}

/// What one step accomplished. `Advanced` means work moved forward, so the
/// next step can start at once. `Idled` means the controller had nothing for
/// this slot. `Faulted` carries the fault, which says whether to retry.
pub type Verdict {
  Advanced
  Idled
  Faulted(Fault)
}

/// Retry transient faults. Stop when local custody cannot be trusted.
pub type Fault {
  Retry(reason: String)
  Stop(reason: String)
}

/// Choose an effect from the persisted phase before requesting any new work.
///
/// ## Examples
///
/// ```gleam
/// // slot.step(slot, Cursor(network, None))
/// ```
pub fn step(slot: Slot, cursor: Cursor) -> #(Cursor, Verdict) {
  // The journal's phase picks the effect. Only an empty journal may claim.
  case custody.pending(slot.db) {
    Error(reason) -> #(cursor, Faulted(Stop(reason)))
    Ok(None) -> claim(slot, cursor)
    Ok(Some(custody.Recorded(name, receipt))) ->
      recorded(slot, cursor, name, receipt)
    Ok(Some(custody.Interrupted(name, assignment))) -> {
      let outcome = {
        use Nil <- result.try(
          slot.engine.cleanup(name) |> result.map_error(cleanup_fault),
        )
        reject(
          slot,
          name,
          assignment,
          "worker interrupted before recording outcome",
        )
      }
      #(cursor, verdict(outcome))
    }
    Ok(Some(custody.Ready(name, assignment))) -> #(
      cursor,
      verdict(perform(slot, cursor.network, name, assignment)),
    )
  }
}

fn verdict(outcome: Result(Nil, Fault)) -> Verdict {
  case outcome {
    Ok(Nil) -> Advanced
    Error(fault) -> Faulted(fault)
  }
}

/// Persist the controller's assignment before the next step can execute it.
fn claim(slot: Slot, cursor: Cursor) -> #(Cursor, Verdict) {
  let request =
    json.object([
      #("worker", json.string(slot.worker)),
      #("pool", json.string(slot.pool)),
    ])

  // Only a 200 carries an assignment. A 204 means no eligible work.
  case send(cursor.network, http.Post, "/v1/claims", json.to_string(request)) {
    Error(fault) -> #(cursor, Faulted(fault))
    Ok(#(network, 204, _)) -> #(Cursor(..cursor, network:), Idled)
    Ok(#(network, 200, body)) -> {
      let outcome = admit(slot, body)
      #(Cursor(..cursor, network:), verdict(outcome))
    }
    Ok(#(network, status, _)) -> #(
      Cursor(..cursor, network:),
      Faulted(Retry("claim returned HTTP " <> int.to_string(status))),
    )
  }
}

/// Journal a claimed assignment after checking that it names this slot.
fn admit(slot: Slot, body: BitArray) -> Result(Nil, Fault) {
  use payload <- result.try(
    bit_array.to_string(body)
    |> result.replace_error(Stop("assignment is not UTF-8")),
  )
  use assignment <- result.try(
    custody.assignment(payload) |> result.map_error(Stop),
  )

  // The lease must name this exact capacity slot and pool.
  use Nil <- result.try(
    case
      queue.lease_worker(assignment.lease) == slot.worker
      && assignment.task.pool == slot.pool
    {
      True -> Ok(Nil)
      False -> Error(Stop("assignment does not match this worker and pool"))
    },
  )

  let identity =
    json.array(
      [
        json.string(slot.directory),
        json.string(slot.worker),
        json.string(assignment.run),
        json.string(assignment.task.action.name),
        json.int(queue.lease_serial(assignment.lease)),
      ],
      fn(value) { value },
    )
  let name =
    "gantry-" <> blobs.digest(bit_array.from_string(json.to_string(identity)))
  custody.claim(slot.db, name, assignment) |> result.map_error(Stop)
}

/// Run the assigned action and durably record its outcome. Docker resources
/// stay in place until the Recorded phase removes them.
fn perform(
  slot: Slot,
  network: controllers.Controllers,
  name: String,
  assignment: queue.Assignment,
) -> Result(Nil, Fault) {
  let result =
    slot.engine.execute(
      name,
      assignment,
      network,
      fn() { custody.mark_started(slot.db, name) },
      fn(bytes) { custody.spool(slot.db, bytes) },
    )

  // A finished action is recorded as it ended. Only a start fault retries.
  case result {
    Ok(completion) ->
      custody.record(slot.db, name, assignment, completion)
      |> result.map_error(Stop)
    Error(docker.Rejected(reason)) -> reject(slot, name, assignment, reason)
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

/// Release Docker resources once, then publish the saved receipt.
fn recorded(
  slot: Slot,
  cursor: Cursor,
  name: String,
  receipt: String,
) -> #(Cursor, Verdict) {
  // Cleanup is idempotent, so run it once per attempt and remember that.
  let cleaned = case cursor.cleaned {
    Some(done) if done == name -> Ok(cursor)
    _ ->
      slot.engine.cleanup(name)
      |> result.map_error(cleanup_fault)
      |> result.replace(Cursor(..cursor, cleaned: Some(name)))
  }

  // A cleanup fault keeps the receipt and retries on the next step.
  case cleaned {
    Error(fault) -> #(cursor, Faulted(fault))
    Ok(cursor) ->
      // Publication releases the slot only after the controller answers.
      case publish(slot, cursor.network, name, receipt) {
        Ok(network) -> #(Cursor(network:, cleaned: None), Advanced)
        Error(fault) -> #(cursor, Faulted(fault))
      }
  }
}

/// Send journaled bytes before publishing the receipt that refers to them.
fn publish(
  slot: Slot,
  network: controllers.Controllers,
  name: String,
  receipt: String,
) -> Result(controllers.Controllers, Fault) {
  // Upload only what the receipt names. A rejected action can leave other
  // spooled bytes that no controller will ever read.
  use digests <- result.try(
    custody.referenced(receipt) |> result.map_error(Stop),
  )
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
      |> result.replace(next)
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
