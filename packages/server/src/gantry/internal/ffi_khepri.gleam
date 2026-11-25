//// Khepri/Ra operations use an Erlang bridge because Gleam has no replicated
//// conditional store. Only trusted startup configuration reaches cluster boot.

import gantry/fault.{type Fault}

/// Whether the expected snapshot authorized the proposal's receipt.
pub type ProposalOutcome {
  Accepted
  SnapshotChanged
}

/// Whether a worker poll can return before running the full claim decision.
pub type QuietCheck {
  ConfirmedQuiet
  NeedsClaim
}

/// Open the replica and initialize the snapshot if absent.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.boot("/var/lib/gantry", "", empty)
/// ```
@external(erlang, "gantry_khepri_ffi", "boot")
pub fn boot(dir: String, seed: String, empty: String) -> Result(Nil, Fault)

/// Confirm that the controller can reach the queue's voting majority.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.ready()
/// ```
@external(erlang, "gantry_khepri_ffi", "ready")
pub fn ready() -> Result(Nil, Fault)

/// Read bytes after Khepri's bounded fence.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.read()
/// ```
@external(erlang, "gantry_khepri_ffi", "read")
pub fn read() -> Result(String, Fault)

/// Check whether a quorum-confirmed snapshot has the expected bytes.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.confirm(expected)
/// ```
@external(erlang, "gantry_khepri_ffi", "confirm")
pub fn confirm(expected: String) -> Result(ProposalOutcome, Fault)

/// Confirm a previously identified quiet snapshot with the quorum.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.confirm_quiet()
/// ```
@external(erlang, "gantry_khepri_ffi", "confirm_quiet")
pub fn confirm_quiet() -> Result(QuietCheck, Fault)

/// Remember the bytes whose worker state is terminal.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.remember_quiet(bytes)
/// ```
@external(erlang, "gantry_khepri_ffi", "remember_quiet")
pub fn remember_quiet(bytes: String) -> Nil

/// Replace the expected bytes with a mutation through Khepri.
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
