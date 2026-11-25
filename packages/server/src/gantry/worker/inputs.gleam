//// Stage one input archive on the worker, whole or chunked, onto disk.
////
//// ## Flow
////
//// `stage` takes a `queue.Input` and a destination path. A `Whole` input goes
//// through `stage_whole`, one blob verified by its address. A `Chunked`
//// input goes through `stage_chunks`: the manifest blob first, then each
//// listed chunk in order, appended to the file by `append`. The first
//// refusal deletes the partial file and ends the stage:
////
//// | Outcome | Fault |
//// | --- | --- |
//// | controller unreachable or a blob missing | `Offline`, retried by the lease |
//// | manifest shape, chunk length or digest, or reassembled digest wrong | `Invalid`, the action is rejected |
////
//// Memory holds one chunk at a time, and the whole-archive digest is
//// computed as the chunks are appended.

import gantry/worker/controllers.{Invalid, Offline}
import gantry_core/chunks
import gantry_core/queue
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Fetch a blob by digest, verified against that digest. The worker passes
/// `controllers.fetch`, and a test passes a map lookup.
pub type Fetch =
  fn(String) -> Result(BitArray, controllers.Fault)

/// Write the input's reassembled bytes to `path`, replacing any file there.
///
/// ## Examples
///
/// ```gleam
/// // inputs.stage(fetch, queue.Chunked(manifest_digest), "/w/source.tar")
/// ```
pub fn stage(
  fetch: Fetch,
  input: queue.Input,
  path: String,
) -> Result(Nil, controllers.Fault) {
  // The layout decides whether the digest names the archive or its manifest.
  let staged = case input {
    queue.Whole(digest) -> stage_whole(fetch, digest, path)
    queue.Chunked(manifest) -> stage_chunks(fetch, manifest, path)
  }

  // A refused input leaves no partial archive behind for a later mount.
  case staged {
    Ok(Nil) -> Ok(Nil)
    Error(fault) -> {
      let _ = simplifile.delete_file(path)
      Error(fault)
    }
  }
}

/// Fetch the one blob that is the archive and write it.
fn stage_whole(
  fetch: Fetch,
  digest: String,
  path: String,
) -> Result(Nil, controllers.Fault) {
  use bytes <- result.try(fetch(digest))
  simplifile.write_bits(path, bytes)
  |> result.replace_error(Offline("could not write input archive"))
}

/// Fetch the manifest, then every chunk it lists, and check the length of each
/// chunk and the digest of the whole.
fn stage_chunks(
  fetch: Fetch,
  manifest_digest: String,
  path: String,
) -> Result(Nil, controllers.Fault) {
  use text <- result.try(fetch(manifest_digest))
  use text <- result.try(
    bit_array.to_string(text)
    |> result.replace_error(Invalid("invalid chunk manifest: not text")),
  )
  use manifest <- result.try(
    chunks.decode(text)
    |> result.map_error(fn(violation) { Invalid(chunks.describe(violation)) }),
  )
  use Nil <- result.try(
    simplifile.write_bits(path, <<>>)
    |> result.replace_error(Offline("could not write input archive")),
  )

  // Hash the reassembled bytes as they are appended.
  use hasher <- result.try(
    list.index_fold(
      chunks.chunks(manifest),
      Ok(crypto.new_hasher(crypto.Sha256)),
      fn(state, listed, index) {
        use hasher <- result.try(state)

        // The fetch checked the chunk against its address, which is the
        // digest the manifest lists. The manifest rule checks its length.
        use bytes <- result.try(fetch(listed.digest))
        use Nil <- result.try(
          chunks.check_chunk(
            manifest,
            index,
            bit_array.byte_size(bytes),
            listed.digest,
          )
          |> result.map_error(fn(violation) {
            Invalid(chunks.describe(violation))
          }),
        )
        use Nil <- result.try(append(path, bytes))
        Ok(crypto.hash_chunk(hasher, bytes))
      },
    ),
  )

  let total =
    crypto.digest(hasher) |> bit_array.base16_encode |> string.lowercase
  chunks.check_total(manifest, total)
  |> result.map_error(fn(violation) { Invalid(chunks.describe(violation)) })
}

/// Add one verified chunk to the end of the staged archive.
fn append(path: String, bytes: BitArray) -> Result(Nil, controllers.Fault) {
  simplifile.append_bits(path, bytes)
  |> result.replace_error(Offline("could not append input chunk"))
}
