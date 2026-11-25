//// Source archives, logs and outputs are immutable content-addressed bytes.
//// Queue transitions reference objects after their atomic publication.
////
//// `put` stages the bytes under a random name, flushes the file and each
//// directory above it with `sync`, and renames the file into place, so a
//// reader sees the whole object or none of it.

import gantry/fault.{type Fault}
import gantry/internal/ffi_host
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Largest single object transferred through the first worker protocol.
pub const limit = 67_108_864

/// Compute the lowercase SHA-256 identity used over the wire.
///
/// ## Examples
///
/// ```gleam
/// // blobs.digest(<<"artifact">>)
/// ```
pub fn digest(bytes: BitArray) -> String {
  crypto.hash(crypto.Sha256, bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Check a digest before it crosses the filesystem boundary.
///
/// ## Examples
///
/// ```gleam
/// blobs.valid("not-a-digest") == False
/// ```
pub fn valid(value: String) -> Bool {
  string.byte_size(value) == 64 && lower_hex(value)
}

/// Whether every character is a lowercase hexadecimal digit. This is the
/// controller's one hex check, shared by digests and Git object IDs.
///
/// ## Examples
///
/// ```gleam
/// assert blobs.lower_hex("00ff")
/// assert !blobs.lower_hex("00FF")
/// ```
pub fn lower_hex(value: String) -> Bool {
  list.all(string.to_utf_codepoints(value), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    { n >= 48 && n <= 57 } || { n >= 97 && n <= 102 }
  })
}

/// Sixteen random bytes as lowercase hex, for staged file names that must
/// not collide between concurrent writers.
///
/// ## Examples
///
/// ```gleam
/// // blobs.unique_suffix() -> "4f9c1a2b7d3e5a604f9c1a2b7d3e5a60"
/// ```
pub fn unique_suffix() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Atomically publish bytes at their immutable object path.
///
/// ## Examples
///
/// ```gleam
/// // blobs.put(shared_root, <<"artifact">>)
/// ```
pub fn put(root: String, bytes: BitArray) -> Result(String, Fault) {
  use Nil <- result.try(check_size(bytes))
  let id = digest(bytes)
  let directory = root <> "/objects"
  let path = directory <> "/" <> id

  use Nil <- result.try(
    simplifile.create_directory_all(directory)
    |> result.replace_error(fault.Unavailable("cannot open blob directory")),
  )
  let temporary = directory <> "/.upload-" <> unique_suffix()
  use Nil <- result.try(
    simplifile.write_bits(bytes, to: temporary)
    |> result.replace_error(fault.Unavailable("cannot stage blob")),
  )

  // Concurrent writers publish identical bytes at the same destination.
  let published = {
    use Nil <- result.try(sync(temporary))
    use Nil <- result.try(
      simplifile.rename(temporary, path)
      |> result.replace_error(fault.Unavailable("cannot publish blob")),
    )
    use Nil <- result.try(sync(directory))
    sync(root) |> result.map(fn(_) { id })
  }
  let _ = simplifile.delete_file(temporary)
  published
}

/// Fetch and verify one immutable object.
///
/// ## Examples
///
/// ```gleam
/// // blobs.get(shared_root, id)
/// ```
pub fn get(root: String, id: String) -> Result(BitArray, Fault) {
  use Nil <- result.try(check_digest(id))
  use bytes <- result.try(
    simplifile.read_bits(root <> "/objects/" <> id)
    |> result.replace_error(fault.NotFound("blob unavailable")),
  )
  use Nil <- result.try(check_size(bytes))

  // Return the object only if its bytes still match its address.
  case digest(bytes) == id {
    True -> Ok(bytes)
    False -> Error(fault.Internal("stored blob failed digest verification"))
  }
}

/// Confirm that a published object exists with a plausible size, without
/// reading it. Objects are written once under their digest, so the upload
/// check already established their content.
///
/// ## Examples
///
/// ```gleam
/// // blobs.require(shared_root, id)
/// ```
pub fn require(root: String, id: String) -> Result(Nil, Fault) {
  use Nil <- result.try(check_digest(id))

  // A missing path and a damaged one are different failures. Only a regular
  // file within the limit can be a published object.
  case simplifile.file_info(root <> "/objects/" <> id) {
    Ok(info) ->
      case simplifile.file_info_type(info), info.size <= limit {
        simplifile.File, True -> Ok(Nil)
        _, _ -> Error(fault.Internal("stored blob is not a regular object"))
      }
    Error(simplifile.Enoent) -> Error(fault.NotFound("blob unavailable"))
    Error(_) -> Error(fault.Unavailable("cannot inspect blob"))
  }
}

fn check_digest(id: String) -> Result(Nil, Fault) {
  case valid(id) {
    True -> Ok(Nil)
    False -> Error(fault.Invalid("invalid SHA-256 digest"))
  }
}

fn check_size(bytes: BitArray) -> Result(Nil, Fault) {
  case bit_array.byte_size(bytes) <= limit {
    True -> Ok(Nil)
    False -> Error(fault.Invalid("blob exceeds 64 MiB"))
  }
}

/// Flush a published path, treating a failure as a retryable storage fault.
fn sync(path: String) -> Result(Nil, Fault) {
  ffi_host.sync_path(path) |> result.map_error(fault.Unavailable)
}
