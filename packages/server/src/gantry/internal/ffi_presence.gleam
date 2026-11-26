//// The latest poll this controller served for each worker slot. It is held
//// in memory and lost on restart, because writing it to the replicated queue
//// would replicate every idle poll. OTP's ETS is the primitive that lets
//// request handlers write it concurrently, so the bridge is three externals.

/// Create the table once for this VM. A second call does nothing.
///
/// ## Examples
///
/// ```gleam
/// // ffi_presence.start()
/// ```
@external(erlang, "gantry_presence_ffi", "start")
pub fn start() -> Nil

/// Record that `worker` polled `pool` at Unix second `at`, replacing its
/// earlier record. Before `start` it records nothing.
///
/// ## Examples
///
/// ```gleam
/// // ffi_presence.record("linux-01", "linux", 1_764_000_000)
/// ```
@external(erlang, "gantry_presence_ffi", "record")
pub fn record(worker: String, pool: String, at: Int) -> Nil

/// Every recorded poll as worker, pool and time, in no particular order.
///
/// ## Examples
///
/// ```gleam
/// // ffi_presence.all()
/// ```
@external(erlang, "gantry_presence_ffi", "all")
pub fn all() -> List(#(String, String, Int))
