//// Gun's receive and flow-control primitives bridge one bounded HTTP stream.
//// Request construction uses Gleam's HTTP types through the public adapter.

import gleam/http

/// An origin and the bytes for one HTTP request.
pub type ControllerRequest {
  ControllerRequest(
    scheme: http.Scheme,
    host: String,
    port: Int,
    method: http.Method,
    target: String,
    headers: List(#(String, String)),
    body: BitArray,
  )
}

/// Whether to try another origin or reject an oversized response.
pub type DispatchError {
  Unavailable
  TooLarge
}

/// Send one request with a deadline and an upper bound on response bytes.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker_http.dispatch(request, 64 * 1024 * 1024)
/// ```
pub fn dispatch(
  request: ControllerRequest,
  limit: Int,
) -> Result(#(Int, BitArray), DispatchError) {
  dispatch_gun(
    #(
      request.scheme,
      request.host,
      request.port,
      http.method_to_string(request.method),
      request.target,
      request.headers,
      request.body,
    ),
    limit,
  )
}

/// Pass the encoded method and stream bounds to Gun.
@external(erlang, "gantry_worker_http_ffi", "dispatch")
fn dispatch_gun(
  request: #(
    http.Scheme,
    String,
    Int,
    String,
    String,
    List(#(String, String)),
    BitArray,
  ),
  limit: Int,
) -> Result(#(Int, BitArray), DispatchError)
