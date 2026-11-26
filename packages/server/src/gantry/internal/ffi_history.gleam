//// The recent past one controller saw, for the dashboard: grants, results,
//// and ready-work samples, held in memory and lost on restart. OTP's ETS is
//// the primitive that lets request handlers write it concurrently, so the
//// bridge is a handful of externals. Every write is idempotent by key and
//// every call before `start` does nothing.

/// Create the record once for this VM, noting `now` as the start of what it
/// covers. A second call does nothing.
///
/// ## Examples
///
/// ```gleam
/// // ffi_history.start(1_764_000_000)
/// ```
@external(erlang, "gantry_history_ffi", "start")
pub fn start(now: Int) -> Nil

/// Record that lease `serial` was granted. A second record of the same
/// serial, as a replayed poll would make, is ignored.
///
/// ## Examples
///
/// ```gleam
/// // ffi_history.granted(7, "run", "test", "linux-01", "linux", now, until)
/// ```
@external(erlang, "gantry_history_ffi", "granted")
pub fn granted(
  serial: Int,
  run: String,
  action: String,
  worker: String,
  pool: String,
  at: Int,
  until: Int,
) -> Nil

/// Record that the result for lease `serial` was accepted.
///
/// ## Examples
///
/// ```gleam
/// // ffi_history.settled(7, True, now)
/// ```
@external(erlang, "gantry_history_ffi", "settled")
pub fn settled(serial: Int, succeeded: Bool, at: Int) -> Nil

/// Record the ready work per pool at `at`, replacing a sample in the same
/// second.
///
/// ## Examples
///
/// ```gleam
/// // ffi_history.sample(now, [#("linux", 3)])
/// ```
@external(erlang, "gantry_history_ffi", "sample")
pub fn sample(at: Int, ready: List(#(String, Int))) -> Nil

/// Drop what is older than `window` seconds before `now`, then the oldest
/// entries past the record's fixed cap.
///
/// ## Examples
///
/// ```gleam
/// // ffi_history.prune(now, 900)
/// ```
@external(erlang, "gantry_history_ffi", "prune")
pub fn prune(now: Int, window: Int) -> Nil

/// The oldest second the record covers, or 0 before `start`.
///
/// ## Examples
///
/// ```gleam
/// // ffi_history.since()
/// ```
@external(erlang, "gantry_history_ffi", "since")
pub fn since() -> Int

/// Every recorded grant as serial, run, action, worker, pool, time and
/// deadline.
///
/// ## Examples
///
/// ```gleam
/// // ffi_history.grants()
/// ```
@external(erlang, "gantry_history_ffi", "grants")
pub fn grants() -> List(#(Int, String, String, String, String, Int, Int))

/// Every recorded result as serial, whether it succeeded, and time.
///
/// ## Examples
///
/// ```gleam
/// // ffi_history.settlements()
/// ```
@external(erlang, "gantry_history_ffi", "settlements")
pub fn settlements() -> List(#(Int, Bool, Int))

/// Every recorded sample as time and ready work per pool.
///
/// ## Examples
///
/// ```gleam
/// // ffi_history.samples()
/// ```
@external(erlang, "gantry_history_ffi", "samples")
pub fn samples() -> List(#(Int, List(#(String, Int))))
