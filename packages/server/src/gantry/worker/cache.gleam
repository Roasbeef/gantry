//// Keep the input blobs a slot fetched, keyed by their digest, so a later
//// action that names the same chunk reads it from disk instead of the
//// controller.
////
//// ## Flow
////
//// ```text
//// stage:  prune -> evictions -> wrap(fetch) -> inputs.stage
//// lookup: read <digest> -> digest matches?  yes -> bytes
////                                            no  -> refill -> bytes
//// ```
////
//// A blob's address is its SHA-256, so an entry can only ever hold one
//// value. Every hit is hashed again before it is returned, which makes a
//// torn or tampered file a miss rather than a wrong input. Publishing writes
//// a unique temporary file and renames it into place, so a reader never sees
//// a partial entry. The cache is an optimization only: a failure to read,
//// write or prune it falls back to the controller and never fails a stage.
////
//// `prune` bounds the directory before each stage. When its files exceed
//// the limit it deletes the oldest by modification time, which counts the
//// temporary files a killed worker left behind.

import gantry/blobs
import gantry/worker/controllers
import gantry/worker/inputs
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import simplifile

/// One file in the cache directory, as `evictions` needs it.
pub type Entry {
  Entry(name: String, size: Int, modified: Int)
}

/// Wrap a fetch so verified blobs are served from, and kept in,
/// `directory`.
///
/// ## Examples
///
/// ```gleam
/// // inputs.stage(cache.wrap(dir, controllers.fetch(network, _)), input, path)
/// ```
pub fn wrap(directory: String, fetch: inputs.Fetch) -> inputs.Fetch {
  fn(digest) {
    // Only a well-formed digest names a file, so no name escapes the directory.
    case blobs.valid(digest) {
      False -> fetch(digest)
      True -> {
        let path = directory <> "/" <> digest

        // A hit is hashed again, so a torn or replaced file is a miss.
        case simplifile.read_bits(path) {
          Ok(bytes) ->
            case blobs.digest(bytes) == digest {
              True -> Ok(bytes)
              False -> refill(path, digest, fetch)
            }
          Error(_) -> refill(path, digest, fetch)
        }
      }
    }
  }
}

/// Fetch a blob that is absent or damaged on disk, then publish it. A
/// failed publish leaves no entry and still returns the verified bytes.
fn refill(
  path: String,
  digest: String,
  fetch: inputs.Fetch,
) -> Result(BitArray, controllers.Fault) {
  use bytes <- result.map(fetch(digest))
  let temporary = path <> "." <> blobs.unique_suffix() <> ".tmp"
  let published = {
    use Nil <- result.try(simplifile.write_bits(temporary, bytes))
    simplifile.rename(temporary, path)
  }

  // A publish that failed part way leaves no temporary file behind.
  case published {
    Ok(Nil) -> Nil
    Error(_) -> {
      let _ = simplifile.delete(temporary)
      Nil
    }
  }

  bytes
}

/// Delete the oldest files in `directory` until it holds at most
/// `limit` bytes. A limit of zero empties it.
///
/// ## Examples
///
/// ```gleam
/// // cache.prune("/var/lib/gantry/slot-1/chunks", 2048 * 1024 * 1024)
/// ```
pub fn prune(directory: String, limit: Int) -> Nil {
  let _ = simplifile.create_directory_all(directory)
  let entries =
    simplifile.read_directory(directory)
    |> result.unwrap([])
    |> list.filter_map(fn(name) {
      use info <- result.map(simplifile.file_info(directory <> "/" <> name))
      Entry(name, info.size, info.mtime_seconds)
    })
  list.each(evictions(entries, limit), fn(name) {
    let _ = simplifile.delete(directory <> "/" <> name)
    Nil
  })
}

/// Choose the files to delete so the rest fit in `limit` bytes, oldest
/// first. Names break ties, so the choice does not depend on listing order.
///
/// ## Examples
///
/// ```gleam
/// cache.evictions([cache.Entry("a", 10, 1), cache.Entry("b", 10, 2)], 10)
/// // -> ["a"]
/// ```
pub fn evictions(entries: List(Entry), limit: Int) -> List(String) {
  let total = list.fold(entries, 0, fn(sum, entry) { sum + entry.size })
  let oldest =
    list.sort(entries, fn(a, b) {
      int.compare(a.modified, b.modified)
      |> order.break_tie(string.compare(a.name, b.name))
    })
  take_until(oldest, total, limit, [])
}

/// Walk the entries oldest first, choosing each one while the bytes left
/// still exceed `limit`, and return the chosen names in that order.
fn take_until(
  entries: List(Entry),
  total: Int,
  limit: Int,
  chosen: List(String),
) -> List(String) {
  case entries {
    [entry, ..rest] if total > limit ->
      take_until(rest, total - entry.size, limit, [entry.name, ..chosen])
    _ -> list.reverse(chosen)
  }
}
