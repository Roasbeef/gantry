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

/// Inspect the members of an archive file without extracting it on the
/// worker host.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.entries("/work/source.tar")
/// ```
@external(erlang, "gantry_worker_ffi", "entries")
pub fn entries(path: String) -> Result(List(Entry), String)

/// Add a directory and everything under it to an open archive, naming it
/// `name` inside the archive. Empty directories are kept.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.archive_add_tree(archive, "/scratch/repo/.git", ".git")
/// ```
@external(erlang, "gantry_worker_ffi", "archive_add_tree")
pub fn archive_add_tree(
  archive: Archive,
  directory: String,
  name: String,
) -> Result(Nil, String)

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

/// Remove one empty directory with rmdir(2), treating a missing one as
/// removed. OTP's `file:del_dir/1` is the primitive: a cgroup v2 directory
/// cannot be deleted recursively, because its interface files cannot be
/// unlinked, and simplifile only offers the recursive delete.
///
/// ## Examples
///
/// ```gleam
/// // ffi_worker.remove_directory("/sys/fs/cgroup/.../gantry-1")
/// ```
@external(erlang, "gantry_worker_ffi", "remove_directory")
pub fn remove_directory(path: String) -> Result(Nil, String)
