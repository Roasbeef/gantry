//// Isolated bare repositories hold temporary fetches. A candidate bundle is
//// published atomically into shared storage before the queue sees its OID.

import gantry/config
import gantry/internal/ffi_host
import gantry_core/job
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Operation-local bare repository and its configured remote.
pub type Session {
  Session(dir: String, url: String, env: List(#(String, String)))
}

/// Create and clean up one isolated Git repository for a controller request.
///
/// ## Examples
///
/// ```gleam
/// // git.session(cfg, repo, fn(s) { git.fetch(s, "refs/heads/main") })
/// ```
pub fn session(
  cfg: config.Config,
  repo: config.Repository,
  work: fn(Session) -> Result(a, String),
) -> Result(a, String) {
  use Nil <- result.try(
    simplifile.create_directory_all(cfg.data)
    |> result.replace_error("cannot create Git work directory"),
  )
  use #(status, out) <- result.try(ffi_host.run(
    "mktemp",
    ["-d", cfg.data <> "/git.XXXXXXXXXX"],
    [],
    5000,
  ))

  // Initialize a repository only after mktemp acknowledges exclusive ownership.
  case status {
    0 -> {
      let dir = string.trim(out)

      // Send credentials only to the configured GitHub HTTPS endpoint.
      let #(url, auth) = case repo.provider {
        config.Local(path) -> #(path, [])
        config.GitHub(_) -> {
          let url = "https://github.com/" <> repo.name <> ".git"
          let auth =
            bit_array.base64_encode(
              <<"x-access-token:":utf8, cfg.github_token:utf8>>,
              True,
            )
          #(url, [
            #("GIT_CONFIG_COUNT", "1"),
            #("GIT_CONFIG_KEY_0", "http.https://github.com/.extraHeader"),
            #("GIT_CONFIG_VALUE_0", "Authorization: Basic " <> auth),
          ])
        }
      }

      let env =
        list.append(auth, [
          #("GIT_TERMINAL_PROMPT", "0"),
          #("GIT_CONFIG_NOSYSTEM", "1"),
          #("GIT_CONFIG_GLOBAL", "/dev/null"),
          #("GIT_AUTHOR_NAME", "Gantry"),
          #("GIT_AUTHOR_EMAIL", "gantry@localhost"),
          #("GIT_COMMITTER_NAME", "Gantry"),
          #("GIT_COMMITTER_EMAIL", "gantry@localhost"),
        ])
      let s = Session(dir, url, env)
      let outcome = {
        use _ <- result.try(
          command(s, ["init", "--bare", "--quiet", "--template="]),
        )
        work(s)
      }
      let _ = simplifile.delete(dir)
      outcome
    }
    _ -> Error("cannot create temporary Git directory")
  }
}

/// Preserve Git exit codes for commands with meaningful negative answers.
fn raw(s: Session, args: List(String)) -> Result(#(Int, String), String) {
  ffi_host.run("git", list.append(["-C", s.dir], args), s.env, 120_000)
}

/// Execute Git with structured arguments.
///
/// ## Examples
///
/// ```gleam
/// // git.command(s, ["version"])
/// ```
pub fn command(s: Session, args: List(String)) -> Result(String, String) {
  use #(status, out) <- result.try(raw(s, args))

  // A nonzero exit carries Git’s bounded diagnostic.
  case status {
    0 -> Ok(out)
    _ -> Error("Git operation failed: " <> string.trim(out))
  }
}

/// Fetch an exact object or ref and return its resolved commit.
///
/// ## Examples
///
/// ```gleam
/// // git.fetch(s, "refs/heads/main")
/// ```
pub fn fetch(s: Session, reference: String) -> Result(String, String) {
  use _ <- result.try(
    command(s, ["fetch", "--quiet", "--no-tags", "--", s.url, reference]),
  )
  oid(s, "FETCH_HEAD")
}

/// Resolve an object as a full commit identity.
///
/// ## Examples
///
/// ```gleam
/// // git.oid(s, "FETCH_HEAD")
/// ```
pub fn oid(s: Session, reference: String) -> Result(String, String) {
  use out <- result.try(
    command(s, ["rev-parse", "--verify", reference <> "^{commit}"]),
  )
  let value = string.trim(out)

  // Only full immutable commit identifiers cross into the queue.
  case job.valid_sha(value) {
    True -> Ok(value)
    False -> Error("Git returned an invalid commit OID")
  }
}

/// Distinguish a negative ancestry result from an unreadable object graph.
///
/// ## Examples
///
/// ```gleam
/// // git.ancestor(s, base, candidate)
/// ```
pub fn ancestor(
  s: Session,
  older: String,
  newer: String,
) -> Result(Bool, String) {
  use #(status, _) <- result.try(
    raw(s, ["merge-base", "--is-ancestor", older, newer]),
  )

  // Git reserves exit code one for a valid negative ancestry answer.
  case status {
    0 -> Ok(True)
    1 -> Ok(False)
    _ -> Error("unable to check Git ancestry")
  }
}

/// Locate the immutable bundle on shared controller storage.
///
/// ## Examples
///
/// ```gleam
/// // git.bundle(cfg, repo, candidate)
/// ```
pub fn bundle(
  cfg: config.Config,
  repo: config.Repository,
  commit: String,
) -> String {
  cfg.blobs <> "/git/" <> repo.name <> "/" <> commit <> ".bundle"
}

/// Publish the integration objects missing from the protected target history.
///
/// ## Examples
///
/// ```gleam
/// // git.preserve(cfg, repo, s, base, candidate)
/// ```
pub fn preserve(
  cfg: config.Config,
  repo: config.Repository,
  s: Session,
  base: String,
  commit: String,
) -> Result(Nil, String) {
  let dir = cfg.blobs <> "/git/" <> repo.name
  use Nil <- result.try(
    simplifile.create_directory_all(dir)
    |> result.replace_error("cannot create shared Git directory"),
  )
  use _ <- result.try(
    command(s, ["update-ref", "refs/heads/candidate", commit]),
  )

  // Git writes to a lockfile and renames on success. A per-operation name
  // avoids contention until the complete file is ready to publish.
  use #(status, tmp) <- result.try(ffi_host.run(
    "mktemp",
    [dir <> "/.bundle.XXXXXXXXXX"],
    [],
    5000,
  ))

  // The staging file must share the destination filesystem for atomic rename.
  use Nil <- result.try(case status {
    0 -> Ok(Nil)
    _ -> Error("cannot allocate bundle file")
  })

  let tmp = string.trim(tmp)
  let outcome = {
    use _ <- result.try(
      command(s, ["bundle", "create", tmp, "refs/heads/candidate", "^" <> base]),
    )
    use Nil <- result.try(ffi_host.sync_path(tmp))

    use Nil <- result.try(
      simplifile.rename(tmp, bundle(cfg, repo, commit))
      |> result.replace_error("cannot publish candidate bundle"),
    )
    ffi_host.sync_path(dir)
  }
  let _ = simplifile.delete_file(tmp)
  outcome
}
