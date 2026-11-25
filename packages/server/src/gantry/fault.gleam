//// Every failure the controller reports to a client carries one of these
//// kinds, so the HTTP layer picks a status from the variant and never from
//// the wording of a message.
////
//// ## Flow
////
//// A lower layer (store, Git, GitHub, blobs) classifies a failure where it
//// happens, because only that layer knows whether a retry can help. The
//// request layer passes the value through unchanged, and `http_api` maps it
//// to a status once.
////
//// | Kind | Meaning | Caller response | Status |
//// | --- | --- | --- | --- |
//// | `Invalid` | The request or the inputs it names are wrong. | Fix the request. | 400 |
//// | `Unauthorized` | No acceptable credential. | Present one. | 401 |
//// | `Forbidden` | The credential does not cover this identity. | Use the right one. | 403 |
//// | `NotFound` | The named run or repository does not exist. | Check the name. | 404 |
//// | `Conflict` | The queue's current state refuses the transition. | Reconcile by ID. | 409 |
//// | `Unavailable` | A dependency failed or timed out. | Retry later. | 503 |
//// | `Internal` | Durable state or a promised invariant is broken. | Operator action. | 500 |
////
//// The Erlang Khepri bridge builds `Unavailable` and `Internal` values as
//// `{unavailable, Detail}` and `{internal, Detail}`, which is how Gleam
//// represents these variants on the BEAM. Renaming either variant requires
//// the same change in `gantry_khepri_ffi.erl`.

/// Why a controller operation failed, and who can fix it.
pub type Fault {
  /// The request or the inputs it names are wrong.
  Invalid(detail: String)

  /// The request carries no acceptable credential.
  Unauthorized(detail: String)

  /// The credential is valid but names a different identity.
  Forbidden(detail: String)

  /// The named run, repository, or object does not exist.
  NotFound(detail: String)

  /// The queue's current state refuses the transition.
  Conflict(detail: String)

  /// A dependency failed or timed out. A later retry can succeed.
  Unavailable(detail: String)

  /// Durable state or an internal invariant is corrupt.
  Internal(detail: String)
}

/// The operator-facing message for a fault.
///
/// ## Examples
///
/// ```gleam
/// assert fault.detail(fault.NotFound("unknown run")) == "unknown run"
/// ```
pub fn detail(fault: Fault) -> String {
  case fault {
    Invalid(detail)
    | Unauthorized(detail)
    | Forbidden(detail)
    | NotFound(detail)
    | Conflict(detail)
    | Unavailable(detail)
    | Internal(detail) -> detail
  }
}

/// The HTTP status a client sees for a fault.
///
/// ## Examples
///
/// ```gleam
/// assert fault.status(fault.Unavailable("quorum lost")) == 503
/// ```
pub fn status(fault: Fault) -> Int {
  case fault {
    Invalid(_) -> 400
    Unauthorized(_) -> 401
    Forbidden(_) -> 403
    NotFound(_) -> 404
    Conflict(_) -> 409
    Unavailable(_) -> 503
    Internal(_) -> 500
  }
}
