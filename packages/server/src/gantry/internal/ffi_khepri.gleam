//// Khepri/Ra primitives behind an Erlang bridge, because Gleam has no
//// replicated conditional store. Each function performs one read, one atomic
//// compare-and-write, or one lock, and reports its outcome. Policy lives in
//// `gantry_core/layout` and `gantry/store`: the bootstrap or join decision,
//// the node-name marker, which keys an operation reads, what its decision
//// relied on, and what it writes. Only trusted startup configuration reaches
//// cluster boot.
////
//// Failures of calls that return a `Fault` are `Unavailable` and `Internal`,
//// built by the Erlang side as `{unavailable, Detail}` and
//// `{internal, Detail}`. A read fails with text, which the caller maps.

import gantry/fault.{type Fault}
import gantry_core/layout
import gleam/option.{type Option}

/// Whether a plan's expectations held when it was committed.
pub type Outcome {
  /// Every expectation held, and every write applied.
  Accepted

  /// A key the plan relied on changed, and nothing was written.
  Stale
}

/// Start the Khepri application and this node's Ra system in `directory`.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.start_system("/var/lib/gantry/queue-ra")
/// ```
@external(erlang, "gantry_khepri_ffi", "start_system")
pub fn start_system(directory: String) -> Result(Nil, Fault)

/// This VM's distribution node name.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.local_node() -> "gantry1@controller1"
/// ```
@external(erlang, "gantry_khepri_ffi", "local_node")
pub fn local_node() -> String

/// Whether Ra's directory already holds this store's server. Khepri would
/// otherwise create a new singleton, so an established voter refuses to
/// start without it.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.directory_known()
/// ```
@external(erlang, "gantry_khepri_ffi", "directory_known")
pub fn directory_known() -> Bool

/// Start or restart this node's store server.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.start_store()
/// ```
@external(erlang, "gantry_khepri_ffi", "start_store")
pub fn start_store() -> Result(Nil, Fault)

/// Join the cluster that the named node belongs to.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.join("gantry1@controller1")
/// ```
@external(erlang, "gantry_khepri_ffi", "join")
pub fn join(seed: String) -> Result(Nil, Fault)

/// Flush Ra's directory so a restart recognizes this member.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.sync_directory()
/// ```
@external(erlang, "gantry_khepri_ffi", "sync_directory")
pub fn sync_directory() -> Result(Nil, Fault)

/// Confirm that the controller can reach the queue's voting majority.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.ready()
/// ```
@external(erlang, "gantry_khepri_ffi", "ready")
pub fn ready() -> Result(Nil, Fault)

/// Wait until this replica has applied everything committed so far.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.fence()
/// ```
@external(erlang, "gantry_khepri_ffi", "fence")
pub fn fence() -> Result(Nil, Fault)

/// Read one key from the local replica.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.get(["counter", "serial"])
/// ```
@external(erlang, "gantry_khepri_ffi", "get")
pub fn get(key: layout.Key) -> Result(Option(String), String)

/// Read several keys from the local replica, in the order asked.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.many([["counter", "serial"], ["counter", "seq"]])
/// ```
@external(erlang, "gantry_khepri_ffi", "many")
pub fn many(keys: List(layout.Key)) -> Result(List(Option(String)), String)

/// Every key below a prefix that holds a value, with that value.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.list(["ready"])
/// ```
@external(erlang, "gantry_khepri_ffi", "list")
pub fn list(prefix: layout.Key) -> Result(List(#(layout.Key, String)), String)

/// Apply the writes if every expectation still holds, atomically. With no
/// writes the leader confirms the expectations through a quorum read. A
/// deadline leaves the outcome unknown.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.commit([], [])
/// ```
@external(erlang, "gantry_khepri_ffi", "commit")
pub fn commit(
  expects: List(layout.Expect),
  writes: List(layout.Write),
) -> Result(Outcome, Fault)

/// The queue snapshot an earlier release stored, if there is one.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.legacy()
/// ```
@external(erlang, "gantry_khepri_ffi", "legacy")
pub fn legacy() -> Result(Option(String), Fault)

/// Remove the earlier release's snapshot after the layout holds it.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.forget_legacy()
/// ```
@external(erlang, "gantry_khepri_ffi", "forget_legacy")
pub fn forget_legacy() -> Result(Nil, Fault)

/// Run `work` while holding the named lock: `admission`, `claiming` or
/// `finishing`. The lock orders one controller's own operations. It decides
/// nothing, because the commit still compares what the plan relied on.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.gated("claiming", fn() { Ok(Nil) })
/// ```
@external(erlang, "gantry_khepri_ffi", "gated")
pub fn gated(name: String, work: fn() -> Result(a, Fault)) -> Result(a, Fault)
