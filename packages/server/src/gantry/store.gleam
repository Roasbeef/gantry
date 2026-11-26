//// The durable queue lives in Khepri under an indexed layout, defined in
//// `gantry_core/layout`: each run under its own key with small index entries
//// derived from it. An operation reads the few keys it needs, the core
//// decides, and the resulting plan commits in one transaction that compares
//// every key the decision relied on. A plan that changes nothing is
//// confirmed by a quorum read and appends nothing to the log. A losing plan
//// is recomputed from fresh reads.
////
//// ## Policy in Gleam
////
//// The Erlang bridge performs single Khepri and Ra calls. This module decides
//// what to do with them: whether a node bootstraps or joins, which marker it
//// trusts, how often a lost race is retried, which lock orders an
//// operation, and how an earlier release's snapshot is imported.
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
import gantry/internal/ffi_khepri.{Accepted, Stale}
import gantry_core/layout
import gantry_core/protocol
import gantry_core/queue
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// How many times an operation recomputes after a competing write.
const attempts = 8

/// How many runs and proofs one retention commit may drop.
const retention_batch = 250

/// How many batches one retention pass may commit.
const retention_passes = 40

/// The longest pause before a recomputation, in milliseconds. A replica that
/// lags the leader needs a few milliseconds to catch up.
const longest_pause = 40

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

/// The lock that orders one controller's operations writing the same counter.
type Lock {
  Admission
  Claiming
  Finishing
  Unordered
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

  // Each way of opening ends with a started store server.
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

  initialize()
}

/// What a booting voter does about the queue's durable format.
pub type Upgrade {
  /// The layout is in place and the old snapshot is sealed or absent.
  Current

  /// The layout is in place, and the old snapshot still holds the queue it
  /// was imported from, because a boot stopped between the two steps.
  Seal

  /// There is no layout yet. Import the old snapshot, or start empty.
  Import
}

/// The bytes that replace the old snapshot once it is imported. An earlier
/// release cannot decode them, so it refuses to serve the queue instead of
/// starting an empty one beside it.
pub const sealed_snapshot = "{\"format\":\"indexed-v1\",\"moved\":\"queue/\"}"

/// Decide what a booting voter does from the layout's format marker and the
/// old snapshot. A marker naming a format this release does not know refuses
/// to start, so a rollback past a format change fails by name.
///
/// | Marker | Old snapshot | Decision |
/// | --- | --- | --- |
/// | `indexed-v1` | absent or sealed | `Current` |
/// | `indexed-v1` | a queue | `Seal` |
/// | another name | any | refuse |
/// | absent | sealed | refuse, the layout was lost |
/// | absent | absent or a queue | `Import` |
///
/// ## Examples
///
/// ```gleam
/// assert store.upgrade(None, None) == Ok(store.Import)
/// ```
pub fn upgrade(
  marker: Option(String),
  legacy: Option(String),
) -> Result(Upgrade, String) {
  let sealed = legacy == Some(sealed_snapshot)

  // The marker names the format. Without one, only an unsealed store imports.
  case marker {
    Some(name) if name == layout.format_value ->
      Ok(case legacy == None || sealed {
        True -> Current
        False -> Seal
      })
    Some(name) -> Error("unknown queue format " <> name)
    None if sealed -> Error("queue format marker missing after import")
    None -> Ok(Import)
  }
}

/// Bring the store to the layout this release reads, importing an earlier
/// release's snapshot, unless a voter already did. The marker is written in the
/// same transaction as everything it describes, and the transaction expects it
/// to be absent, so the first voter to boot wins and the others find it.
fn initialize() -> Result(Nil, Fault) {
  use legacy <- result.try(ffi_khepri.legacy())
  use marker <- result.try(
    ffi_khepri.get(layout.format_key())
    |> result.map_error(fault.Unavailable),
  )
  use decision <- result.try(
    upgrade(marker, legacy) |> result.map_error(fault.Internal),
  )

  // Each decision ends with the layout in place and the old snapshot sealed.
  case decision {
    Current -> Ok(Nil)
    Seal -> ffi_khepri.seal_legacy(sealed_snapshot)
    Import -> import_snapshot(legacy)
  }
}

/// Create the layout from an earlier release's snapshot, or from an empty
/// queue when there is none, and then seal the snapshot. Losing the race to
/// another voter is success, because that voter's layout is the same.
fn import_snapshot(legacy: Option(String)) -> Result(Nil, Fault) {
  use state <- result.try(decode_snapshot(legacy))
  use _ <- result.try(commit(layout.bootstrap(state)))
  use <- bool.guard(legacy == None, Ok(Nil))
  ffi_khepri.seal_legacy(sealed_snapshot)
}

