//// The worker adapter exposes OS locking, bounded Docker ports, and tar
//// metadata. Decisions about work and result publication stay in Gleam.

import envoy
import gleam/list
import gleam/result

/// Select which bytes a Docker subprocess may write to the captured stream.
pub type Stream {
  Combined
  Stdout
}

/// Whether the capture retained every byte written by the subprocess.
pub type Capture {
  Complete
  Clipped
}

/// A bounded stream and its subprocess exit status.
pub type Command {
  Command(status: Int, bytes: BitArray, capture: Capture)
}

/// Tar members that can enter an isolated workspace.
pub type Entry {
  Directory(path: String)
  Regular(path: String)
  Symlink(path: String)
}

/// An open, worker-owned dependency archive.
pub type Archive

/// Hold an exclusive OS lock for the life of the worker VM.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.lock("/srv/gantry/worker/slot.lock")
/// ```
@external(erlang, "gantry_worker_ffi", "lock")
pub fn lock(path: String) -> Result(Nil, String)

/// Run Docker with a cleared environment and a bounded output stream.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.docker(["version"], 30_000, 4096, ffi_worker.Combined)
/// ```
pub fn docker(
  args: List(String),
  deadline_ms: Int,
  limit: Int,
  stream: Stream,
) -> Result(Command, String) {
  let path = envoy.get("PATH") |> result.unwrap("/usr/local/bin:/usr/bin:/bin")
  let connection =
    list.filter_map(["DOCKER_HOST", "XDG_RUNTIME_DIR"], fn(key) {
      envoy.get(key) |> result.map(fn(value) { key <> "=" <> value })
    })
  let settings = ["PATH=" <> path, "DOCKER_CONFIG=/nonexistent", ..connection]
  docker_port(args, settings, deadline_ms, limit, stream)
}

/// Start the Docker port with the selected environment and capture policy.
@external(erlang, "gantry_worker_ffi", "docker")
fn docker_port(
  args: List(String),
  settings: List(String),
  deadline_ms: Int,
  limit: Int,
  stream: Stream,
) -> Result(Command, String)

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
