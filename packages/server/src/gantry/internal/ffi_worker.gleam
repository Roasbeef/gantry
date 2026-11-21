//// The host requests a core decoder over a framed Erlang port.

/// Message kind selected by the host adapter.
pub type Decoder {
  Assignment
  Completion
}

/// Start the slot process and serve its codec requests until it exits.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.run(check_wire)
/// ```
@external(erlang, "gantry_worker_ffi", "run")
pub fn run(
  check: fn(Decoder, String) -> Result(String, Nil),
) -> Result(Nil, String)
