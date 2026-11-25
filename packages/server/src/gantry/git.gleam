//// One persistent bare mirror per repository holds every Git object the
//// controller reads, so each request fetches only what is new. A candidate
//// bundle is published atomically into shared storage before the queue sees
//// its OID.
////
//// ## Flow
////
//// `session` takes the repository's lock, creates the mirror on first use,
//// and runs the caller's work against it. The lock is a node-local OTP
//// global lock keyed by repository name. It serializes the shared state
//// that concurrent Git processes would corrupt: `FETCH_HEAD`, the
//// `refs/heads/candidate` name, the attributes file and the archive scratch
//// files. A lock held by a crashed process is released by OTP, so no stale
//// lock needs cleanup. Different repositories never contend.
////
//// | State | Where | Lifetime |
//// | --- | --- | --- |
//// | Mirror | `<data>/mirrors/<owner>/<name>.git` | Persists. Deleting it is safe, and the next request refetches. |
//// | Tracking refs | `refs/gantry/...` in the mirror | Persist, so a fetch advertises what it already has. |
//// | Scratch files | Beside the mirror, random names | Deleted by the call that made them. |

import gantry/blobs
import gantry/config
import gantry/fault.{type Fault}
import gantry/internal/ffi_host
import gantry/internal/ffi_lock
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// The repository's persistent bare mirror and its configured remote.
pub type Session {
  Session(dir: String, url: String, env: List(#(String, String)))
}

/// Run one controller operation against the repository's mirror while
/// holding its lock. The mirror survives the call, and the work must delete
/// any scratch file it makes.
///
/// ## Examples
///
/// ```gleam
/// // git.session(cfg, repo, fn(s) { git.fetch(s, "refs/heads/main") })
/// ```
pub fn session(
  cfg: config.Config,
  repo: config.Repository,
  work: fn(Session) -> Result(a, Fault),
) -> Result(a, Fault) {
  // Send credentials only to the configured GitHub HTTPS endpoint. Git's
  // housekeeping must finish inside the call that triggers it, or it would
  // run after the lock is released.
  let #(url, configuration) = case repo.provider {
    config.Local(path) -> #(path, [#("gc.autoDetach", "false")])
    config.GitHub(_) -> {
      let auth =
        bit_array.base64_encode(
          <<"x-access-token:":utf8, cfg.github_token:utf8>>,
          True,
        )
      #("https://github.com/" <> repo.name <> ".git", [
        #("gc.autoDetach", "false"),
        #(
          "http.https://github.com/.extraHeader",
          "Authorization: Basic " <> auth,
        ),
      ])
    }
  }
  let s = Session(mirror(cfg, repo), url, environment(configuration))

  ffi_lock.with_lock(repo.name, fn() {
    use Nil <- result.try(open(s))
    work(s)
  })
}

