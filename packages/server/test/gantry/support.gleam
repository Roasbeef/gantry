//// Fixtures shared by the controller tests: a throwaway bare remote with a
//// manifest, a controller configuration over it, and one Khepri store for the
//// whole test VM.

import envoy
import gantry/config
import gantry/internal/ffi_host
import gantry/store
import gantry_core/queue
import gantry_core/sandbox
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/option
import gleam/string
import simplifile

/// The manifest every fixture repository carries. One action, no inputs, so
/// the staged archive is the empty one.
const manifest =
  "{\"actions\":[{\"name\":\"check\",\"argv\":[\"true\"],\"inputs\":[],\"outputs\":[],\"timeout\":10}],\"targets\":{\"check\":[\"check\"]}}"

/// A bare remote and a work clone, with `main` at `base`.
pub type Remote {
  Remote(root: String, remote: String, work: String, base: String)
}

/// A random path under /tmp for one test.
pub fn directory(prefix: String) -> String {
  let suffix = crypto.strong_random_bytes(8) |> bit_array.base16_encode
  let root = "/tmp/gantry-" <> prefix <> "-" <> suffix
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  root
}

/// Run Git in `directory` with a fixed identity, returning trimmed output.
pub fn git(directory: String, arguments: List(String)) -> String {
  let env = [
    #("GIT_CONFIG_GLOBAL", "/dev/null"),
    #("GIT_CONFIG_NOSYSTEM", "1"),
    #("GIT_AUTHOR_NAME", "Test"),
    #("GIT_AUTHOR_EMAIL", "test@localhost"),
    #("GIT_COMMITTER_NAME", "Test"),
    #("GIT_COMMITTER_EMAIL", "test@localhost"),
  ]
  let assert Ok(#(0, out)) =
    ffi_host.run("git", ["-C", directory, ..arguments], env, 30_000)
  string.trim(out)
}

/// Write a file in the work clone, commit it, and return the new commit.
pub fn commit_file(work: String, name: String, contents: String) -> String {
  let assert Ok(Nil) = simplifile.write(work <> "/" <> name, contents)
  git(work, ["add", name])
  git(work, ["commit", "-q", "-m", name])
  git(work, ["rev-parse", "HEAD"])
}

/// A remote whose `main` holds the manifest.
pub fn remote() -> Remote {
  let root = directory("remote")
  let remote = root <> "/remote.git"
  let work = root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(remote)
  let assert Ok(Nil) = simplifile.create_directory_all(work)
  git(remote, ["init", "--bare", "--quiet", "-b", "main"])
  git(work, ["init", "--quiet", "-b", "main"])
  let assert Ok(Nil) = simplifile.write(work <> "/gantry.json", manifest)
  git(work, ["add", "gantry.json"])
  let base = commit_file(work, "readme", "base")
  git(work, ["push", "--quiet", remote, "main"])
  Remote(root:, remote:, work:, base:)
}

/// Publish a commit made on a branch off `main` as `refs/pull/<n>/head`.
pub fn pull(
  r: Remote,
  number: String,
  file: String,
  contents: String,
) -> String {
  git(r.work, ["checkout", "--quiet", "-B", "pull-" <> number, r.base])
  let head = commit_file(r.work, file, contents)
  git(r.work, [
    "push",
    "--quiet",
    "-f",
    r.remote,
    head <> ":refs/pull/" <> number <> "/head",
  ])
  head
}

/// The commit `main` names on the remote.
pub fn main_of(r: Remote) -> String {
  git(r.remote, ["rev-parse", "refs/heads/main"])
}

/// A controller configuration over one local remote registered as `name`.
pub fn config_for(
  r: Remote,
  name: String,
  retention: queue.Retention,
) -> #(config.Config, config.Repository) {
  let repo =
    config.Repository(
      name:,
      provider: config.Local(r.remote),
      branch: "main",
      target: "check",
      pool: "default",
      image: "image@sha256:" <> string.repeat("a", 64),
      sandbox: sandbox.Strict,
    )
  let cfg =
    config.Config(
      data: r.root <> "/data",
      blobs: r.root <> "/blobs",
      port: 4737,
      seed: "",
      repositories: dict.from_list([#(name, repo)]),
      workers: [],
      retention:,
      agent_token: "",
      submit_token: "",
      view_token: option.None,
      github_token: "",
    )
  #(cfg, repo)
}

/// Open the one Khepri store of this test VM, once. Later calls find it
/// recorded in the environment and reuse it.
pub fn boot_store() -> Nil {
  case envoy.get("GANTRY_TEST_STORE") {
    Ok(_) -> Nil
    Error(Nil) -> {
      let root = directory("store")
      let assert Ok(Nil) = store.boot(root, "")
      envoy.set("GANTRY_TEST_STORE", root)
    }
  }
}

/// A random run ID for a test, so the shared store never sees a repeat.
pub fn run_id(prefix: String) -> String {
  let suffix = crypto.strong_random_bytes(4) |> bit_array.base16_encode
  prefix <> "-" <> string.lowercase(suffix)
}
