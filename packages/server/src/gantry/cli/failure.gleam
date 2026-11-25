//// How a CLI invocation fails. A failure carries the exit class and the
//// JSON envelope written to stderr, and every command reports through it,
//// so the exit-code table in `gantry describe` describes all of them.
////
//// | Exit | Variant | Meaning |
//// | --- | --- | --- |
//// | 1 | `Failed` | Local resource, transport or service failure, an HTTP status without a more specific code, watch deadline, or a failed or blocked run. |
//// | 2 | `Invalid` | Invalid command, arguments, request, or configuration, or HTTP 400, 411, 413, or 422. |
//// | 3 | `Unauthorized` | Missing or invalid credentials, or HTTP 401 or 403. |
//// | 4 | `Missing` | HTTP 404 or a missing local profile. |
//// | 6 | `Conflict` | HTTP 409, a local profile conflict, or a busy profile. |

import gleam/json
import gleam/option.{type Option, None, Some}

/// The exit status classes of a failed invocation.
pub type Exit {
  Failed
  Invalid
  Unauthorized
  Missing
  Conflict

  /// A child already reported its own failure with this status.
  Reported(status: Int)
}

/// A failed invocation and the JSON envelope it reports on stderr.
pub type Failure {
  Failure(
    exit: Exit,
    code: String,
    message: String,
    field: Option(String),
    http_status: Option(Int),
  )
}

/// Map an exit class to its documented status.
///
/// ## Examples
///
/// ```gleam
/// assert failure.exit_code(failure.Conflict) == 6
/// ```
pub fn exit_code(exit: Exit) -> Int {
  case exit {
    Failed -> 1
    Invalid -> 2
    Unauthorized -> 3
    Missing -> 4
    Conflict -> 6
    Reported(status) -> status
  }
}

/// Encode a failure as the stderr envelope.
///
/// ## Examples
///
/// ```gleam
/// // failure.envelope(failure) |> json.to_string
/// // -> {"error":{"code":"not_found","message":"unknown run","http_status":404}}
/// ```
pub fn envelope(failure: Failure) -> json.Json {
  let optional = [
    option.map(failure.field, fn(field) { #("field", json.string(field)) }),
    option.map(failure.http_status, fn(status) {
      #("http_status", json.int(status))
    }),
  ]
  json.object([
    #(
      "error",
      json.object([
        #("code", json.string(failure.code)),
        #("message", json.string(failure.message)),
        ..option.values(optional)
      ]),
    ),
  ])
}

/// An invalid argument or setting, naming the field to change.
pub fn invalid(message: String, field: String) -> Failure {
  Failure(Invalid, "invalid_input", message, Some(field), None)
}

/// An invalid command line with no single field to blame.
pub fn invalid_input(message: String) -> Failure {
  Failure(Invalid, "invalid_input", message, None, None)
}

/// A failure of the given class with no field or HTTP status.
pub fn new(exit: Exit, code: String, message: String) -> Failure {
  Failure(exit, code, message, None, None)
}

/// A local, transport, or service failure.
pub fn failed(code: String, message: String) -> Failure {
  new(Failed, code, message)
}
