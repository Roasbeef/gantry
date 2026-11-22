//// One quorum snapshot holds the proof deployment's queue metadata. Every
//// mutation compares the exact bytes read before computing its proposal.
//// A proposal with no changes confirms the same bytes with the Ra leader
//// and its quorum. A losing proposal recomputes from a fresh snapshot.
//// Each mutation reads and writes the full document. The 4 MiB ceiling
//// bounds replicated metadata and makes this unsuitable for unbounded history.

import gantry/internal/ffi_khepri.{
  type ProposalOutcome, Accepted, ConfirmedQuiet, NeedsClaim, SnapshotChanged,
}
import gantry_core/protocol
import gantry_core/queue
import gleam/json
import gleam/option.{type Option, None}
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

/// Probe queue quorum access for a gateway's backend selection.
///
/// ## Examples
///
/// ```gleam
/// // store.ready()
/// ```
pub fn ready() -> Result(Nil, String) {
  ffi_khepri.ready()
}

/// Run a pure proposal and return its receipt after a majority confirms the
/// unchanged snapshot or commits a mutation.
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

/// Return a confirmed empty poll or run the full durable claim decision.
///
/// ## Examples
///
/// ```gleam
/// // store.claim("worker", "linux", 0)
/// ```
pub fn claim(
  worker: String,
  pool: String,
  now: Int,
) -> Result(Option(queue.Assignment), String) {
  use confirmed <- result.try(ffi_khepri.confirm_quiet())

  // A quiet snapshot cannot offer a lease to any worker.
  case confirmed {
    ConfirmedQuiet -> Ok(None)
    NeedsClaim ->
      change(fn(state) { Ok(queue.claim(state, worker, pool, now)) })
  }
}

/// Recompute a pure transition from the latest snapshot after a competing write.
fn attempt(
  propose: fn(queue.State) -> Result(#(queue.State, a), String),
  remaining: Int,
) -> Result(a, String) {
  use #(prior, state) <- result.try(snapshot())
  use #(next, receipt) <- result.try(propose(state))

  // A quorum can confirm an unchanged receipt without appending a write.
  use accepted <- result.try(case next == state {
    True -> confirm(prior, state)
    False -> commit(prior, next)
  })

  // A competing write invalidates the proposal and its receipt.
  case accepted, remaining {
    Accepted, _ -> Ok(receipt)
    SnapshotChanged, 1 -> Error("queue contention exceeded retry budget")
    SnapshotChanged, _ -> attempt(propose, remaining - 1)
  }
}

/// Remember a quiet snapshot after it authorizes an unchanged receipt.
fn confirm(
  prior: String,
  state: queue.State,
) -> Result(ProposalOutcome, String) {
  use accepted <- result.try(ffi_khepri.confirm(prior))

  // Pending and active work require the full decision even on a snapshot hit.
  case accepted == Accepted && queue.quiescent(state) {
    True -> ffi_khepri.remember_quiet(prior)
    False -> Nil
  }

  Ok(accepted)
}

/// Replace the expected snapshot with a bounded mutation.
fn commit(prior: String, next: queue.State) -> Result(ProposalOutcome, String) {
  let bytes = encode(next)

  // Reject oversized metadata before it reaches the replicated log.
  case string.byte_size(bytes) > max_bytes {
    True -> Error("queue snapshot exceeds 4 MiB")
    False -> ffi_khepri.swap(prior, bytes)
  }
}
