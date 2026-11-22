//// The worker HTTP adapter opens one bounded stream per controller request.

import gleam/http

/// An origin and the bytes for one HTTP request.
pub type ControllerRequest {
  ControllerRequest(
    scheme: http.Scheme,
    host: String,
    port: Int,
    method: String,
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
@external(erlang, "gantry_worker_http_ffi", "dispatch")
pub fn dispatch(
  request: ControllerRequest,
  limit: Int,
) -> Result(#(Int, BitArray), DispatchError)
