//// Only the operator's repository entry sets a sandbox profile, a pool serves
//// one profile, and a wider profile changes the cache key while a strict one
//// keeps the key it had before profiles existed.

import gantry/config
import gantry/prepare
import gantry/support
import gantry_core/queue
import gantry_core/request
import gantry_core/sandbox
import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/string

fn secrets() -> config.Secrets {
  config.Secrets(
    agent: "agent-token-agent-token-agent-token-0",
    submit: "submit-token-submit-token-submit-tok0",
    view: None,
    github: "",
  )
}

fn repository(name: String, pool: String, sandbox: String) -> String {
  "\n[[repository]]\nname = \""
  <> name
  <> "\"\npool = \""
  <> pool
  <> "\"\nimage = \"alpine@sha256:"
  <> string.repeat("a", 64)
  <> "\"\n"
  <> sandbox
}

fn document(repositories: String) -> String {
  "data_dir = \"/srv/gantry/controller\"\nblob_dir = \"/srv/gantry/shared\"\n\n"
  <> "[[worker]]\nid = \"linux-01\"\ntoken_sha256 = \""
  <> config.token_digest("token-for-linux-01")
  <> "\"\n"
  <> repositories
}

fn profile_of(text: String, name: String) -> sandbox.Profile {
  let assert Ok(cfg) = config.parse(text, secrets())
  let assert Ok(repo) = dict.get(cfg.repositories, name)
  repo.sandbox
}

pub fn a_repository_without_a_sandbox_line_is_strict_test() {
  let text = document(repository("owner/a", "linux", ""))
  assert profile_of(text, "owner/a") == sandbox.Strict
}

pub fn the_operator_can_approve_userns_test() {
  let text =
    document(repository("owner/a", "linux-wide", "sandbox = \"userns\"\n"))
  assert profile_of(text, "owner/a") == sandbox.Userns
}

pub fn an_unknown_profile_fails_to_load_test() {
  list.each(["\"unconfined\"", "\"\"", "\"Userns\"", "true"], fn(value) {
    let text =
      document(repository("owner/a", "linux", "sandbox = " <> value <> "\n"))
    let assert Error(_) = config.parse(text, secrets())
  })
}

pub fn a_pool_serves_one_profile_test() {
  let mixed =
    document(
      repository("owner/a", "linux", "")
      <> repository("owner/b", "linux", "sandbox = \"userns\"\n"),
    )
  let assert Error(message) = config.parse(mixed, secrets())
  assert string.contains(message, "linux")

  // Separate pools, or one profile shared by a pool, both load.
  let separate =
    document(
      repository("owner/a", "linux", "")
      <> repository("owner/b", "linux-wide", "sandbox = \"userns\"\n")
      <> repository("owner/c", "linux-wide", "sandbox = \"userns\"\n"),
    )
  let assert Ok(_) = config.parse(separate, secrets())
}

pub fn only_a_wider_profile_changes_the_recipe_test() {
  let r = support.remote()
  let #(cfg, repo) =
    support.config_for(r, "owner/project", queue.Retention(200, 1000))
  let assert Ok(pinned) =
    request.build("recipe", "owner/project", r.base, "check", None)
  let assert Ok(strict) = prepare.build(cfg, repo, pinned)
  let wide = config.Repository(..repo, sandbox: sandbox.Userns)
  let assert Ok(userns) = prepare.build(cfg, wide, pinned)

  assert strict != []
  list.zip(strict, userns)
  |> list.each(fn(pair) {
    let #(a, b) = pair
    assert a.sandbox == sandbox.Strict
    assert b.sandbox == sandbox.Userns
    assert a.recipe != b.recipe
    assert a.source == b.source
  })

  // A strict recipe is stable across preparations of the same revision.
  let assert Ok(again) = prepare.build(cfg, repo, pinned)
  assert list.map(again, fn(task) { task.recipe })
    == list.map(strict, fn(task) { task.recipe })
}