/// Pass Git its configuration through the environment, so no credential
/// reaches a file or a command line.
fn environment(
  configuration: List(#(String, String)),
) -> List(#(String, String)) {
  let entries =
    list.index_map(configuration, fn(pair, index) {
      let n = int.to_string(index)
      [#("GIT_CONFIG_KEY_" <> n, pair.0), #("GIT_CONFIG_VALUE_" <> n, pair.1)]
    })
  list.flatten([
    [#("GIT_CONFIG_COUNT", int.to_string(list.length(configuration)))],
    list.flatten(entries),
    [
      #("GIT_TERMINAL_PROMPT", "0"),
      #("GIT_CONFIG_NOSYSTEM", "1"),
      #("GIT_CONFIG_GLOBAL", "/dev/null"),
      #("GIT_AUTHOR_NAME", "Gantry"),
      #("GIT_AUTHOR_EMAIL", "gantry@localhost"),
      #("GIT_COMMITTER_NAME", "Gantry"),
      #("GIT_COMMITTER_EMAIL", "gantry@localhost"),
    ],
  ])
}

/// Locate a repository's mirror. The name is a validated `owner/name` slug.
fn mirror(cfg: config.Config, repo: config.Repository) -> String {
  cfg.data <> "/mirrors/" <> repo.name <> ".git"
}

/// Create the bare mirror on first use. `HEAD` exists only after Git has
/// finished initializing, so a crash midway leaves a directory that the
/// next call initializes again.
fn open(s: Session) -> Result(Nil, Fault) {
  case simplifile.is_file(s.dir <> "/HEAD") {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) -> {
      use Nil <- result.try(
        simplifile.create_directory_all(s.dir)
        |> result.replace_error(fault.Unavailable(
          "cannot create the Git mirror directory",
        )),
      )
      command(s, ["init", "--bare", "--quiet", "--template="])
      |> result.replace(Nil)
    }
  }
}

/// A fresh random path for a scratch file beside the mirror. The caller
/// deletes it before the session ends.
///
/// ## Examples
///
/// ```gleam
/// // git.scratch(s, "source.tar")
/// // -> "/data/mirrors/o/p.git/gantry-4f9c1a2b7d3e5a60-source.tar"
/// ```
pub fn scratch(s: Session, name: String) -> String {
  s.dir <> "/gantry-" <> blobs.unique_suffix() <> "-" <> name
}

/// Preserve Git exit codes for commands with meaningful negative answers.
fn raw(s: Session, args: List(String)) -> Result(#(Int, String), Fault) {
  ffi_host.run("git", list.append(["-C", s.dir], args), s.env, 120_000)
  |> result.map_error(fault.Unavailable)
}

/// Execute Git with structured arguments.
///
/// ## Examples
///
/// ```gleam
/// // git.command(s, ["version"])
/// ```
pub fn command(s: Session, args: List(String)) -> Result(String, Fault) {
  use #(status, out) <- result.try(raw(s, args))

  // A nonzero exit carries Git’s bounded diagnostic.
  case status {
    0 -> Ok(out)
    _ -> Error(fault.Unavailable("Git operation failed: " <> string.trim(out)))
  }
}

/// Fetch an exact object or ref and return its resolved commit. A ref keeps
/// a tracking ref in the mirror, so the next fetch advertises what the
/// mirror already has and transfers only the difference. A full object ID
/// that the mirror already holds needs no fetch.
///
/// ## Examples
///
/// ```gleam
/// // git.fetch(s, "refs/heads/main")
/// ```
pub fn fetch(s: Session, reference: String) -> Result(String, Fault) {
  case string.starts_with(reference, "refs/") {
    True -> {
      let tracking = "refs/gantry/" <> string.drop_start(reference, 5)
      use _ <- result.try(
        command(s, [
          "fetch",
          "--quiet",
          "--no-tags",
          "--",
          s.url,
          "+" <> reference <> ":" <> tracking,
        ]),
      )
      oid(s, tracking)
    }
    False -> {
      use #(known, _) <- result.try(
        raw(s, ["cat-file", "-e", reference <> "^{commit}"]),
      )

      // An object ID is content-addressed, so a local copy is the object.
      case known {
        0 -> oid(s, reference)
        _ -> {
          use _ <- result.try(
            command(s, [
              "fetch",
              "--quiet",
              "--no-tags",
              "--",
              s.url,
              reference,
            ]),
          )
          oid(s, "FETCH_HEAD")
        }
      }
    }
  }
}

/// Resolve an object as a full commit identity.
///
/// ## Examples
///
/// ```gleam
/// // git.oid(s, "FETCH_HEAD")
/// ```
pub fn oid(s: Session, reference: String) -> Result(String, Fault) {
  use out <- result.try(
    command(s, ["rev-parse", "--verify", reference <> "^{commit}"]),
  )
  let value = string.trim(out)

  // Only full immutable commit identifiers cross into the queue.
  case string.byte_size(value) == 40 && blobs.lower_hex(value) {
    True -> Ok(value)
    False -> Error(fault.Internal("Git returned an invalid commit OID"))
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
) -> Result(Bool, Fault) {
  use #(status, _) <- result.try(
    raw(s, ["merge-base", "--is-ancestor", older, newer]),
  )

  // Git reserves exit code one for a valid negative ancestry answer.
  case status {
    0 -> Ok(True)
    1 -> Ok(False)
    _ -> Error(fault.Unavailable("unable to check Git ancestry"))
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
) -> Result(Nil, Fault) {
  let dir = cfg.blobs <> "/git/" <> repo.name
  use Nil <- result.try(
    simplifile.create_directory_all(dir)
    |> result.replace_error(fault.Unavailable(
      "cannot create shared Git directory",
    )),
  )
  use _ <- result.try(
    command(s, ["update-ref", "refs/heads/candidate", commit]),
  )

  // Git writes to a lockfile and renames on success. A per-operation name
  // avoids contention until the complete file is ready to publish, and it
  // shares the destination filesystem so the final rename is atomic.
  let tmp = dir <> "/.bundle-" <> blobs.unique_suffix()
  let outcome = {
    use _ <- result.try(
      command(s, ["bundle", "create", tmp, "refs/heads/candidate", "^" <> base]),
    )
    use Nil <- result.try(sync(tmp))

    use Nil <- result.try(
      simplifile.rename(tmp, bundle(cfg, repo, commit))
      |> result.replace_error(fault.Unavailable(
        "cannot publish candidate bundle",
      )),
    )
    sync(dir)
  }
  let _ = simplifile.delete_file(tmp)
  outcome
}

/// Flush a published path, treating a failure as a retryable storage fault.
fn sync(path: String) -> Result(Nil, Fault) {
  ffi_host.sync_path(path) |> result.map_error(fault.Unavailable)
}
