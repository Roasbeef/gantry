//// An input archive larger than one blob is stored as ordered byte ranges,
//// each its own blob, plus a manifest that names them. The manifest is the
//// only thing a task points at, and it carries everything a worker must
//// check: the length and SHA-256 of every chunk, and the SHA-256 of the
//// reassembled bytes.
////
//// A `Manifest` can be built only by `manifest` or `decode`, and both refuse
//// the shapes below, so a value in hand is valid.
////
//// | Rule | Why |
//// | --- | --- |
//// | at least one chunk, at most `max_chunks` | an empty or unbounded list stages nothing or everything |
//// | each length is in `1..chunk_limit` | a chunk is one ordinary blob, within the blob limit |
//// | `total` is the sum of the lengths and at most `input_limit` | the worker's disk budget |
//// | every digest is 64 lowercase hex characters | a digest becomes a path component |
////
//// `check_chunk` is the per-chunk test the worker applies as bytes arrive.
//// The whole-archive digest cannot be checked until the last chunk, so the
//// worker hashes incrementally and compares it with `check_total` at the end.
////
//// ## Flow
////
//// `plan` sizes the chunks of an archive, `manifest` validates their digests,
//// `encode` and `decode` carry the manifest between the controller and the
//// worker, and `check_chunk` and `check_total` test what arrives. `split` is
//// the arithmetic under `plan`, and `chunk_decoder` reads one chunk entry.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// The largest chunk. It is half the blob limit, so a chunk always fits one
/// blob with room to spare.
pub const chunk_limit = 33_554_432

/// The largest reassembled archive a worker will stage.
pub const input_limit = 536_870_912

/// The most chunks a manifest may list.
pub const max_chunks = 16

/// One byte range of the archive.
pub type Chunk {
  Chunk(digest: String, length: Int)
}

/// An ordered, validated list of chunks and the digest of their concatenation.
pub opaque type Manifest {
  Manifest(digest: String, chunks: List(Chunk))
}

/// Why a manifest or a received chunk was refused.
pub type Violation {
  /// The manifest breaks a shape rule or does not parse.
  InvalidManifest(detail: String)

  /// Chunk `index` (from zero) has a different length than listed.
  ChunkLength(index: Int)

  /// Chunk `index` (from zero) has a different SHA-256 than listed.
  ChunkDigest(index: Int)

  /// There is no chunk at `index`.
  NoChunk(index: Int)

  /// The reassembled bytes do not match the manifest digest.
  TotalDigest
}

/// Spell a violation for a rejection log.
///
/// ## Examples
///
/// ```gleam
/// assert chunks.describe(chunks.ChunkDigest(2)) == "input chunk 2 failed SHA-256 verification"
/// ```
pub fn describe(violation: Violation) -> String {
  case violation {
    InvalidManifest(detail) -> "invalid chunk manifest: " <> detail
    ChunkLength(index) ->
      "input chunk " <> int.to_string(index) <> " has the wrong length"
    ChunkDigest(index) ->
      "input chunk " <> int.to_string(index) <> " failed SHA-256 verification"
    NoChunk(index) -> "input chunk " <> int.to_string(index) <> " is not listed"
    TotalDigest -> "reassembled input failed SHA-256 verification"
  }
}

/// Split `total` bytes into chunk lengths: full chunks, then the remainder.
///
/// ## Examples
///
/// ```gleam
/// assert chunks.plan(chunks.chunk_limit + 1) == Ok([chunks.chunk_limit, 1])
/// ```
pub fn plan(total: Int) -> Result(List(Int), Violation) {
  // A total outside the limits has no valid split.
  case total >= 1 && total <= input_limit {
    True -> Ok(split(total, []))
    False -> Error(InvalidManifest("total is outside the input limit"))
  }
}

/// Peel full chunks off `remaining`, then end with the remainder.
fn split(remaining: Int, acc: List(Int)) -> List(Int) {
  // Anything above one chunk yields a full chunk and recurses.
  case remaining > chunk_limit {
    True -> split(remaining - chunk_limit, [chunk_limit, ..acc])
    False -> list.reverse([remaining, ..acc])
  }
}

