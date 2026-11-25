import gantry/config
import gantry/git
import gantry/internal/ffi_host
import gantry/prepare
import gantry_core/queue
import gantry_core/request
import gantry_core/sandbox
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import simplifile

fn directory() -> String {
  let suffix = crypto.strong_random_bytes(8) |> bit_array.base16_encode
  let root = "/tmp/gantry-git-test-" <> suffix
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  root
}

fn config_for(
  root: String,
  remote: String,
) -> #(config.Config, config.Repository) {
  let repo =
    config.Repository(
      name: "owner/project",
      provider: config.Local(remote),
      branch: "main",
      target: "check",
      pool: "default",
      image: "image@sha256:" <> string.repeat("a", 64),
      sandbox: sandbox.Strict,
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
      retention: queue.Retention(200, 1000),
      submit_token: "",
      view_token: option.None,
      github_token: "",
    )
  #(cfg, repo)
}

fn run_git(directory: String, arguments: List(String)) -> String {
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

fn remote_with_commit(root: String) -> #(String, String, String) {
  let remote = root <> "/remote.git"
  let work = root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(remote)
  let assert Ok(Nil) = simplifile.create_directory_all(work)
  run_git(remote, ["init", "--bare", "--quiet", "-b", "main"])
  run_git(work, ["init", "--quiet", "-b", "main"])
  let assert Ok(Nil) = simplifile.write(work <> "/a", "a")
  run_git(work, ["add", "a"])
  run_git(work, ["commit", "-q", "-m", "a"])
  run_git(work, ["push", "--quiet", remote, "main"])
  #(remote, work, run_git(work, ["rev-parse", "HEAD"]))
}

pub fn the_mirror_persists_and_fetches_incrementally_test() {
  let root = directory()
  let #(remote, work, first) = remote_with_commit(root)
  let #(cfg, repo) = config_for(root, remote)

  // The first request creates the mirror and a tracking ref.
  let assert Ok(seen) =
    git.session(cfg, repo, fn(s) { git.fetch(s, "refs/heads/main") })
  assert seen == first
  let mirror = root <> "/data/mirrors/owner/project.git"
  let assert Ok(True) = simplifile.is_file(mirror <> "/HEAD")

  // A later request reuses the mirror and sees the new commit.
  let assert Ok(Nil) = simplifile.write(work <> "/b", "b")
  run_git(work, ["add", "b"])
  run_git(work, ["commit", "-q", "-m", "b"])
  run_git(work, ["push", "--quiet", remote, "main"])
  let second = run_git(work, ["rev-parse", "HEAD"])
  let assert Ok(seen) =
    git.session(cfg, repo, fn(s) { git.fetch(s, "refs/heads/main") })
  assert seen == second

  // The tracking ref and both commits remain in the same mirror.
  assert run_git(mirror, ["rev-parse", "refs/gantry/heads/main"]) == second
  assert run_git(mirror, ["cat-file", "-t", first]) == "commit"

  // A pinned object the mirror already holds resolves without the remote.
  let assert Ok(Nil) = simplifile.delete(remote)
  let assert Ok(known) = git.session(cfg, repo, fn(s) { git.fetch(s, first) })
  assert known == first
  let _ = simplifile.delete(root)
}

pub fn sessions_on_one_repository_do_not_overlap_test() {
  let root = directory()
  let #(remote, _, _) = remote_with_commit(root)
  let #(cfg, repo) = config_for(root, remote)
  let log = root <> "/log"
  let finished = process.new_subject()

  let worker = fn(name) {
    fn() {
      let _ =
        git.session(cfg, repo, fn(_) {
          let assert Ok(Nil) = simplifile.append(log, name <> "-in\n")
          process.sleep(150)
          let assert Ok(Nil) = simplifile.append(log, name <> "-out\n")
          Ok(Nil)
        })
      process.send(finished, Nil)
    }
  }
  let _ = process.spawn(worker("a"))
  let _ = process.spawn(worker("b"))
  let _ = process.spawn(worker("c"))
  list.each([1, 2, 3], fn(_) {
    let assert Ok(Nil) = process.receive(finished, 30_000)
  })

  // Every entry is followed by its own exit before another entry.
  let assert Ok(text) = simplifile.read(log)
  let lines = string.split(string.trim(text), "\n")
  assert list.length(lines) == 6
  list.sized_chunk(lines, 2)
  |> list.each(fn(pair) {
    let assert [entered, left] = pair
    assert string.replace(entered, "-in", "")
      == string.replace(left, "-out", "")
  })
  let _ = simplifile.delete(root)
}

