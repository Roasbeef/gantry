//// One quorum snapshot holds the proof deployment's queue metadata. Every
//// successful change compares the exact bytes read before computing its
//// proposal. A losing writer recomputes from a fresh fenced snapshot.
//// Each mutation reads and writes the full document. The 4 MiB ceiling
//// bounds replicated metadata and makes this unsuitable for unbounded history.

import gantry/internal/ffi_khepri
import gantry_core/protocol
import gantry_core/queue
import gleam/json
import gleam/result
import gleam/string

const max_bytes = 4_194_304

/// Open this node's durable replica. On a fresh disk an empty seed bootstraps
/// a cluster, and a remote seed joins its existing cluster.
///
/// ## Examples
///
/// ```gleam
/// // store.boot("/var/lib/gantry", "gantry1@controller1")
/// ```
pub fn boot(data_dir: String, seed: String) -> Result(Nil, String) {
  ffi_khepri.boot(data_dir, seed, queue.empty() |> encode)
}

fn encode(state: queue.State) -> String {
  state |> protocol.encode_state |> json.to_string
}

/// Decode the fenced document and retain its exact bytes for conditional replacement.
fn snapshot() -> Result(#(String, queue.State), String) {
  use bytes <- result.try(ffi_khepri.read())
  use state <- result.try(
    json.parse(bytes, protocol.state_decoder())
    |> result.replace_error("invalid durable queue snapshot"),
  )
  Ok(#(bytes, state))
}

/// Read a quorum-fenced queue snapshot.
///
/// ## Examples
///
/// ```gleam
/// // store.read()
/// ```
pub fn read() -> Result(queue.State, String) {
  use #(_, state) <- result.try(snapshot())
  Ok(state)
}

/// Run a pure proposal and return its receipt only after the majority commits.
/// A storage timeout leaves the outcome unknown. Recover by operation identity.
///
/// ## Examples
///
/// ```gleam
/// // store.change(fn(state) { Ok(#(state, Nil)) })
/// ```
pub fn change(
  propose: fn(queue.State) -> Result(#(queue.State, a), String),
) -> Result(a, String) {
  attempt(propose, 8)
}

/// Recompute a pure transition from the latest snapshot after a competing write.
fn attempt(
  propose: fn(queue.State) -> Result(#(queue.State, a), String),
  remaining: Int,
) -> Result(a, String) {
  use #(prior, state) <- result.try(snapshot())
  use #(next, receipt) <- result.try(propose(state))
  let bytes = encode(next)

  // Reject oversized metadata before it reaches the replicated log.
  case string.byte_size(bytes) > max_bytes {
    True -> Error("queue snapshot exceeds 4 MiB")
    False -> {
      use committed <- result.try(ffi_khepri.swap(prior, bytes))

      // Return the receipt on commit. Recompute a losing proposal within the retry budget.
      case committed, remaining {
        True, _ -> Ok(receipt)
        False, 1 -> Error("queue contention exceeded retry budget")
        False, _ -> attempt(propose, remaining - 1)
      }
    }
  }
}
