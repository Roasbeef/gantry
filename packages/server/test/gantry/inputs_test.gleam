//// Chunked inputs are published as blobs plus a manifest, and the worker
//// refuses each way those can disagree: a bad manifest, a chunk with the
//// wrong length or digest, a missing chunk, and a reassembled digest that
//// differs from the manifest's.

import gantry/blobs
import gantry/worker/controllers
import gantry/worker/docker
import gantry/worker/inputs
import gantry_core/chunks
import gantry_core/queue
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/result
import gleam/string
import simplifile

fn root() -> String {
  let suffix = crypto.strong_random_bytes(8) |> bit_array.base16_encode
  let path = "/tmp/gantry-inputs-test-" <> suffix
  let assert Ok(Nil) = simplifile.create_directory_all(path)
  path
}

/// A fetch that reads a controller's published objects the way the HTTP
/// route does, verifying the address.
fn fetch_from(directory: String) -> inputs.Fetch {
  fn(digest) {
    blobs.get(directory, digest)
    |> result.map_error(fn(_) { controllers.Offline("blob unavailable") })
  }
}

fn pattern(size: Int) -> BitArray {
  let repeated = string.repeat("0123456789abcdef", size / 16 + 1)
  let assert Ok(bytes) =
    bit_array.slice(bit_array.from_string(repeated), 0, size)
  bytes
}

/// Publish chunks of the given sizes by hand, so a test can damage them.
fn publish(
  directory: String,
  parts: List(BitArray),
) -> #(chunks.Manifest, String) {
  let all = bit_array.concat(parts)
  let listed =
    list.map(parts, fn(part) {
      let assert Ok(id) = blobs.put(directory, part)
      chunks.Chunk(id, bit_array.byte_size(part))
    })
  let assert Ok(manifest) = chunks.manifest(blobs.digest(all), listed)
  let assert Ok(id) = blobs.put(directory, <<chunks.encode(manifest):utf8>>)
  #(manifest, id)
}

fn staged(
  fetch: inputs.Fetch,
  input: queue.Input,
) -> #(Result(Nil, controllers.Fault), Bool) {
  let path = root() <> "/source.tar"
  let outcome = inputs.stage(fetch, input, path)
  let present = simplifile.is_file(path) == Ok(True)
  #(outcome, present)
}

pub fn a_small_input_stays_one_blob_test() {
  let directory = root()
  let bytes = pattern(1000)
  let assert Ok(input) = blobs.put_input(directory, bytes)
  assert input == queue.Whole(blobs.digest(bytes))
  let path = root() <> "/out"
  assert inputs.stage(fetch_from(directory), input, path) == Ok(Nil)
  assert simplifile.read_bits(path) == Ok(bytes)
}

pub fn an_input_over_one_blob_is_chunked_and_reassembles_test() {
  let directory = root()
  let size = blobs.limit + 1_000_000
  let bytes = pattern(size)
  let assert Ok(queue.Chunked(manifest_id)) = blobs.put_input(directory, bytes)
  let assert Ok(manifest_bytes) = blobs.get(directory, manifest_id)
  let assert Ok(text) = bit_array.to_string(manifest_bytes)
  let assert Ok(manifest) = chunks.decode(text)
  assert chunks.total(manifest) == size
  assert list.length(chunks.chunks(manifest)) == 3
  assert chunks.digest(manifest) == blobs.digest(bytes)

  let path = root() <> "/out"
  assert inputs.stage(fetch_from(directory), queue.Chunked(manifest_id), path)
    == Ok(Nil)
  let assert Ok(back) = simplifile.read_bits(path)
  assert blobs.digest(back) == blobs.digest(bytes)
}

pub fn a_chunk_with_the_wrong_length_is_refused_test() {
  let directory = root()
  let #(_, id) = publish(directory, [pattern(10), pattern(5)])
  // Serve a shorter chunk under the first chunk's address.
  let fetch = fn(digest) {
    case digest == blobs.digest(pattern(10)) {
      True -> Ok(pattern(9))
      False -> fetch_from(directory)(digest)
    }
  }
  let #(outcome, present) = staged(fetch, queue.Chunked(id))
  assert outcome
    == Error(controllers.Invalid("input chunk 0 has the wrong length"))
  assert !present
}

