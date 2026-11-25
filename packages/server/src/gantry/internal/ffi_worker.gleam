//// The worker adapter exposes the bounded Docker runner and tar
//// metadata. Decisions about work and result publication stay in Gleam.

import envoy
import gantry/internal/ffi_host
import gleam/list
import gleam/result

/// Tar members that can enter an isolated workspace.
pub type Entry {
  Directory(path: String)
  Regular(path: String)
  Symlink(path: String)
}

/// An open, worker-owned dependency archive.
pub type Archive

/// Run Docker with a cleared environment and a bounded output stream.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.docker(["version"], 30_000, 4096, ffi_host.Combined)
/// ```
pub fn docker(
  args: List(String),
  deadline_ms: Int,
  limit: Int,
  stream: ffi_host.Stream,
) -> Result(ffi_host.Command, String) {
  let path = envoy.get("PATH") |> result.unwrap("/usr/local/bin:/usr/bin:/bin")
  let connection =
    list.filter_map(["DOCKER_HOST", "XDG_RUNTIME_DIR"], fn(key) {
      envoy.get(key) |> result.map(fn(value) { key <> "=" <> value })
    })
  let settings = ["PATH=" <> path, "DOCKER_CONFIG=/nonexistent", ..connection]
  ffi_host.capture(
    "docker",
    args,
    ffi_host.Clear(settings),
    stream,
    limit,
    deadline_ms,
  )
}

/// Inspect source members without extracting them on the worker host.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.entries(source_tar)
/// ```
@external(erlang, "gantry_worker_ffi", "entries")
pub fn entries(bytes: BitArray) -> Result(List(Entry), String)

/// Open a fresh archive for verified upstream files.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.archive_open("/tmp/attempt/dependencies.tar")
/// ```
@external(erlang, "gantry_worker_ffi", "archive_open")
pub fn archive_open(path: String) -> Result(Archive, String)

/// Write one regular file to the dependency archive.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.archive_add(archive, "out/product", bytes)
/// ```
@external(erlang, "gantry_worker_ffi", "archive_add")
pub fn archive_add(
  archive: Archive,
  path: String,
  bytes: BitArray,
) -> Result(Nil, String)

/// Finish writing the dependency archive.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.archive_close(archive)
/// ```
@external(erlang, "gantry_worker_ffi", "archive_close")
pub fn archive_close(archive: Archive) -> Result(Nil, String)
