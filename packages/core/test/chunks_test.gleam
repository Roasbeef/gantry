//// Chunk manifests refuse every malformed shape, and the planner covers its
//// total exactly. Recipe identities move only with the metadata an action
//// declares.

import gantry_core/chunks
import gantry_core/graph
import gantry_core/sandbox
import gleam/int
import gleam/list
import gleam/string
import qcheck

const a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

fn sample() -> chunks.Manifest {
  let assert Ok(value) =
    chunks.manifest(a, [chunks.Chunk(a, 10), chunks.Chunk(b, 5)])
  value
}

pub fn round_trip_test() {
  let value = sample()
  assert chunks.decode(chunks.encode(value)) == Ok(value)
  assert chunks.total(value) == 15
}

pub fn manifest_refuses_bad_shapes_test() {
  let bad_digest = "ABC"
  let too_many = list.repeat(chunks.Chunk(a, 1), chunks.max_chunks + 1)
  let oversized = list.repeat(chunks.Chunk(a, chunks.chunk_limit), 17)
  list.each(
    [
      chunks.manifest(a, []),
      chunks.manifest(bad_digest, [chunks.Chunk(a, 1)]),
      chunks.manifest(a, [chunks.Chunk(bad_digest, 1)]),
      chunks.manifest(a, [chunks.Chunk(a, 0)]),
      chunks.manifest(a, [chunks.Chunk(a, -1)]),
      chunks.manifest(a, [chunks.Chunk(a, chunks.chunk_limit + 1)]),
      chunks.manifest(a, too_many),
      chunks.manifest(a, oversized),
    ],
    fn(outcome) {
      let assert Error(chunks.InvalidManifest(_)) = outcome
      Nil
    },
  )
}

pub fn decode_refuses_damage_test() {
  let good = chunks.encode(sample())
  list.each(
    [
      "",
      "{}",
      "[]",
      string.replace(good, "\"version\":1", "\"version\":2"),
      string.replace(good, "\"total\":15", "\"total\":16"),
      string.replace(good, "\"length\":10", "\"length\":0"),
      string.replace(good, a, "xyz"),
    ],
    fn(text) {
      let assert Error(chunks.InvalidManifest(_)) = chunks.decode(text)
      Nil
    },
  )
}

pub fn check_chunk_test() {
  let value = sample()
  assert chunks.check_chunk(value, 0, 10, a) == Ok(Nil)
  assert chunks.check_chunk(value, 1, 5, b) == Ok(Nil)
  assert chunks.check_chunk(value, 0, 9, a) == Error(chunks.ChunkLength(0))
  assert chunks.check_chunk(value, 1, 5, a) == Error(chunks.ChunkDigest(1))
  assert chunks.check_chunk(value, 2, 5, a) == Error(chunks.NoChunk(2))
  assert chunks.check_chunk(value, -1, 5, a) == Error(chunks.NoChunk(-1))
  assert chunks.check_total(value, a) == Ok(Nil)
  assert chunks.check_total(value, b) == Error(chunks.TotalDigest)
}

pub fn plan_covers_total_exactly_test() {
  qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(200),
    qcheck.bounded_int(from: 1, to: chunks.input_limit),
    fn(total) {
      let assert Ok(lengths) = chunks.plan(total)
      assert list.fold(lengths, 0, int.add) == total
      assert list.all(lengths, fn(n) { n >= 1 && n <= chunks.chunk_limit })
      assert list.length(lengths) <= chunks.max_chunks
    },
  )
  assert chunks.plan(0)
    == Error(chunks.InvalidManifest("total is outside the input limit"))
  let assert Error(_) = chunks.plan(chunks.input_limit + 1)
}

fn action(git: graph.Metadata) -> graph.Action {
  graph.Action(..graph.action("c", ["make"], ["."], [], [], [], 60), git: git)
}

fn id(git: graph.Metadata, source: String, commit: String) -> String {
  graph.identity(
    "declared",
    "o/r",
    "linux",
    "img",
    source,
    action(git),
    sandbox.Strict,
    commit,
  )
}

pub fn identity_without_git_ignores_the_commit_test() {
  assert id(graph.NoGit, a, "c1") == id(graph.NoGit, a, "c2")
  assert id(graph.NoGit, a, "c1") != id(graph.NoGit, b, "c1")
}

pub fn identity_without_git_is_the_legacy_array_test() {
  assert id(graph.NoGit, a, "c1")
    == "[\"gantry-action-v1\",\"declared\",\"o/r\",\"linux\",\"img\",\""
    <> a
    <> "\",{\"name\":\"c\",\"argv\":[\"make\"],\"inputs\":[\".\"],\"outputs\":[],\"deps\":[],\"after\":[],\"timeout\":60}]"
}

pub fn identity_with_shallow_tracks_the_commit_test() {
  assert id(graph.Shallow, a, "c1") == id(graph.Shallow, a, "c1")
  assert id(graph.Shallow, a, "c1") != id(graph.Shallow, a, "c2")
  assert id(graph.Shallow, a, "c1") != id(graph.NoGit, a, "c1")
}

pub fn identity_names_a_wider_profile_before_the_commit_test() {
  let profiled = fn(git, profile) {
    graph.identity(
      "declared",
      "o/r",
      "linux",
      "img",
      a,
      action(git),
      profile,
      "c1",
    )
  }
  let strict = id(graph.NoGit, a, "c1")

  // A userns key is the strict array with the profile's name appended, as
  // keys were hashed before metadata existed, so those proofs stay valid.
  assert profiled(graph.NoGit, sandbox.Userns)
    == string.drop_end(strict, 1) <> ",\"userns\"]"

  // Metadata follows the profile, so each part moves the key on its own.
  let shallow = profiled(graph.Shallow, sandbox.Strict)
  assert string.ends_with(shallow, ",\"git-shallow-v1\",\"c1\"]")
  assert profiled(graph.Shallow, sandbox.Userns)
    == string.replace(
      shallow,
      ",\"git-shallow-v1\"",
      ",\"userns\",\"git-shallow-v1\"",
    )
}

pub fn git_key_decodes_totally_test() {
  let body = fn(git) {
    "{\"name\":\"a\",\"argv\":[\"x\"],\"git\":" <> git <> "}"
  }
  let decoded = fn(git) { gleam_json_parse(body(git)) }
  assert decoded("\"shallow\"") == Ok(graph.Shallow)
  assert decoded("\"none\"") == Ok(graph.NoGit)
  assert decoded("\"deep\"") == Error(Nil)
  assert decoded("true") == Error(Nil)
}

fn gleam_json_parse(text: String) -> Result(graph.Metadata, Nil) {
  case
    graph.compile(
      "{\"actions\":[" <> text <> "],\"targets\":{\"t\":[\"a\"]}}",
      "t",
    )
  {
    Ok([action]) -> Ok(action.git)
    _ -> Error(Nil)
  }
}
