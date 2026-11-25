//// OTP primitives the benchmark driver needs and the Gleam libraries do not
//// expose. `erlang:monotonic_time/1` gives microsecond timestamps that a
//// wall-clock step cannot move, and `httpc:set_options/1` widens the
//// default HTTP profile so concurrent protocol clients do not queue behind
//// its two persistent sessions. No custom Erlang module is involved.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

/// Monotonic time in microseconds on an arbitrary per-VM base.
///
/// ## Examples
///
/// ```gleam
/// // ffi_bench.now_us()
/// ```
pub fn now_us() -> Int {
  monotonic_time(atom.create("microsecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

/// Allow `sessions` concurrent connections per origin in the default httpc
/// profile, with one outstanding request on each kept-alive connection.
///
/// ## Examples
///
/// ```gleam
/// // ffi_bench.widen_http(256)
/// ```
pub fn widen_http(sessions: Int) -> Nil {
  let _ =
    set_options([
      #(atom.create("max_sessions"), sessions),
      #(atom.create("max_keep_alive_length"), 1),
    ])
  Nil
}

@external(erlang, "httpc", "set_options")
fn set_options(options: List(#(Atom, Int))) -> Dynamic