pub fn the_empty_archive_is_ten_zero_blocks_test() {
  let archive = prepare.empty_archive()
  assert bit_array.byte_size(archive) == 10_240
  assert archive == <<0:size(81_920)>>

  // A tar reader accepts it as an archive with no members.
  let root = directory()
  let path = root <> "/empty.tar"
  let assert Ok(Nil) = simplifile.write_bits(archive, to: path)
  let assert Ok(#(0, listing)) = ffi_host.run("tar", ["-tf", path], [], 10_000)
  assert listing == ""
  let _ = simplifile.delete(root)
}

pub fn stale_lock_files_from_a_killed_git_are_cleared_test() {
  let root = directory()
  let #(remote, _, _) = remote_with_commit(root)
  let #(cfg, repo) = config_for(root, remote)
  let assert Ok(_) =
    git.session(cfg, repo, fn(s) { git.fetch(s, "refs/heads/main") })

  // A killed fetch leaves lock files in the mirror and its ref directories.
  let mirror = root <> "/data/mirrors/owner/project.git"
  let ref_lock = mirror <> "/refs/gantry/heads/main.lock"
  let shallow_lock = mirror <> "/shallow.lock"
  let assert Ok(Nil) = simplifile.write(ref_lock, "")
  let assert Ok(Nil) = simplifile.write(shallow_lock, "")

  // Clearing removes them and leaves every other file in place.
  git.clear_locks(mirror)
  assert simplifile.is_file(ref_lock) == Ok(False)
  assert simplifile.is_file(shallow_lock) == Ok(False)
  assert simplifile.is_file(mirror <> "/HEAD") == Ok(True)
  let _ = simplifile.delete(root)
}

pub fn shallow_metadata_makes_a_checkout_a_clean_shallow_repository_test() {
  let root = directory()
  let #(remote, work, first) = remote_with_commit(root)
  let assert Ok(Nil) = simplifile.write(work <> "/b", "b")
  run_git(work, ["add", "b"])
  run_git(work, ["commit", "-q", "-m", "b"])
  run_git(work, ["push", "--quiet", remote, "main"])
  let second = run_git(work, ["rev-parse", "HEAD"])
  let #(cfg, repo) = config_for(root, remote)

  let assert Ok(archive) =
    git.session(cfg, repo, fn(s) {
      use sha <- result.try(git.fetch(s, "refs/heads/main"))
      assert sha == second
      git.shallow_metadata(s, sha)
    })

  // Check out the tree as the worker does, then lay the metadata over it.
  let checkout = root <> "/checkout"
  let assert Ok(Nil) = simplifile.create_directory_all(checkout)
  let assert Ok(Nil) = simplifile.write_bits(root <> "/git.tar", archive)
  let assert Ok(Nil) = simplifile.write(checkout <> "/a", "a")
  let assert Ok(Nil) = simplifile.write(checkout <> "/b", "b")
  let assert Ok(#(0, _)) =
    ffi_host.run("tar", ["xf", root <> "/git.tar", "-C", checkout], [], 30_000)

  assert run_git(checkout, ["rev-parse", "--verify", "HEAD^{commit}"]) == second
  assert run_git(checkout, ["rev-parse", "--is-shallow-repository"]) == "true"
  assert run_git(checkout, ["rev-list", "--count", "HEAD"]) == "1"
  assert run_git(checkout, ["status", "--porcelain=v1", "--untracked-files=all"])
    == ""
  assert run_git(checkout, ["cat-file", "-p", "HEAD:b"]) == "b"

  // Git exits 1 when no key matches, so no remote or promisor is configured.
  let assert Ok(#(1, "")) =
    ffi_host.run(
      "git",
      ["-C", checkout, "config", "--get-regexp", "remote|promisor"],
      [],
      30_000,
    )
  // The parent exists in the mirror but must not be in the archive.
  let assert Ok(#(status, _)) =
    ffi_host.run(
      "git",
      ["-C", checkout, "cat-file", "-e", first <> "^{commit}"],
      [],
      30_000,
    )
  assert status != 0
}

pub fn only_an_action_that_declares_git_changes_key_with_the_commit_test() {
  let root = directory()
  let #(remote, work, _) = remote_with_commit(root)
  let manifest =
    "{\"actions\":["
    <> "{\"name\":\"plain\",\"argv\":[\"true\"],\"inputs\":[\"a\"]},"
    <> "{\"name\":\"meta\",\"argv\":[\"true\"],\"inputs\":[\"a\"],\"git\":\"shallow\"}"
    <> "],\"targets\":{\"all\":[\"plain\",\"meta\"]}}"
  let assert Ok(Nil) = simplifile.write(work <> "/gantry.json", manifest)
  run_git(work, ["add", "gantry.json"])
  run_git(work, ["commit", "-q", "-m", "manifest"])
  let first = run_git(work, ["rev-parse", "HEAD"])

  // The next commit changes a file neither action reads.
  let assert Ok(Nil) = simplifile.write(work <> "/unrelated", "x")
  run_git(work, ["add", "unrelated"])
  run_git(work, ["commit", "-q", "-m", "unrelated"])
  let second = run_git(work, ["rev-parse", "HEAD"])
  run_git(work, ["push", "--quiet", remote, "main"])

  let #(cfg, repo) = config_for(root, remote)
  let recipes = fn(commit) {
    let assert Ok(build) =
      request.build("b-" <> commit, "owner/project", commit, "all", option.None)
    let assert Ok(tasks) = prepare.build(cfg, repo, build)
    list.map(tasks, fn(task) { #(task.action.name, task) })
    |> dict.from_list
  }
  let one = recipes(first)
  let two = recipes(second)
  let assert Ok(plain_one) = dict.get(one, "plain")
  let assert Ok(plain_two) = dict.get(two, "plain")
  let assert Ok(meta_one) = dict.get(one, "meta")
  let assert Ok(meta_two) = dict.get(two, "meta")

  // The undeclared action keeps its key, and so reuses its proof.
  assert plain_one.recipe == plain_two.recipe
  assert plain_one.git == option.None
  // The declared one moves with the commit, and carries its archive.
  assert meta_one.recipe != meta_two.recipe
  assert option.is_some(meta_one.git)
  // The two actions have the same source and policy, yet different keys.
  assert plain_one.recipe != meta_one.recipe
  assert plain_one.source == meta_one.source
}
