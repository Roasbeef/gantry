//// The executor keeps one physical slot locked until the controller accepts
//// or fences its durable result. Core codecs validate assignments before
//// admission and completions before publication. The host owns Docker and
//// local custody.

import gantry/internal/ffi_host
import gantry/internal/ffi_worker
import gantry_core/graph
import gantry_core/protocol
import gleam/io
import gleam/json
import gleam/result

/// Run a remote executor using the configured physical slot and controller list.
///
/// ## Examples
///
/// ```sh
/// gleam run -m gantry/worker
/// ```
pub fn main() -> Nil {
  // A failed host adapter exits the service so its supervisor can recover custody.
  case ffi_worker.run(check_wire) {
    Ok(Nil) -> Nil
    Error(reason) -> {
      io.println_error(reason)
      ffi_host.exit_failure()
    }
  }
}

/// Reconstruct validated wire evidence before the host acts on it.
///
/// ## Examples
///
/// ```gleam
/// // check_wire(ffi_worker.Assignment, "{}") == Error(Nil)
/// ```
fn check_wire(
  kind: ffi_worker.Decoder,
  payload: String,
) -> Result(String, Nil) {
  // Assignment validation also bounds argv, paths and execution time.
  case kind {
    ffi_worker.Assignment -> {
      use assignment <- result.try(
        json.parse(payload, protocol.assignment_decoder())
        |> result.replace_error(Nil),
      )
      use Nil <- result.try(
        graph.validate_action(assignment.task.action)
        |> result.replace_error(Nil),
      )
      Ok(json.to_string(protocol.encode_assignment(assignment)))
    }
    ffi_worker.Completion ->
      json.parse(payload, protocol.completion_decoder())
      |> result.map(fn(receipt) {
        json.to_string(protocol.encode_completion(receipt))
      })
      |> result.replace_error(Nil)
  }
}
