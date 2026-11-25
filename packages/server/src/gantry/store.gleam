//// One quorum snapshot holds the proof deployment's queue metadata. Every
//// mutation compares the exact bytes read before computing its proposal.
//// A proposal with no changes confirms the same bytes with the Ra leader
//// and its quorum. A losing proposal recomputes from a fresh snapshot.
//// Each mutation reads and writes the full document. The 4 MiB ceiling
//// bounds replicated metadata and makes this unsuitable for unbounded history.
////
//// ## Policy in Gleam
////
//// The Erlang bridge performs single Khepri, Ra and ETS calls. This module
//// decides what to do with them: whether a node bootstraps or joins, which
//// marker it trusts, how large a snapshot may be, and when a remembered
//// quiet snapshot may answer a poll.
////
//// | Marker file | Seed | Decision |
//// | --- | --- | --- |
//// | Names this node | any | Reopen the store, and refuse if Ra lost its server |
//// | Names another node | any | Refuse to start |
//// | Absent | empty, or this node | Bootstrap a singleton |
//// | Absent | longer than 255 bytes | Refuse to start |
//// | Absent | another node | Join that node's cluster |
////
//// A joined or bootstrapped node writes the marker last, after Ra's
//// directory is on disk, so a crash before the marker leaves a node that
//// starts over instead of one that claims an incomplete identity.

import gantry/fault.{type Fault}
import gantry/internal/ffi_host
import gantry/internal/ffi_khepri.{
  type ProposalOutcome, Accepted, SnapshotChanged,
}
import gantry_core/protocol
import gantry_core/queue
import gleam/bit_array
import gleam/crypto
import gleam/json
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import simplifile

/// The ceiling on one replicated snapshot, in bytes.
const max_bytes = 4_194_304

/// The longest accepted seed node name.
const max_seed_bytes = 255

/// What the marker file says about this node's identity.
pub type Marker {
  Absent
  Names(node: String)
}

/// How a node opens its replica.
pub type Opening {
  Reopen
  Bootstrap
  Join(seed: String)
}

/// Whether a worker poll can return before running the full claim decision.
type QuietCheck {
  ConfirmedQuiet
  NeedsClaim
}

/// Decide how this node opens its replica from its marker and configured
/// seed. The seed is operator configuration supplied once at boot.
///
/// ## Examples
///
/// ```gleam
/// assert store.opening(store.Absent, "a@host", "") == Ok(store.Bootstrap)
/// ```
///
/// ```gleam
/// assert store.opening(store.Absent, "b@host", "a@host")
///   == Ok(store.Join("a@host"))
/// ```
pub fn opening(
  marker: Marker,
  node: String,
  seed: String,
) -> Result(Opening, String) {
  case marker {
    Names(name) if name == node -> Ok(Reopen)
    Names(_) -> Error("member node name changed")
    Absent ->
      case seed == "" || seed == node {
        True -> Ok(Bootstrap)
        False ->
          case string.byte_size(seed) <= max_seed_bytes {
            True -> Ok(Join(seed))
            False -> Error("seed node name is too long")
          }
      }
  }
}

/// Open this node's durable replica. On a fresh disk an empty seed bootstraps
/// a cluster, and a remote seed joins its existing cluster.
///
/// ## Examples
///
/// ```gleam
/// // store.boot("/var/lib/gantry", "gantry1@controller1")
/// ```
pub fn boot(data_dir: String, seed: String) -> Result(Nil, String) {
  open_replica(data_dir <> "/queue-ra", seed)
  |> result.map_error(fault.detail)
}

/// Start the Ra system, then reopen, bootstrap or join the store.
fn open_replica(directory: String, seed: String) -> Result(Nil, Fault) {
  let node = ffi_khepri.local_node()
  use Nil <- result.try(
    simplifile.create_directory_all(directory)
    |> result.replace_error(fault.Unavailable(
      "cannot create the queue directory",
    )),
  )
  use Nil <- result.try(ffi_khepri.start_system(directory))
  use identity <- result.try(read_marker(directory <> "/member"))
  use how <- result.try(
    opening(identity, node, seed) |> result.map_error(fault.Internal),
  )

  use Nil <- result.try(case how {
    // Khepri creates a new singleton if Ra cannot find the server. An
    // established voter must refuse that fallback after disk loss.
    Reopen ->
      case ffi_khepri.directory_known() {
        True -> ffi_khepri.start_store()
        False -> Error(fault.Internal("missing durable member"))
      }
    Bootstrap -> {
      use Nil <- result.try(ffi_khepri.start_store())
      write_marker(directory, node)
    }
    Join(remote) -> {
      use Nil <- result.try(ffi_khepri.start_store())
      use Nil <- result.try(ffi_khepri.join(remote))
      write_marker(directory, node)
    }
  })

  use Nil <- result.try(ffi_khepri.create(encode(queue.empty())))
  ffi_khepri.hint_open()
  Ok(Nil)
}

