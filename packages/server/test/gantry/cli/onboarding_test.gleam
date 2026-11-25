//// Profile decoding, minting, atomic saves, and gateway origins are pure
//// enough to check without Docker or a release.

import gantry/cli/failure
import gantry/cli/onboarding
import gantry/cli/origin
import gantry/cli/profile
import gantry/config
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

const token = "0123456789abcdef0123456789abcdef"

pub fn minted_local_profile_round_trips_test() {
  let local = profile.new_local("/state/gantry/local", 4737)
  let text = json.to_string(profile.encode_local(local))
  assert profile.parse_local(text) == Ok(local)
  assert string.starts_with(profile.node(local), "gantry_")
  assert string.ends_with(profile.node(local), "@127.0.0.1")
  assert string.starts_with(profile.local_worker_id(local), "local-")
  assert profile.credential(profile.agent_token(local))
  assert profile.credential(profile.cookie(local))

  // Each mint draws fresh identities and credentials.
  let other = profile.new_local("/state/gantry/local", 4737)
  assert profile.node(other) != profile.node(local)
  assert profile.agent_token(other) != profile.agent_token(local)
}

pub fn bash_written_local_profile_reopens_test() {
  // The shape the Bash helper saved, field order and all.
  let text =
    "{\"version\":1,\"kind\":\"local\",\"node\":\"gantry_0123456789abcdef@127.0.0.1\",\"worker_id\":\"local-0123456789abcdef\",\"directory\":\"/s/gantry/local\",\"port\":4737,\"agent_token\":\""
    <> token
    <> "\",\"worker_token\":\""
    <> token
    <> "\",\"submit_token\":\""
    <> token
    <> "\",\"cookie\":\""
    <> token
    <> "\"}\n"
  let assert Ok(local) = profile.parse_local(text)
  assert profile.port(local) == 4737
  assert profile.directory(local) == "/s/gantry/local"
}

pub fn invalid_local_profiles_are_rejected_test() {
  let local = profile.new_local("/state", 4737)
  let good = profile.encode_local(local) |> json.to_string
  let swaps = [
    #("\"version\":1", "\"version\":2"),
    #("\"kind\":\"local\"", "\"kind\":\"worker\""),
    #("\"port\":4737", "\"port\":0"),
    #("\"port\":4737", "\"port\":65536"),
    #("@127.0.0.1", "@10.0.0.1"),
    #(profile.agent_token(local), "short"),
    #(profile.cookie(local), "has space " <> token),
  ]
  list.each(swaps, fn(swap) {
    let bad = string.replace(good, swap.0, swap.1)
    assert bad != good
    assert profile.parse_local(bad) == Error(Nil)
  })
  assert profile.parse_local("[]") == Error(Nil)
}

pub fn worker_profile_round_trips_test() {
  let assert Ok(slot) =
    profile.new_worker("https://gantry.example", "linux", token, "/s/journal")
  let text = json.to_string(profile.encode_worker(slot))
  assert profile.parse_worker(text) == Ok(slot)
  assert string.starts_with(profile.worker_id(slot), "worker-")
  assert profile.new_worker("https://g", "..", token, "/j") == Error(Nil)
  assert profile.new_worker("https://g", "linux", "short", "/j") == Error(Nil)
}

pub fn credential_rule_test() {
  assert profile.credential(token)
  assert !profile.credential(string.drop_end(token, 1))
  assert !profile.credential(token <> " ")
  assert !profile.credential(token <> "é")
  assert profile.credential(string.repeat("!~", 16))
}

pub fn save_publishes_a_private_file_test() {
  let directory = "build/onboarding-save-test"
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(Nil) = profile.save(directory, "profile.json", "one")
  let assert Ok(Nil) = profile.save(directory, "profile.json", "two")
  assert simplifile.read(directory <> "/profile.json") == Ok("two")
  let assert Ok(info) = simplifile.file_info(directory <> "/profile.json")
  assert info.mode % 0o1000 == 0o600

  // No staged copy is left beside the published file.
  assert simplifile.read_directory(directory) == Ok(["profile.json"])
  let _ = simplifile.delete(directory)
}

pub fn authority_parser_test() {
  assert origin.parse_authority("127.0.0.1:4737") == Ok(Some(4737))
  assert origin.parse_authority("gantry.example") == Ok(None)
  assert origin.parse_authority("[::1]:99999") == Ok(Some(99_999))
  assert origin.parse_authority("[::1]") == Ok(None)
  list.each(
    ["", ":80", "user@host", "host:", "host:+80", "host:123456", "[]", "[zz]"],
    fn(authority) {
      assert origin.parse_authority(authority) == Error(Nil)
    },
  )
}

pub fn remote_origin_rules_test() {
  assert onboarding.remote_origin("https://gantry.example") == Ok(Nil)
  assert onboarding.remote_origin("https://[fd00::1]:8443") == Ok(Nil)
  list.each(
    [
      "http://gantry.example", "https://gantry.example/path",
      "https://user@gantry.example", "https://gantry.example?x=1",
      "https://gantry.example:0", "https://gantry.example:65536",
    ],
    fn(endpoint) {
      let assert Error(failure.Failure(exit: failure.Invalid, ..)) =
        onboarding.remote_origin(endpoint)
      Nil
    },
  )
}

pub fn an_empty_worker_token_mints_a_fresh_credential_test() {
  let assert Ok(first) =
    profile.new_worker("https://gantry.example", "linux", "", "/s/journal")
  let assert Ok(second) =
    profile.new_worker("https://gantry.example", "linux", "", "/s/journal")
  assert profile.credential(profile.worker_token(first))
  assert profile.worker_token(first) != profile.worker_token(second)
  assert profile.worker_id(first) != profile.worker_id(second)
}

pub fn the_local_controller_config_registers_its_worker_test() {
  let local = profile.new_local("/state/gantry/local", 4737)
  let text = onboarding.controller_config("/state/gantry/local", local)
  let secrets =
    config.Secrets(
      agent: profile.agent_token(local),
      submit: profile.submit_token(local),
      github: "",
    )

  // The controller accepts the generated file and authenticates the
  // profile's own worker token as the profile's worker ID.
  let assert Ok(cfg) = config.parse(text, secrets)
  assert config.worker_for(cfg, profile.local_worker_token(local))
    == Ok(profile.local_worker_id(local))
  assert config.worker_for(cfg, profile.agent_token(local)) == Error(Nil)

  // The token itself is never written to the file.
  assert !string.contains(text, profile.local_worker_token(local))
}

pub fn ipv6_request_keeps_its_brackets_test() {
  // `request.to` drops the brackets, and httpc cannot send to a bare `::1`.
  let assert Ok(outgoing) = origin.request("http://[::1]:4737/ready")
  assert outgoing.host == "[::1]"
  assert outgoing.port == option.Some(4737)
  let assert Ok(named) =
    origin.request("https://gantry.example/v1/worker/ready")
  assert named.host == "gantry.example"
}