/// Build a manifest from the whole-archive digest and its chunks.
///
/// ## Examples
///
/// ```gleam
/// // chunks.manifest(digest, [chunks.Chunk(first, 10)])
/// ```
pub fn manifest(
  digest: String,
  chunks: List(Chunk),
) -> Result(Manifest, Violation) {
  let count = list.length(chunks)
  let total = list.fold(chunks, 0, fn(sum, chunk) { sum + chunk.length })
  let sound =
    valid_digest(digest)
    && count >= 1
    && count <= max_chunks
    && total <= input_limit
    && list.all(chunks, fn(chunk) {
      valid_digest(chunk.digest)
      && chunk.length >= 1
      && chunk.length <= chunk_limit
    })

  // One failed rule refuses the whole manifest.
  case sound {
    True -> Ok(Manifest(digest, chunks))
    False -> Error(InvalidManifest("a chunk, digest or count is out of range"))
  }
}

/// The digest of the reassembled archive.
pub fn digest(value: Manifest) -> String {
  value.digest
}

/// The chunks in archive order.
pub fn chunks(value: Manifest) -> List(Chunk) {
  value.chunks
}

/// The reassembled archive's length.
pub fn total(value: Manifest) -> Int {
  list.fold(value.chunks, 0, fn(sum, chunk) { sum + chunk.length })
}

/// Test chunk `index` against the length and digest that were listed.
///
/// ## Examples
///
/// ```gleam
/// // chunks.check_chunk(manifest, 0, byte_size, sha256)
/// ```
pub fn check_chunk(
  value: Manifest,
  index: Int,
  length: Int,
  digest: String,
) -> Result(Nil, Violation) {
  case list.drop(value.chunks, index) {
    [listed, ..] if index >= 0 ->
      case listed.length == length, listed.digest == digest {
        False, _ -> Error(ChunkLength(index))
        True, False -> Error(ChunkDigest(index))
        True, True -> Ok(Nil)
      }
    _ -> Error(NoChunk(index))
  }
}

/// Test the digest of the reassembled bytes.
///
/// ## Examples
///
/// ```gleam
/// // chunks.check_total(manifest, sha256_of_all)
/// ```
pub fn check_total(value: Manifest, digest: String) -> Result(Nil, Violation) {
  case value.digest == digest {
    True -> Ok(Nil)
    False -> Error(TotalDigest)
  }
}

/// Encode a manifest. The output is the same bytes for the same manifest, so
/// its blob digest names the archive.
///
/// ## Examples
///
/// ```gleam
/// // chunks.encode(manifest) |> bit_array.from_string
/// ```
pub fn encode(value: Manifest) -> String {
  json.object([
    #("version", json.int(1)),
    #("total", json.int(total(value))),
    #("digest", json.string(value.digest)),
    #(
      "chunks",
      json.array(value.chunks, fn(chunk) {
        json.object([
          #("digest", json.string(chunk.digest)),
          #("length", json.int(chunk.length)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

/// Decode and validate a manifest. A `total` that disagrees with the chunk
/// lengths is refused.
///
/// ## Examples
///
/// ```gleam
/// assert chunks.decode("{}") != Ok(_)
/// ```
pub fn decode(text: String) -> Result(Manifest, Violation) {
  let decoder = {
    use version <- decode.field("version", decode.int)
    use claimed <- decode.field("total", decode.int)
    use digest <- decode.field("digest", decode.string)
    use listed <- decode.field("chunks", decode.list(chunk_decoder()))
    decode.success(#(version, claimed, digest, listed))
  }

  use #(version, claimed, digest, listed) <- result.try(
    json.parse(text, decoder)
    |> result.replace_error(InvalidManifest("not a manifest")),
  )

  // Only version 1 exists, and a manifest written for another is refused.
  use Nil <- result.try(case version {
    1 -> Ok(Nil)
    _ -> Error(InvalidManifest("unknown version"))
  })

  use value <- result.try(manifest(digest, listed))

  // The stated total must equal the sum the chunks add up to.
  case claimed == total(value) {
    True -> Ok(value)
    False -> Error(InvalidManifest("total is not the sum"))
  }
}

/// Decode one chunk entry of a manifest.
fn chunk_decoder() -> decode.Decoder(Chunk) {
  use digest <- decode.field("digest", decode.string)
  use length <- decode.field("length", decode.int)
  decode.success(Chunk(digest, length))
}

/// Whether a string is a 64-character lowercase hexadecimal SHA-256.
fn valid_digest(value: String) -> Bool {
  string.byte_size(value) == 64
  && list.all(string.to_utf_codepoints(value), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    { n >= 48 && n <= 57 } || { n >= 97 && n <= 102 }
  })
}
