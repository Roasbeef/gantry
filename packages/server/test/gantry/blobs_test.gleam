import gantry/blobs
import gantry/fault
import gleam/bit_array
import gleam/crypto
import gleam/string
import simplifile

fn root() -> String {
  let suffix = crypto.strong_random_bytes(8) |> bit_array.base16_encode
  let path = "/tmp/gantry-blobs-test-" <> suffix
  let assert Ok(Nil) = simplifile.create_directory_all(path)
  path
}

pub fn a_published_object_is_present_without_being_read_test() {
  let directory = root()
  let assert Ok(id) = blobs.put(directory, <<"artifact":utf8>>)
  assert blobs.require(directory, id) == Ok(Nil)
  let _ = simplifile.delete(directory)
}

pub fn a_missing_object_is_not_found_test() {
  let directory = root()
  let id = blobs.digest(<<"absent":utf8>>)
  assert blobs.require(directory, id)
    == Error(fault.NotFound("blob unavailable"))
  let _ = simplifile.delete(directory)
}

pub fn a_malformed_digest_is_invalid_test() {
  let directory = root()
  let assert Error(fault.Invalid(_)) = blobs.require(directory, "../escape")
  let _ = simplifile.delete(directory)
}

pub fn a_directory_in_place_of_an_object_is_corrupt_test() {
  let directory = root()
  let id = blobs.digest(<<"directory":utf8>>)
  let assert Ok(Nil) =
    simplifile.create_directory_all(directory <> "/objects/" <> id)
  let assert Error(fault.Internal(_)) = blobs.require(directory, id)
  let _ = simplifile.delete(directory)
}

pub fn hex_check_accepts_only_lowercase_digits_test() {
  assert blobs.lower_hex("00af09")
  assert !blobs.lower_hex("00AF09")
  assert !blobs.lower_hex("xyz")
  assert blobs.valid(string.repeat("a", 64))
  assert !blobs.valid(string.repeat("a", 63))
}
