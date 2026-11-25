import gantry/config
import gantry/internal/ffi_host
import gantry/submit
import gantry_core/queue
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/string
import simplifile

/// A bare remote with `main` at `base`, a candidate commit that is a child of
/// the base, and a stored bundle for it. `refs/pull/1/head` names the pinned
/// head.
type Fixture {
  Fixture(
    root: String,
    remote: String,
    cfg: config.Config,
    repo: config.Repository,
    base: String,
    commit: String,
    intent: queue.Intent,
  )
}

fn git(directory: String, arguments: List(String)) -> String {
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

fn commit_file(work: String, name: String) -> String {
  let assert Ok(Nil) = simplifile.write(work <> "/" <> name, name)
  git(work, ["add", name])
  git(work, ["commit", "-q", "-m", name])
  git(work, ["rev-parse", "HEAD"])
}

fn fixture() -> Fixture {
  let suffix = crypto.strong_random_bytes(8) |> bit_array.base16_encode
  let root = "/tmp/gantry-submit-test-" <> suffix
  let remote = root <> "/remote.git"
  let work = root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(work)
  let assert Ok(Nil) = simplifile.create_directory_all(remote)
  git(remote, ["init", "--bare", "--quiet", "-b", "main"])
  git(work, ["init", "--quiet", "-b", "main"])
  let base = commit_file(work, "base")
  git(work, ["push", "--quiet", remote, "main"])
  git(work, ["checkout", "--quiet", "-b", "candidate"])
  let commit = commit_file(work, "change")
  git(work, ["push", "--quiet", remote, commit <> ":refs/pull/1/head"])

  let repo =
    config.Repository(
      name: "owner/project",
      provider: config.Local(remote),
      branch: "main",
      target: "check",
      pool: "default",
      image: "image@sha256:" <> string.repeat("a", 64),
    )
  let cfg =
    config.Config(
      data: root <> "/data",
      blobs: root <> "/blobs",
      port: 4737,
      seed: "",
      repositories: dict.from_list([#(repo.name, repo)]),
      agent_token: "",
      workers: [],
      submit_token: "",
      github_token: "",
    )
  let bundles = root <> "/blobs/git/owner/project"
  let assert Ok(Nil) = simplifile.create_directory_all(bundles)
  git(work, [
    "bundle",
    "create",
    bundles <> "/" <> commit <> ".bundle",
    "refs/heads/candidate",
    "^" <> base,
  ])
  let candidate =
    queue.Candidate("main", base, commit, [queue.Member(1, commit)])
  Fixture(
    root:,
    remote:,
    cfg:,
    repo:,
    base:,
    commit:,
    intent: queue.Intent("run-1", "owner/project", candidate),
  )
}

fn remote_main(f: Fixture) -> String {
  git(f.remote, ["rev-parse", "refs/heads/main"])
}

fn finish(f: Fixture) -> Nil {
  let _ = simplifile.delete(f.root)
  Nil
}

pub fn a_local_pull_that_moved_resolves_as_a_refusal_test() {
  let f = fixture()

  // The pull ref now names a different commit than the tested pin.
  let work = f.root <> "/work"
  git(work, ["checkout", "--quiet", "-b", "other", f.base])
  let moved = commit_file(work, "moved")
  git(work, ["push", "--quiet", "-f", f.remote, moved <> ":refs/pull/1/head"])

  assert submit.reconcile(f.cfg, f.repo, f.intent)
    == Ok(submit.Refused("pull head changed while submission unresolved"))

  // Nothing was pushed, so the target is untouched.
  assert remote_main(f) == f.base
  finish(f)
}

pub fn a_current_pull_lands_by_expected_old_oid_push_test() {
  let f = fixture()
  assert submit.reconcile(f.cfg, f.repo, f.intent) == Ok(submit.Landed)
  assert remote_main(f) == f.commit

  // A replay observes the landing and does not push again.
  assert submit.reconcile(f.cfg, f.repo, f.intent) == Ok(submit.Landed)
  finish(f)
}

pub fn a_target_that_advanced_elsewhere_is_refused_test() {
  let f = fixture()
  let work = f.root <> "/work"
  git(work, ["checkout", "--quiet", "-b", "elsewhere", f.base])
  let other = commit_file(work, "elsewhere")
  git(work, ["push", "--quiet", "-f", f.remote, other <> ":refs/heads/main"])

  assert submit.reconcile(f.cfg, f.repo, f.intent)
    == Ok(submit.Refused("target advanced outside the tested candidate"))
  assert remote_main(f) == other
  finish(f)
}

pub fn a_missing_bundle_keeps_the_intent_open_test() {
  let f = fixture()
  let assert Ok(Nil) = simplifile.delete(blobs_bundle(f))

  // The outcome is unknown, so reconcile reports an error and decides nothing.
  let assert Error(_) = submit.reconcile(f.cfg, f.repo, f.intent)
  assert remote_main(f) == f.base
  finish(f)
}

fn blobs_bundle(f: Fixture) -> String {
  f.cfg.blobs <> "/git/owner/project/" <> f.commit <> ".bundle"
}
