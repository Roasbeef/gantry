import gantry/api
import gantry/config
import gantry/fault
import gleam/dict
import gleam/option
import gleam/string

const agent = "agent-token-agent-token-agent-token-0"

const submit = "submit-token-submit-token-submit-tok0"

fn secrets() -> config.Secrets {
  config.Secrets(agent:, submit:, view: option.None, github: "")
}

/// A complete configuration whose workers section is `workers`.
fn document(workers: String) -> String {
  "data_dir = \"/srv/gantry/controller\"\nblob_dir = \"/srv/gantry/shared\"\n\n"
  <> workers
  <> "\n[[repository]]\nname = \"owner/project\"\nimage = \"alpine@sha256:"
  <> string.repeat("a", 64)
  <> "\"\n"
}

fn worker_entry(id: String, token: String) -> String {
  "[[worker]]\nid = \""
  <> id
  <> "\"\ntoken_sha256 = \""
  <> config.token_digest(token)
  <> "\"\n"
}

fn loaded() -> config.Config {
  let text =
    document(
      worker_entry("linux-01", "token-for-linux-01")
      <> worker_entry("linux-02", "token-for-linux-02"),
    )
  let assert Ok(cfg) = config.parse(text, secrets())
  cfg
}

pub fn a_legacy_shared_token_configuration_fails_to_load_test() {
  // No [[worker]] entries is the earlier format.
  let assert Error(message) = config.parse(document(""), secrets())
  assert string.contains(message, "[[worker]]")
  assert string.contains(message, "token_sha256")
  assert string.contains(message, "GANTRY_WORKER_TOKEN")
}

pub fn workers_load_with_their_registered_identities_test() {
  let cfg = loaded()
  assert list_ids(cfg) == ["linux-01", "linux-02"]
  assert dict.size(cfg.repositories) == 1
}

fn list_ids(cfg: config.Config) -> List(String) {
  let config.Config(workers:, ..) = cfg
  case workers {
    [first, second] -> [first.id, second.id]
    _ -> []
  }
}

pub fn a_token_selects_exactly_its_worker_test() {
  let cfg = loaded()
  assert config.worker_for(cfg, "token-for-linux-01") == Ok("linux-01")
  assert config.worker_for(cfg, "token-for-linux-02") == Ok("linux-02")
  assert config.worker_for(cfg, "token-for-linux-03") == Error(Nil)
  assert config.worker_for(cfg, "") == Error(Nil)

  // A role token is not a worker credential.
  assert config.worker_for(cfg, agent) == Error(Nil)
}

pub fn malformed_worker_tables_fail_to_load_test() {
  let digest = config.token_digest("token-for-linux-01")
  let bad = [
    // Repeated identifier.
    worker_entry("linux-01", "token-a") <> worker_entry("linux-01", "token-b"),
    // Repeated token.
    worker_entry("linux-01", "token-a") <> worker_entry("linux-02", "token-a"),
    // An identifier that is not one path component.
    worker_entry("linux/01", "token-a"),
    // A digest that is not 64 lowercase hex digits.
    "[[worker]]\nid = \"linux-01\"\ntoken_sha256 = \""
      <> string.uppercase(digest)
      <> "\"\n",
    "[[worker]]\nid = \"linux-01\"\ntoken_sha256 = \"abc\"\n",
    // A worker whose token is a role token.
    worker_entry("linux-01", agent),
    worker_entry("linux-01", submit),
  ]
  list_each(bad, fn(workers) {
    let assert Error(_) = config.parse(document(workers), secrets())
    Nil
  })
}

fn list_each(items: List(a), run: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [first, ..rest] -> {
      run(first)
      list_each(rest, run)
    }
  }
}

pub fn a_body_naming_another_worker_is_forbidden_test() {
  let body = "{\"worker\":\"linux-02\",\"pool\":\"default\"}"

  // The refusal comes before any queue read, so no store is needed.
  let assert Error(fault.Forbidden(_)) = api.claim("linux-01", body)
}

pub fn a_result_naming_another_worker_is_forbidden_test() {
  let body =
    "{\"run\":\"r\",\"action\":\"a\",\"worker\":\"linux-02\",\"serial\":1,\"completion\":{\"kind\":\"rejected\",\"reason\":\"x\",\"log\":\""
    <> string.repeat("0", 64)
    <> "\"}}"
  let assert Error(fault.Forbidden(_)) = api.finish(loaded(), "linux-01", body)
}

pub fn a_worker_may_carry_a_host_label_test() {
  let text =
    document(
      worker_entry("linux-01", "token-for-linux-01")
      <> "host = \"gilgamesh\"\n"
      <> worker_entry("linux-02", "token-for-linux-02"),
    )
  let assert Ok(cfg) = config.parse(text, secrets())
  let assert [first, second] = cfg.workers
  assert first.host == option.Some("gilgamesh")
  assert second.host == option.None
}

pub fn a_host_label_must_be_an_identifier_test() {
  let text =
    document(
      worker_entry("linux-01", "token-for-linux-01") <> "host = \"../x\"\n",
    )
  let assert Error(_) = config.parse(text, secrets())
}

pub fn the_view_token_must_differ_from_the_role_tokens_test() {
  let text = document(worker_entry("linux-01", "token-for-linux-01"))
  let view = "view-token-view-token-view-token-0000"
  let assert Ok(cfg) =
    config.parse(text, config.Secrets(..secrets(), view: option.Some(view)))
  assert cfg.view_token == option.Some(view)
  let assert Error(_) =
    config.parse(text, config.Secrets(..secrets(), view: option.Some(agent)))
  let assert Error(_) =
    config.parse(text, config.Secrets(..secrets(), view: option.Some(submit)))
}

pub fn a_worker_token_cannot_be_the_view_token_test() {
  let view = "view-token-view-token-view-token-0000"
  let text = document(worker_entry("linux-01", view))
  let assert Error(_) =
    config.parse(text, config.Secrets(..secrets(), view: option.Some(view)))
}
