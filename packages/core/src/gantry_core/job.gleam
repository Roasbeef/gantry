//// A provider request binds a pull number to an immutable Git revision.
//// Identifier validators keep remote and ref operands in the GitHub domain.

import gleam/int
import gleam/list
import gleam/string

/// Whether the entry may advance the target branch.
pub type Mode {
  /// Run the build and record its outcome.
  Build

  /// Submit the tested commit after a successful build.
  Submit
}

/// A validated, immutable queue request.
pub type Request {
  Request(repository: String, pull: Int, head: String, mode: Mode)
}

/// Check the spelling allowed for a github.com repository slug.
///
/// ## Examples
///
/// ```gleam
/// job.valid_repository("owner/repo")
/// ```
pub fn valid_repository(slug: String) -> Bool {
  case string.split(slug, "/") {
    [owner, repo] -> valid_component(owner) && valid_component(repo)
    [_, _, _, ..] | [_] | [] -> False
  }
}

/// Check one slug segment before it becomes an HTTPS path component.
fn valid_component(component: String) -> Bool {
  component != ""
  && component != "."
  && component != ".."
  && list.all(string.to_utf_codepoints(component), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    { n >= 48 && n <= 57 }
    || { n >= 65 && n <= 90 }
    || { n >= 97 && n <= 122 }
    || n == 45
    || n == 46
    || n == 95
  })
}

/// Check a full GitHub SHA-1 object name.
///
/// ## Examples
///
/// ```gleam
/// job.valid_sha("abc") == False
/// ```
pub fn valid_sha(sha: String) -> Bool {
  string.byte_size(sha) == 40
  && list.all(string.to_utf_codepoints(sha), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    { n >= 48 && n <= 57 } || { n >= 97 && n <= 102 }
  })
}

/// Format a pull request number for a GitHub URL or ref.
///
/// ## Examples
///
/// ```gleam
/// // job.pull_number(request)
/// ```
pub fn pull_number(request: Request) -> String {
  int.to_string(request.pull)
}
