//// Gun's receive and flow-control primitives bridge one bounded HTTP stream.
//// Request construction uses Gleam's HTTP types through the public adapter.
//// The Erlang side keeps one connection per origin for the calling process,
//// so a caller that wants reuse must call from one long-lived process.

import gleam/http

/// How long each phase of an exchange may take, in milliseconds.
pub type Timeouts {
  Timeouts(
    /// Name resolution, TCP connect and TLS handshake, each.
    connect: Int,
    /// The wait for the response head after the request is sent.
    first_byte: Int,
    /// The wait for each further response chunk. Every chunk restarts it.
    idle: Int,
  )
}

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
    timeouts: Timeouts,
  )
}

/// Whether to try another origin or reject an oversized response.
pub type DispatchError {
  Unavailable
  TooLarge
}

/// Send one request with its timeouts and an upper bound on response bytes.
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
      #(
        request.timeouts.connect,
        request.timeouts.first_byte,
        request.timeouts.idle,
      ),
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
    #(Int, Int, Int),
  ),
  limit: Int,
) -> Result(#(Int, BitArray), DispatchError)
