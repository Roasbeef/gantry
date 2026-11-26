//// The browser's fetch, timer, and local storage, bridged because Lustre's
//// effects cover none of them. Each external returns plain values, and the
//// app turns them into messages.

/// Fetch `url` with a bearer token and call `done` with the status and body.
/// A network failure calls it with status 0 and the error's message.
///
/// ## Examples
///
/// ```gleam
/// // ffi_browser.get("/v1/fleet", token, fn(status, body) { Nil })
/// ```
@external(javascript, "./browser_ffi.mjs", "get")
pub fn get(url: String, token: String, done: fn(Int, String) -> Nil) -> Nil

/// Call `tick` every `ms` milliseconds.
///
/// ## Examples
///
/// ```gleam
/// // ffi_browser.every(2000, fn() { Nil })
/// ```
@external(javascript, "./browser_ffi.mjs", "every")
pub fn every(ms: Int, tick: fn() -> Nil) -> Nil

/// The stored token, or the empty string.
///
/// ## Examples
///
/// ```gleam
/// // ffi_browser.load_token()
/// ```
@external(javascript, "./browser_ffi.mjs", "load_token")
pub fn load_token() -> String

/// Store the token, or forget it when it is empty.
///
/// ## Examples
///
/// ```gleam
/// // ffi_browser.save_token("")
/// ```
@external(javascript, "./browser_ffi.mjs", "save_token")
pub fn save_token(token: String) -> Nil
