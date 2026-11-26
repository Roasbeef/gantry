//// The sandbox an operator approves for a repository's actions.
////
//// The profile is operator policy. It is set only on a repository's entry in
//// `controller.toml`, copied into each task, and turned into container flags
//// only by the worker. A task carries the profile's name and never a flag or
//// a host path, so nothing on the wire can widen a container beyond a name
//// the worker already knows.
////
//// | Profile  | Name       | What the worker adds to the strict flags          |
//// | -------- | ---------- | ------------------------------------------------- |
//// | `Strict` | `"strict"` | nothing                                           |
//// | `Userns` | `"userns"` | its seccomp profile, unmasked paths, no AppArmor  |
////
//// A missing name is `Strict`, so a task written before profiles existed
//// keeps the strict flags. An unknown name is an error and never widens.
//// See `docs/design-notes/sandbox-profiles.md`.

import gleam/dynamic/decode

/// A closed set of sandboxes. `Strict` is the default.
pub type Profile {
  /// The default container flags, unchanged.
  Strict

  /// Strict flags plus what a nested `bwrap` needs to create user namespaces.
  Userns
}

/// The profile's name in `controller.toml` and on the wire.
///
/// ## Examples
///
/// ```gleam
/// assert sandbox.name(sandbox.Userns) == "userns"
/// ```
pub fn name(profile: Profile) -> String {
  case profile {
    Strict -> "strict"
    Userns -> "userns"
  }
}

/// Read a profile from its name. Any other spelling is an error.
///
/// ## Examples
///
/// ```gleam
/// assert sandbox.parse("strict") == Ok(sandbox.Strict)
/// assert sandbox.parse("unconfined") == Error(Nil)
/// ```
pub fn parse(text: String) -> Result(Profile, Nil) {
  case text {
    "strict" -> Ok(Strict)
    "userns" -> Ok(Userns)
    _ -> Error(Nil)
  }
}

/// Decode a profile name, failing on any name outside the closed set.
///
/// ## Examples
///
/// ```gleam
/// // decode.optional_field("sandbox", sandbox.Strict, sandbox.decoder())
/// ```
pub fn decoder() -> decode.Decoder(Profile) {
  use text <- decode.then(decode.string)

  // A name outside the closed set fails rather than falling back to strict.
  case parse(text) {
    Ok(profile) -> decode.success(profile)
    Error(Nil) -> decode.failure(Strict, "sandbox profile")
  }
}