/// The queue an earlier release stored, or an empty one when it stored none.
fn decode_snapshot(legacy: Option(String)) -> Result(queue.State, Fault) {
  // No snapshot means a fresh disk.
  case legacy {
    None -> Ok(queue.empty())
    Some(bytes) ->
      json.parse(bytes, protocol.state_decoder())
      |> result.replace_error(fault.Internal("invalid durable queue snapshot"))
  }
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

/// The reader the layout uses, over this node's replica.
fn reader() -> layout.Reader {
  layout.Reader(
    get: ffi_khepri.get,
    many: ffi_khepri.many,
    list: ffi_khepri.list,
  )
}

/// Map a layout failure to the fault a caller handles.
fn fault_of(failure: layout.Failure) -> Fault {
  case failure {
    layout.Refused(detail) -> fault.Conflict(detail)
    layout.Full(detail) -> fault.Unavailable(detail)
    layout.Unreadable(detail) -> fault.Unavailable(detail)
    layout.Corrupt(detail) -> fault.Internal(detail)
  }
}

/// Commit one plan, returning whether its expectations held.
fn commit(plan: layout.Plan(a)) -> Result(ffi_khepri.Outcome, Fault) {
  case layout.expects(plan), layout.writes(plan) {
    [], [] -> Ok(Accepted)
    expects, writes -> ffi_khepri.commit(expects, writes)
  }
}

/// Plan against fresh reads and commit, recomputing after a competing write.
/// An operation that writes a counter first plans without the lock, because a
/// plan that writes nothing, such as an empty poll, needs no ordering and
/// must not queue behind the others. A plan that writes takes the lock and
/// plans again, so a refused commit then means another controller wrote one
/// of the keys read.
fn transact(
  lock: Lock,
  plan: fn(layout.Reader) -> Result(layout.Plan(a), layout.Failure),
) -> Result(a, Fault) {
  case lock {
    Admission -> ordered("admission", plan)
    Claiming -> ordered("claiming", plan)
    Finishing -> ordered("finishing", plan)
    Unordered -> attempt(plan, attempts)
  }
}

/// Take the lock only when the first plan has something to write.
fn ordered(
  name: String,
  plan: fn(layout.Reader) -> Result(layout.Plan(a), layout.Failure),
) -> Result(a, Fault) {
  use first <- result.try(fresh_plan(plan))
  let locked = fn() { ffi_khepri.gated(name, fn() { attempt(plan, attempts) }) }

  // A plan with nothing to write is confirmed, and one with writes is not.
  case layout.writes(first) {
    [] -> confirmed(first, locked)
    [_, ..] -> locked()
  }
}

/// Confirm a plan that writes nothing. A stale read means a competing write,
/// so the operation then plans again under its lock.
fn confirmed(
  planned: layout.Plan(a),
  fallback: fn() -> Result(a, Fault),
) -> Result(a, Fault) {
  use outcome <- result.try(commit(planned))

  // Only a refused confirmation needs the lock.
  case outcome {
    Accepted -> Ok(layout.receipt(planned))
    Stale -> fallback()
  }
}

/// Plan against fresh reads, commit, and recompute while a competing write
/// keeps invalidating the plan, up to the remaining attempts.
fn attempt(
  plan: fn(layout.Reader) -> Result(layout.Plan(a), layout.Failure),
  remaining: Int,
) -> Result(a, Fault) {
  use planned <- result.try(fresh_plan(plan))
  use outcome <- result.try(commit(planned))

  // A competing write invalidates the plan and its receipt.
  case outcome, remaining {
    Accepted, _ -> Ok(layout.receipt(planned))
    Stale, 1 ->
      Error(fault.Unavailable("queue contention exceeded retry budget"))
    Stale, _ -> {
      // A replica that lags would keep reading the older keys, so wait for it.
      let _ = ffi_khepri.fence()
      process.sleep(pause(remaining))
      attempt(plan, remaining - 1)
    }
  }
}

/// Plan from the local replica. A refusal from a replica that lags would be
/// wrong, such as a result refused as stale because the lease has not reached
/// this replica, so a refusal waits for the replica to catch up and plans once
/// more before it is believed.
fn fresh_plan(
  plan: fn(layout.Reader) -> Result(layout.Plan(a), layout.Failure),
) -> Result(layout.Plan(a), Fault) {
  // Only a refusal can come from a stale view, so only it is planned twice.
  case plan(reader()) {
    Error(layout.Refused(_)) -> {
      // A refusal that cannot be confirmed is unavailable, not a conflict.
      use Nil <- result.try(ffi_khepri.fence())
      plan(reader()) |> result.map_error(fault_of)
    }
    other -> result.map_error(other, fault_of)
  }
}

/// A growing, jittered pause before the next recomputation.
fn pause(remaining: Int) -> Int {
  let tried = attempts - remaining + 1
  int.min(longest_pause, tried * 2 + int.random(tried * 2 + 1))
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

/// Read every run and proof as one state. Tests and tools use this, and the
/// controller's hot paths never do.
///
/// ## Examples
///
/// ```gleam
/// // store.read()
/// ```
pub fn read() -> Result(queue.State, Fault) {
  layout.materialize(reader()) |> result.map_error(fault_of)
}

/// Look up a run by its stable ID. A majority confirms the answer.
///
/// ## Examples
///
/// ```gleam
/// // store.find("run-1")
/// ```
pub fn find(id: String) -> Result(Option(queue.Run), Fault) {
  transact(Unordered, layout.find(_, id))
}

/// Admit a run exactly as `queue.admit` does, or return the stored run when
/// the same inputs arrive again. A storage timeout leaves the outcome
/// unknown, so retry with the same ID.
///
/// ## Examples
///
/// ```gleam
/// // store.admit("run-1", "owner/project", sha, "check", queue.Build, tasks)
/// ```
pub fn admit(
  id: String,
  repo: String,
  revision: String,
  target: String,
  submission: queue.Submission,
  tasks: List(queue.Task),
) -> Result(queue.Run, Fault) {
  transact(Admission, layout.admit(
    _,
    id,
    repo,
    revision,
    target,
    submission,
    tasks,
  ))
}

/// Lease or reuse one action for a worker, expiring lapsed leases first. An
/// empty poll is confirmed by a majority and writes nothing.
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
  transact(Claiming, layout.claim(_, worker, pool, now))
}

/// Accept a worker's result for the live lease, or refuse it as stale.
///
/// ## Examples
///
/// ```gleam
/// // store.finish("run", "build", "worker", 3, completion)
/// ```
pub fn finish(
  run: String,
  action: String,
  worker: String,
  serial: Int,
  completion: queue.Completion,
) -> Result(Nil, Fault) {
  transact(Finishing, layout.finish(_, run, action, worker, serial, completion))
}

/// The waiting run at the head of each free lane.
///
/// ## Examples
///
/// ```gleam
/// // store.preparations()
/// ```
pub fn preparations() -> Result(List(queue.Preparation), Fault) {
  transact(Unordered, layout.preparations)
}

/// Record a built candidate or a refusal for exactly the run that was offered.
///
/// ## Examples
///
/// ```gleam
/// // store.record_preparation(preparation, outcome)
/// ```
pub fn record_preparation(
  preparation: queue.Preparation,
  outcome: Result(#(queue.Candidate, List(queue.Task)), queue.PrepareFailure),
) -> Result(Nil, Fault) {
  transact(Unordered, layout.record_preparation(_, preparation, outcome))
}

/// Move each lane's finished run to `Landing` and return the intents.
///
/// ## Examples
///
/// ```gleam
/// // store.landings()
/// ```
pub fn landings() -> Result(List(queue.Intent), Fault) {
  transact(Unordered, layout.landings)
}

/// Record the outcome of exactly the intent that was committed.
///
/// ## Examples
///
/// ```gleam
/// // store.record_landing(intent, Ok(Nil))
/// ```
pub fn record_landing(
  intent: queue.Intent,
  outcome: Result(Nil, queue.Block),
) -> Result(Nil, Fault) {
  transact(Unordered, layout.record_landing(_, intent, outcome))
}

/// Drop finished runs and proofs beyond the retention bounds, a bounded
/// batch per commit so one pass never writes an unbounded transaction.
///
/// ## Examples
///
/// ```gleam
/// // store.retain(queue.Retention(200, 1000))
/// ```
pub fn retain(retention: queue.Retention) -> Result(Nil, Fault) {
  retain_batches(retention, retention_passes)
}

/// Run retention batches until nothing is left to drop or the passes run out.
/// An interrupted pass resumes at the next interval.
fn retain_batches(
  retention: queue.Retention,
  passes: Int,
) -> Result(Nil, Fault) {
  // Retention lowers the count that admission raises, so it takes the same
  // lock, and a pass cannot lose every attempt to a steady stream of admissions.
  use more <- result.try(
    transact(Admission, layout.retain(_, retention, retention_batch)),
  )

  // Stop when the queue is within its bounds or the pass budget is spent.
  case more, passes {
    True, passes if passes > 1 -> retain_batches(retention, passes - 1)
    True, _ | False, _ -> Ok(Nil)
  }
}