pub fn a_chunk_that_fails_its_digest_is_refused_test() {
  let directory = root()
  let #(_, id) = publish(directory, [pattern(10), pattern(5)])
  // Serve other bytes of the right length under the second chunk's address.
  let fetch = fn(digest) {
    case digest == blobs.digest(pattern(5)) {
      True -> Ok(<<"zzzzz":utf8>>)
      False -> fetch_from(directory)(digest)
    }
  }
  let #(outcome, present) = staged(fetch, queue.Chunked(id))
  assert outcome
    == Error(controllers.Invalid("input chunk 1 failed SHA-256 verification"))
  assert !present
}

pub fn a_missing_chunk_is_offline_not_invalid_test() {
  let directory = root()
  let #(manifest, id) = publish(directory, [pattern(10), pattern(5)])
  let assert [_, second] = chunks.chunks(manifest)
  let assert Ok(Nil) =
    simplifile.delete(directory <> "/objects/" <> second.digest)
  let #(outcome, present) = staged(fetch_from(directory), queue.Chunked(id))
  assert outcome == Error(controllers.Offline("blob unavailable"))
  assert !present
}

pub fn a_reassembled_digest_mismatch_is_refused_test() {
  let directory = root()
  let parts = [pattern(10), pattern(5)]
  let listed =
    list.map(parts, fn(part) {
      let assert Ok(id) = blobs.put(directory, part)
      chunks.Chunk(id, bit_array.byte_size(part))
    })
  // Every chunk is sound, but the manifest names another whole digest.
  let assert Ok(manifest) =
    chunks.manifest(blobs.digest(<<"something else":utf8>>), listed)
  let assert Ok(id) = blobs.put(directory, <<chunks.encode(manifest):utf8>>)
  let #(outcome, present) = staged(fetch_from(directory), queue.Chunked(id))
  assert outcome
    == Error(controllers.Invalid(
      "reassembled input failed SHA-256 verification",
    ))
  assert !present
}

pub fn a_malformed_manifest_is_refused_test() {
  let directory = root()
  let assert Ok(id) = blobs.put(directory, <<"{\"version\":1}":utf8>>)
  let #(outcome, present) = staged(fetch_from(directory), queue.Chunked(id))
  assert outcome
    == Error(controllers.Invalid("invalid chunk manifest: not a manifest"))
  assert !present
  let assert Ok(binary) = blobs.put(directory, <<255, 254>>)
  let #(outcome, _) = staged(fetch_from(directory), queue.Chunked(binary))
  assert outcome
    == Error(controllers.Invalid("invalid chunk manifest: not text"))
}

pub fn an_unlisted_blob_is_never_asked_for_test() {
  // Only digests the manifest lists, and the manifest itself, are fetched.
  let directory = root()
  let #(manifest, id) = publish(directory, [pattern(10), pattern(5)])
  let allowed = [
    id,
    ..list.map(chunks.chunks(manifest), fn(chunk) { chunk.digest })
  ]
  let fetch = fn(digest) {
    assert list.contains(allowed, digest)
    fetch_from(directory)(digest)
  }
  assert staged(fetch, queue.Chunked(id)).0 == Ok(Nil)
}

pub fn an_interrupted_attempt_leaves_no_partial_staging_test() {
  let directory = root()
  let name = "attempt-1"
  let staging = directory <> "/" <> name <> ".staging"
  let assert Ok(Nil) = simplifile.create_directory(staging)

  // A worker stopped mid-transfer leaves part of a chunked source and a
  // whole metadata archive in the attempt's staging directory.
  let assert Ok(Nil) =
    simplifile.write_bits(staging <> "/source.tar", pattern(chunks.chunk_limit))
  let assert Ok(Nil) = simplifile.write_bits(staging <> "/git.tar", pattern(64))

  // The cleanup an interrupted attempt runs before it is recorded removes
  // both, and a second cleanup after a restart finds nothing to remove.
  let assert Ok(Nil) = docker.unstage(directory, name)
  assert simplifile.is_directory(staging) == Ok(False)
  let assert Ok(Nil) = docker.unstage(directory, name)
  let assert Ok(Nil) = simplifile.delete(directory)
}
