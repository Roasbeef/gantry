//// Khepri/Ra primitives behind an Erlang bridge, because Gleam has no
//// replicated conditional store. Each function performs one call and
//// reports its outcome. Policy lives in `gantry/store`: the bootstrap or
//// join decision, the node-name marker, the snapshot size limit and the
//// quiet hint's invalidation. Only trusted startup configuration reaches
//// cluster boot.
////
//// Failures are `Fault`s. The Erlang side builds `Unavailable` and
//// `Internal` as `{unavailable, Detail}` and `{internal, Detail}`.

import gantry/fault.{type Fault}

/// Whether the expected snapshot authorized the proposal's receipt.
pub type ProposalOutcome {
  Accepted
  SnapshotChanged
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

/// Initialize the snapshot unless it already exists.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.create(empty)
/// ```
@external(erlang, "gantry_khepri_ffi", "create")
pub fn create(empty: String) -> Result(Nil, Fault)

/// Confirm that the controller can reach the queue's voting majority.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.ready()
/// ```
@external(erlang, "gantry_khepri_ffi", "ready")
pub fn ready() -> Result(Nil, Fault)

/// Read bytes after Khepri's bounded fence. The caller checks their size.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.read()
/// ```
@external(erlang, "gantry_khepri_ffi", "read")
pub fn read() -> Result(String, Fault)

/// Ask the Ra leader, after a quorum confirms its authority, whether the
/// stored snapshot hashes to the SHA-256 `digest`. Only the answer returns.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.matches(digest)
/// ```
@external(erlang, "gantry_khepri_ffi", "matches")
pub fn matches(digest: BitArray) -> Result(ProposalOutcome, Fault)

/// Replace the expected bytes with a mutation through Khepri, within the
/// same deadline as every other call. A deadline leaves the outcome unknown.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.swap(expected, proposed)
/// ```
@external(erlang, "gantry_khepri_ffi", "swap")
pub fn swap(
  expected: String,
  proposed: String,
) -> Result(ProposalOutcome, Fault)

/// Create the table that holds the local quiet hint, if it is absent.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.hint_open()
/// ```
@external(erlang, "gantry_khepri_ffi", "hint_open")
pub fn hint_open() -> Nil

/// The digest of the last snapshot a worker poll found quiet.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.hint_read()
/// ```
@external(erlang, "gantry_khepri_ffi", "hint_read")
pub fn hint_read() -> Result(BitArray, Nil)

/// Remember the digest of a snapshot whose worker state is terminal.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.hint_remember(digest)
/// ```
@external(erlang, "gantry_khepri_ffi", "hint_remember")
pub fn hint_remember(digest: BitArray) -> Nil

/// Drop the hint if it still holds `digest`.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.hint_forget(digest)
/// ```
@external(erlang, "gantry_khepri_ffi", "hint_forget")
pub fn hint_forget(digest: BitArray) -> Nil