/// Read the node name that an earlier boot recorded.
fn read_marker(path: String) -> Result(Marker, Fault) {
  case simplifile.read(path) {
    Ok(name) -> Ok(Names(name))
    Error(simplifile.Enoent) -> Ok(Absent)
    Error(_) -> Error(fault.Internal("cannot read the member marker"))
  }
}

/// Record this node's identity after Ra's directory is durable. The marker
/// is staged, synced and renamed, so a reader sees all of it or none.
fn write_marker(directory: String, node: String) -> Result(Nil, Fault) {
  let path = directory <> "/member"
  let staged = path <> ".tmp"
  let failure = fault.Unavailable("cannot record the member marker")
  use Nil <- result.try(ffi_khepri.sync_directory())
  use Nil <- result.try(
    simplifile.write(staged, node) |> result.replace_error(failure),
  )
  use Nil <- result.try(
    ffi_host.sync_path(staged) |> result.replace_error(failure),
  )
  use Nil <- result.try(
    simplifile.rename(staged, path) |> result.replace_error(failure),
  )
  ffi_host.sync_path(directory) |> result.replace_error(failure)
}

fn encode(state: queue.State) -> String {
  state |> protocol.encode_state |> json.to_string
}

/// The SHA-256 of snapshot bytes, which a leader compares instead of
/// receiving the document.
fn digest(bytes: String) -> BitArray {
  crypto.hash(crypto.Sha256, bit_array.from_string(bytes))
}

/// Decode the fenced document and retain its exact bytes for conditional replacement.
fn snapshot() -> Result(#(String, queue.State), Fault) {
  use bytes <- result.try(ffi_khepri.read())

  // A document above the ceiling was not written by this release.
  use Nil <- result.try(case string.byte_size(bytes) > max_bytes {
    True -> Error(fault.Internal("invalid durable queue snapshot"))
    False -> Ok(Nil)
  })
  use state <- result.try(
    json.parse(bytes, protocol.state_decoder())
    |> result.replace_error(fault.Internal("invalid durable queue snapshot")),
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
pub fn read() -> Result(queue.State, Fault) {
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
pub fn ready() -> Result(Nil, Fault) {
  ffi_khepri.ready()
}

/// Run a pure proposal and return its receipt after a majority confirms the
/// unchanged snapshot or commits a mutation.
/// A storage timeout leaves the outcome unknown. Recover by operation identity.
/// The proposal refuses a transition with a `Fault`, usually `Conflict`.
///
/// ## Examples
///
/// ```gleam
/// // store.change(fn(state) { Ok(#(state, Nil)) })
/// ```
pub fn change(
  propose: fn(queue.State) -> Result(#(queue.State, a), Fault),
) -> Result(a, Fault) {
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
) -> Result(Option(queue.Assignment), Fault) {
  use confirmed <- result.try(confirm_quiet())

  // A quiet snapshot cannot offer a lease to any worker.
  case confirmed {
    ConfirmedQuiet -> Ok(None)
    NeedsClaim ->
      change(fn(state) { Ok(queue.claim(state, worker, pool, now)) })
  }
}

/// Ask the leader whether the remembered quiet snapshot is still current.
/// A changed snapshot drops the hint, and the poll takes the full path.
fn confirm_quiet() -> Result(QuietCheck, Fault) {
  case ffi_khepri.hint_read() {
    Error(Nil) -> Ok(NeedsClaim)
    Ok(remembered) -> {
      use outcome <- result.try(ffi_khepri.matches(remembered))
      case outcome {
        Accepted -> Ok(ConfirmedQuiet)
        SnapshotChanged -> {
          ffi_khepri.hint_forget(remembered)
          Ok(NeedsClaim)
        }
      }
    }
  }
}

/// Recompute a pure transition from the latest snapshot after a competing write.
fn attempt(
  propose: fn(queue.State) -> Result(#(queue.State, a), Fault),
  remaining: Int,
) -> Result(a, Fault) {
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
    SnapshotChanged, 1 ->
      Error(fault.Unavailable("queue contention exceeded retry budget"))
    SnapshotChanged, _ -> attempt(propose, remaining - 1)
  }
}

/// Remember a quiet snapshot after it authorizes an unchanged receipt.
fn confirm(
  prior: String,
  state: queue.State,
) -> Result(ProposalOutcome, Fault) {
  let hash = digest(prior)
  use accepted <- result.try(ffi_khepri.matches(hash))

  // Pending and active work require the full decision even on a snapshot hit.
  case accepted == Accepted && queue.quiescent(state) {
    True -> ffi_khepri.hint_remember(hash)
    False -> Nil
  }

  Ok(accepted)
}

/// Replace the expected snapshot with a bounded mutation.
fn commit(prior: String, next: queue.State) -> Result(ProposalOutcome, Fault) {
  let bytes = encode(next)

  // Reject oversized metadata before it reaches the replicated log.
  case string.byte_size(bytes) > max_bytes {
    True -> Error(fault.Internal("queue snapshot exceeds 4 MiB"))
    False -> ffi_khepri.swap(prior, bytes)
  }
}
