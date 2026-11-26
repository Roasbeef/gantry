//// The worker's blob cache serves a verified entry without the controller,
//// repairs a damaged one, and evicts the oldest files to stay in bounds.

import gantry/blobs
import gantry/worker/cache
import gantry/worker/controllers
import gantry/worker/docker
import gantry/worker/inputs
import gleam/list
import simplifile
import worker_fixture

/// A controller that serves `bytes` under their digest.
fn serving(bytes: BitArray) -> inputs.Fetch {
  let digest = blobs.digest(bytes)
  fn(asked) {
    case asked == digest {
      True -> Ok(bytes)
      False -> Error(controllers.Offline("blob unavailable"))
    }
  }
}

/// A controller that is unreachable, so only the cache can answer.
fn offline(_digest: String) -> Result(BitArray, controllers.Fault) {
  Error(controllers.Offline("controller unreachable"))
}

pub fn a_fetched_blob_is_served_without_the_controller_test() {
  let directory = worker_fixture.temp_directory()
  let bytes = <<"chunk bytes":utf8>>
  let digest = blobs.digest(bytes)

  assert cache.wrap(directory, serving(bytes))(digest) == Ok(bytes)
  assert cache.wrap(directory, offline)(digest) == Ok(bytes)

  // Publishing leaves only the entry, never its temporary file.
  assert simplifile.read_directory(directory) == Ok([digest])
  worker_fixture.remove(directory)
}

pub fn a_damaged_entry_is_fetched_again_and_repaired_test() {
  let directory = worker_fixture.temp_directory()
  let bytes = <<"the real chunk":utf8>>
  let digest = blobs.digest(bytes)
  let assert Ok(Nil) =
    simplifile.write_bits(directory <> "/" <> digest, <<"torn":utf8>>)

  // A wrong entry is never returned, and without the controller it is a miss.
  assert cache.wrap(directory, offline)(digest)
    == Error(controllers.Offline("controller unreachable"))
  assert cache.wrap(directory, serving(bytes))(digest) == Ok(bytes)
  assert simplifile.read_bits(directory <> "/" <> digest) == Ok(bytes)
  worker_fixture.remove(directory)
}

pub fn an_unwritable_cache_still_returns_the_fetched_bytes_test() {
  let bytes = <<"kept nowhere":utf8>>
  let digest = blobs.digest(bytes)

  // The directory does not exist, so every publish fails.
  let root = worker_fixture.temp_directory()
  let missing = root <> "/absent/chunks"
  assert cache.wrap(missing, serving(bytes))(digest) == Ok(bytes)
  assert cache.wrap(missing, offline)(digest)
    == Error(controllers.Offline("controller unreachable"))
  worker_fixture.remove(root)
}

pub fn a_malformed_digest_never_names_a_cache_file_test() {
  let directory = worker_fixture.temp_directory()
  let assert Ok(Nil) = simplifile.write_bits(directory <> "/x", <<"x":utf8>>)

  // The fetch decides what a malformed address means, not the cache.
  assert cache.wrap(directory, offline)("../x")
    == Error(controllers.Offline("controller unreachable"))
  assert cache.wrap(directory, offline)("x")
    == Error(controllers.Offline("controller unreachable"))
  worker_fixture.remove(directory)
}

pub fn evictions_take_the_oldest_until_the_rest_fit_test() {
  let entries = [
    cache.Entry("new", 10, 30),
    cache.Entry("old", 10, 10),
    cache.Entry("mid", 10, 20),
  ]
  assert cache.evictions(entries, 30) == []
  assert cache.evictions(entries, 25) == ["old"]
  assert cache.evictions(entries, 10) == ["old", "mid"]
  assert cache.evictions(entries, 0) == ["old", "mid", "new"]
}

pub fn evictions_break_ties_by_name_test() {
  let entries = [cache.Entry("b", 5, 1), cache.Entry("a", 5, 1)]
  assert cache.evictions(entries, 5) == ["a"]
  assert cache.evictions(list.reverse(entries), 5) == ["a"]
}

pub fn prune_bounds_the_directory_test() {
  let directory = worker_fixture.temp_directory()
  let assert Ok(Nil) =
    simplifile.write_bits(directory <> "/one", <<0:size(800)>>)
  let assert Ok(Nil) =
    simplifile.write_bits(directory <> "/two", <<0:size(800)>>)

  cache.prune(directory, 250)
  let assert Ok(left) = simplifile.read_directory(directory)
  assert list.length(left) == 2
  cache.prune(directory, 150)
  let assert Ok(left) = simplifile.read_directory(directory)
  assert list.length(left) == 1
  cache.prune(directory, 0)
  assert simplifile.read_directory(directory) == Ok([])
  worker_fixture.remove(directory)
}

pub fn the_cache_bound_is_checked_test() {
  let with = fn(value) {
    fn(key) {
      case key {
        "GANTRY_WORKER_CACHE_MIB" -> Ok(value)
        _ -> Error(Nil)
      }
    }
  }
  let assert Ok(_) = docker.limits_from(with("0"))
  let assert Ok(_) = docker.limits_from(with("8192"))
  let assert Error(_) = docker.limits_from(with("-1"))
  let assert Error(_) = docker.limits_from(with("lots"))
}
