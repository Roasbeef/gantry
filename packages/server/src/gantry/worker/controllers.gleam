//// Controller requests retain a preferred origin and try the other replicas
//// after transport errors or server failures. The caller owns that preference.

import gantry/blobs
import gantry/internal/ffi_worker_http.{
  ControllerRequest, Timeouts, TooLarge, Unavailable,
}
import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// Name resolution, connect and TLS handshake each get this long.
const connect_timeout = 10_000

/// A controller that goes quiet for this long between response chunks, or
/// before its first byte, is treated as unavailable.
const idle_timeout = 30_000

/// The slowest link, in bytes per second, a request body is expected to
/// cross. It sizes the wait for the response to an upload.
const slowest_bytes_per_second = 262_144

/// A validated set of controller endpoints with one preferred origin.
pub opaque type Controllers {
  Controllers(origins: List(String), token: String)
}

/// An HTTP response or a reason to retry or reject a request.
pub type Fault {
  Offline(reason: String)
  Invalid(reason: String)
}

/// Read the configured controller origins and credential.
///
/// ## Examples
///
/// ```gleam
/// // controllers.new("https://controller-a,https://controller-b", token)
/// ```
pub fn new(endpoints: String, token: String) -> Result(Controllers, String) {
  string.split(endpoints, ",")
  |> list.try_map(fn(endpoint) {
    let address = string.trim(endpoint)

    // An endpoint is an HTTP(S) origin. Credentials belong in the header.
    case uri.parse(address) {
      Ok(uri.Uri(
        scheme: Some(scheme),
        host: Some(host),
        userinfo: None,
        path:,
        query: None,
        fragment: None,
        ..,
      ))
        if host != ""
        && { scheme == "http" || scheme == "https" }
        && { path == "" || path == "/" }
      ->
        Ok(case path {
          "" -> address
          _ -> string.drop_end(address, 1)
        })
      _ -> Error("GANTRY_ENDPOINT must contain HTTP(S) origins")
    }
  })
  |> result.map(fn(origins) { Controllers(origins, token) })
}

/// The wait for a response head after sending `request_bytes`. The server
/// answers an upload only after reading it, so the allowance grows with the
/// declared size: a 64 MiB blob gets about 286 seconds, not a fixed 20.
///
/// ## Examples
///
/// ```gleam
/// controllers.first_byte_allowance(0)
/// // -> 30_000
/// ```
pub fn first_byte_allowance(request_bytes: Int) -> Int {
  idle_timeout + request_bytes * 1000 / slowest_bytes_per_second
}

/// Call the preferred origin first and retain the responsive replica.
///
/// ## Examples
///
/// ```gleam
/// // controllers.call(network, http.Get, "/health", <<>>, "application/json")
/// ```
pub fn call(
  network: Controllers,
  method: http.Method,
  path: String,
  bytes: BitArray,
  content_type: String,
) -> Result(#(Controllers, Int, BitArray), Fault) {
  use origin <- walk_origins(network.origins, [])
  let response = {
    use req <- result.try(
      request.to(origin <> path) |> result.replace_error(Unavailable),
    )

    // Use the scheme's port when the origin leaves it implicit.
    let default_port = case req.scheme {
      http.Https -> 443
      http.Http -> 80
    }

    // The request target keeps the path and query separate from the origin.
    let target = case req.query {
      Some(query) -> req.path <> "?" <> query
      None -> req.path
    }

    ffi_worker_http.dispatch(
      ControllerRequest(
        scheme: req.scheme,
        host: req.host,
        port: option.unwrap(req.port, default_port),
        method:,
        target:,
        headers: [
          #("authorization", "Bearer " <> network.token),
          #("content-type", content_type),
          #("accept-encoding", "identity"),
        ],
        body: bytes,
        timeouts: Timeouts(
          connect: connect_timeout,
          first_byte: first_byte_allowance(bit_array.byte_size(bytes)),
          idle: idle_timeout,
        ),
      ),
      blobs.limit,
    )
  }

  // Keep bounded client responses and fail over on transport or server errors.
  case response {
    Ok(#(status, body)) -> Some(Ok(#(network, status, body)))
    Error(TooLarge) ->
      Some(Error(Invalid("controller response exceeded size limit")))
    Error(Unavailable) -> None
  }
}

/// Try each origin once and put the first responsive controller first.
fn walk_origins(
  remaining: List(String),
  passed: List(String),
  try_one: fn(String) -> Option(Result(#(Controllers, Int, BitArray), Fault)),
) -> Result(#(Controllers, Int, BitArray), Fault) {
  case remaining {
    [] -> Error(Offline("no controller available"))
    [origin, ..rest] ->
      case try_one(origin) {
        Some(Ok(#(network, status, bytes))) ->
          Ok(#(
            Controllers(
              [origin, ..list.append(rest, list.reverse(passed))],
              network.token,
            ),
            status,
            bytes,
          ))
        Some(Error(error)) -> Error(error)
        None -> walk_origins(rest, [origin, ..passed], try_one)
      }
  }
}

/// Fetch bytes by address and verify the digest before staging them.
///
/// ## Examples
///
/// ```gleam
/// // controllers.fetch(network, digest)
/// ```
pub fn fetch(network: Controllers, digest: String) -> Result(BitArray, Fault) {
  // A blob address must be a lowercase SHA-256 digest.
  use Nil <- result.try(case blobs.valid(digest) {
    True -> Ok(Nil)
    False -> Error(Invalid("invalid input digest"))
  })

  use #(_, status, bytes) <- result.try(call(
    network,
    http.Get,
    "/v1/blobs/" <> digest,
    <<>>,
    "application/octet-stream",
  ))

  // A successful response still needs to match the requested address.
  case status, blobs.digest(bytes) == digest {
    200, True -> Ok(bytes)
    200, False -> Error(Invalid("input failed SHA-256 verification"))
    _, _ ->
      Error(Offline("input blob unavailable, HTTP " <> int.to_string(status)))
  }
}
