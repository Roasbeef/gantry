//// Khepri/Ra operations use an Erlang bridge because Gleam has no replicated
//// conditional store. Only trusted startup configuration reaches cluster boot.

/// Open the replica and initialize the snapshot if absent.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.boot("/var/lib/gantry", "", empty)
/// ```
@external(erlang, "gantry_khepri_ffi", "boot")
pub fn boot(dir: String, seed: String, empty: String) -> Result(Nil, String)

/// Read bytes after a bounded quorum fence.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.read()
/// ```
@external(erlang, "gantry_khepri_ffi", "read")
pub fn read() -> Result(String, String)

/// Compare exact bytes. False means another proposal won.
///
/// ## Examples
///
/// ```gleam
/// // ffi_khepri.swap(expected, proposed)
/// ```
@external(erlang, "gantry_khepri_ffi", "swap")
pub fn swap(expected: String, proposed: String) -> Result(Bool, String)
