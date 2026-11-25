//// A named lock for operations that share files on this controller. Gleam
//// has no mutex, and OTP's `global:trans/4` is the primitive that already
//// releases on holder death, so the bridge is one external.

/// Run `work` while holding the lock named `key`, waiting for any earlier
/// holder. The lock is released when `work` returns or its process dies.
/// Waiters poll with OTP's randomized backoff, so a heavily contended key
/// can wait up to a few seconds past the holder's release.
///
/// ## Examples
///
/// ```gleam
/// // ffi_lock.with_lock("owner/project", fn() { Nil })
/// ```
@external(erlang, "gantry_lock_ffi", "with_lock")
pub fn with_lock(key: String, work: fn() -> a) -> a
