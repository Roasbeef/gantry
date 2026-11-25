//// Stage verified archives and run one action in a private Docker volume.
//// Cleanup looks up persisted names. Starting an action uses its immutable
//// container ID so a delayed request cannot start a replacement.
//// The transfer_fault boundary rejects bad evidence and retries offline reads.
//// Onboarding uses `probe` and `prepare_image` to check a host with the same
//// cleared Docker environment and image rules the worker runs with.

import envoy
import gantry/blobs
import gantry/internal/ffi_worker
import gantry/worker/controllers
import gantry_core/graph
import gantry_core/queue
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import simplifile

const collector =
  "alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"

const restrictions = [
  "--pull=never", "--network=none", "--cap-drop=ALL", "--read-only",
  "--user=65534:65534", "--security-opt=no-new-privileges", "--pids-limit=128",
  "--log-driver=none", "--ulimit=nofile=1024:1024",
]

const read_output =
  "set -efu
path=$1
set -f
IFS=/
current=/work
for part in $path; do
  current=$current/$part
  [ ! -L \"$current\" ] || exit 1
done
[ -f \"$current\" ] || exit 1
size=$(stat -c %s \"$current\") || exit 1
[ \"$size\" -le \"$2\" ] || exit 1
exec cat \"$current\""

/// Resource limits reserved for one physical worker slot.
pub opaque type Limits {
  Limits(cpus: String, memory: String, workspace: String)
}

/// Only action rejections are terminal. Infrastructure faults keep custody.
pub type Fault {
  Rejected(reason: String)
  Unavailable(reason: String)
  JournalFault(reason: String)
}

/// Read and bound the resource settings consumed by Docker.
///
/// ## Examples
///
/// ```gleam
/// // docker.limits()
/// ```
pub fn limits() -> Result(Limits, String) {
  use cpus <- result.try(resource("GANTRY_WORKER_CPUS", "2", 1, 1024))
  use memory <- result.try(resource(
    "GANTRY_WORKER_MEMORY_MIB",
    "768",
    128,
    2_097_152,
  ))
  use workspace <- result.try(resource(
    "GANTRY_WORKSPACE_MIB",
    "256",
    64,
    1_048_576,
  ))
  Ok(Limits(cpus, memory, workspace))
}

/// Check that the Docker daemon answers within ten seconds.
///
/// ## Examples
///
/// ```gleam
/// // docker.probe()
/// ```
pub fn probe() -> Result(Nil, String) {
  let reply =
    ffi_worker.docker(
      ["info", "--format", "{{.ServerVersion}}"],
      10_000,
      4096,
      ffi_worker.Combined,
    )

  // Any answer other than a clean exit leaves the host unready.
  case reply {
    Ok(ffi_worker.Command(status: 0, ..)) -> Ok(Nil)
    Ok(_) -> Error("Docker did not answer docker info")
    Error(reason) -> Error(reason)
  }
}

/// Make a pinned image available locally, pulling it once if needed. A
/// failed pull returns its output so a caller can keep it as a log.
///
/// ## Examples
///
/// ```gleam
/// // docker.prepare_image("alpine@sha256:...")
/// ```
pub fn prepare_image(image: String) -> Result(Nil, String) {
  use Nil <- result.try(
    validate_image(image) |> result.replace_error("invalid image reference"),
  )
  let inspect =
    ffi_worker.docker(
      ["image", "inspect", image],
      10_000,
      4096,
      ffi_worker.Combined,
    )

  // A local copy is enough. Otherwise one bounded pull fetches it.
  case inspect {
    Ok(ffi_worker.Command(status: 0, ..)) -> Ok(Nil)
    Ok(_) | Error(_) -> {
      use pulled <- result.try(ffi_worker.docker(
        ["pull", image],
        120_000,
        65_536,
        ffi_worker.Combined,
      ))

      // The pull output explains a failure better than its status.
      case pulled.status {
        0 -> Ok(Nil)
        _ ->
          Error(
            bit_array.to_string(pulled.bytes)
            |> result.unwrap("docker pull failed"),
          )
      }
    }
  }
}

/// Remove all resources associated with a previously started attempt.
///
/// ## Examples
///
/// ```gleam
/// // docker.cleanup(directory, name)
/// ```
pub fn cleanup(directory: String, name: String) -> Result(Nil, Fault) {
  use _ <- result.try(remove_container(name))
  use _ <- result.try(remove_container(name <> "-collector"))
  use _ <- result.try(control(["volume", "rm", name], "no such volume"))
  unstage(directory, name)
}

/// Run one attempt after the journal acknowledges its start.
///
/// ## Examples
///
/// ```gleam
/// // docker.execute(directory, name, assignment, limits, network, start, spool)
/// ```
pub fn execute(
  directory: String,
  name: String,
  assignment: queue.Assignment,
  limits: Limits,
  network: controllers.Controllers,
  start: fn() -> Result(Nil, String),
  spool: fn(BitArray) -> Result(String, String),
) -> Result(queue.Completion, Fault) {
  use Nil <- result.try(validate_image(assignment.task.image))
  let path = directory <> "/" <> name <> ".staging"
  use Nil <- result.try(unstage(directory, name))
  use Nil <- result.try(
    simplifile.create_directory(path)
    |> result.replace_error(Unavailable(
      "could not create attempt staging directory",
    )),
  )
  use Nil <- result.try(stage(path, assignment, network))
  use Nil <- result.try(start() |> result.map_error(JournalFault))
  run(path, name, assignment.task, limits, spool)
}

/// Delete the slot-owned staging directory after its archives are unused.
///
/// ## Examples
///
/// ```gleam
/// // docker.unstage(directory, name)
/// ```
pub fn unstage(directory: String, name: String) -> Result(Nil, Fault) {
  // A restart can find that the directory was already removed.
  case simplifile.delete(directory <> "/" <> name <> ".staging") {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(_) -> Error(Unavailable("could not clear attempt staging directory"))
  }
}

/// Verify input bytes and build dependency archives without host extraction.
fn stage(
  directory: String,
  assignment: queue.Assignment,
  network: controllers.Controllers,
) -> Result(Nil, Fault) {
  use source <- result.try(
    controllers.fetch(network, assignment.task.source)
    |> result.map_error(transfer_fault),
  )
  use entries <- result.try(
    ffi_worker.entries(source) |> result.map_error(Rejected),
  )
  use #(blocked, occupied) <- result.try(list.try_fold(
    entries,
    #(set.new(), set.new()),
    index_entry,
  ))
  use Nil <- result.try(
    simplifile.write_bits(source, to: directory <> "/source.tar")
    |> result.replace_error(Unavailable("could not write source archive")),
  )

  let archive_path = directory <> "/dependencies.tar"
  use archive <- result.try(
    ffi_worker.archive_open(archive_path) |> result.map_error(Unavailable),
  )
  let added =
    list.try_fold(assignment.lease.key.dependencies, 1024, fn(size, item) {
      use Nil <- result.try(check_destination(item.path, blocked, occupied))
      use bytes <- result.try(
        controllers.fetch(network, item.digest)
        |> result.map_error(transfer_fault),
      )

      // Account for the file header, block padding, and end-of-archive blocks.
      let total = size + 512 + { bit_array.byte_size(bytes) + 511 } / 512 * 512

      // The archive has the same byte budget as the source blob.
      use Nil <- result.try(case total <= blobs.limit {
        True -> Ok(Nil)
        False -> Error(Rejected("dependency archive exceeds worker size limit"))
      })

      ffi_worker.archive_add(archive, item.path, bytes)
      |> result.map_error(Unavailable)
      |> result.replace(total)
    })
  let closed =
    ffi_worker.archive_close(archive) |> result.map_error(Unavailable)
  use _ <- result.try(added)
  use Nil <- result.try(closed)
  use info <- result.try(
    simplifile.file_info(archive_path)
    |> result.replace_error(Unavailable("could not inspect dependency archive")),
  )

  // Long names can add PAX headers beyond the regular file blocks.
  use Nil <- result.try(case info.size <= blobs.limit {
    True -> Ok(Nil)
    False -> Error(Rejected("dependency archive exceeds worker size limit"))
  })

  list.try_fold(["source.tar", "dependencies.tar"], Nil, fn(_, file) {
    simplifile.set_permissions_octal(directory <> "/" <> file, 420)
    |> result.replace_error(Unavailable("could not set archive permissions"))
  })
}

/// Classify source paths that cannot be traversed or replaced by dependencies.
fn index_entry(
  index: #(set.Set(String), set.Set(String)),
  entry: ffi_worker.Entry,
) -> Result(#(set.Set(String), set.Set(String)), Fault) {
  // Files block traversal. Links also block replacement at their own path.
  let #(path, blocked, occupied) = case entry {
    ffi_worker.Directory(path) -> {
      // Tar directory entries may end with a slash.
      let path = case string.ends_with(path, "/") {
        True -> string.drop_end(path, 1)
        False -> path
      }

      #(path, index.0, set.insert(index.1, path))
    }
    ffi_worker.Regular(path) -> #(path, set.insert(index.0, path), index.1)
    ffi_worker.Symlink(path) -> #(
      path,
      set.insert(index.0, path),
      set.insert(index.1, path),
    )
  }

  let clean =
    string.split(path, "/")
    |> list.all(fn(part) {
      part != "" && part != "." && part != ".." && part != ".git"
    })

  // Each archive member must stay relative to the isolated workspace.
  case clean {
    True -> Ok(#(blocked, occupied))
    False -> Error(Rejected("unsafe path in source archive"))
  }
}

/// Require a declared dependency to stay within regular workspace paths.
fn check_destination(
  path: String,
  blocked: set.Set(String),
  occupied: set.Set(String),
) -> Result(Nil, Fault) {
  let parents =
    string.split(path, "/")
    |> list.reverse
    |> list.drop(1)
    |> list.reverse
    |> list.fold(#("", False), fn(found, segment) {
      // Check every ancestor before reading or writing a dependency.
      let prefix = case found.0 {
        "" -> segment
        previous -> previous <> "/" <> segment
      }

      #(prefix, found.1 || set.contains(blocked, prefix))
    })

  // A dependency may replace a regular file at the same path.
  case graph.valid_path(path), parents.1 || set.contains(occupied, path) {
    True, False -> Ok(Nil)
    False, _ -> Error(Rejected("invalid dependency path"))
    True, True ->
      Error(Rejected(
        "dependency crosses a non-directory source entry or replaces a directory",
      ))
  }
}

/// Create the volume and collector, start the action, then capture its result.
fn run(
  directory: String,
  name: String,
  task: queue.Task,
  limits: Limits,
  spool: fn(BitArray) -> Result(String, String),
) -> Result(queue.Completion, Fault) {
  use _ <- result.try(control(
    [
      "volume",
      "create",
      "--driver",
      "local",
      "--opt",
      "type=tmpfs",
      "--opt",
      "device=tmpfs",
      "--opt",
      "o=size=" <> limits.workspace <> "m,nr_inodes=1048576,mode=1777",
      name,
    ],
    "",
  ))
  let mount = "type=volume,src=" <> name <> ",dst=/work,volume-nocopy"
  use _ <- result.try(control(
    list.append(["run", "-d", ..restrictions], [
      "--name",
      name <> "-collector",
      "--mount",
      mount <> ",readonly",
      "--memory=128m",
      "--cpus=0.25",
      "--entrypoint",
      "/bin/sleep",
      collector,
      "7200",
    ]),
    "",
  ))
  use identity <- result.try(control(
    list.append(["create", ..restrictions], [
      "--memory=" <> limits.memory <> "m",
      "--cpus=" <> limits.cpus,
      "--name",
      name,
      "--mount",
      mount,
      "--workdir",
      "/work",
      "--tmpfs",
      "/tmp:rw,nosuid,nodev,size=64m,mode=1777",
      "--mount",
      bind(directory, "source.tar"),
      "--mount",
      bind(directory, "dependencies.tar"),
      "--entrypoint",
      "/bin/sh",
      task.image,
      "-c",
      "set -eu; tar xf /source.tar; tar xf /dependencies.tar; exec \"$@\"",
      "gantry",
      ..task.action.argv
    ]),
    "",
  ))
  let container = string.trim(identity)

  // Start Docker by immutable container ID after validating its response.
  use Nil <- result.try(case blobs.valid(container) {
    True -> Ok(Nil)
    False -> Error(Unavailable("Docker returned an invalid container ID"))
  })

  use command <- result.try(
    ffi_worker.docker(
      ["start", "-a", container],
      task.action.timeout * 1000,
      65_536,
      ffi_worker.Combined,
    )
    |> result.map_error(Unavailable),
  )
  use log <- result.try(
    spool(with_truncation(command)) |> result.map_error(JournalFault),
  )
  use state <- result.try(control(
    ["inspect", "--format", "{{.State.Status}} {{.State.ExitCode}}", container],
    "",
  ))

  // Use Docker's exit state to distinguish an action exit from timeout.
  case string.split(string.trim(state), " ") {
    ["exited", number] -> {
      use code <- result.try(
        int.parse(number)
        |> result.replace_error(Unavailable("invalid Docker exit code")),
      )
      use _ <- result.try(remove_container(name))
      complete(
        name,
        task.action.outputs,
        log,
        case code {
          0 -> command.status
          _ -> code
        },
        spool,
      )
    }
    _ if command.status == 124 || command.status == 137 ->
      Ok(queue.Rejected("action exceeded its wall deadline", log))
    _ -> Ok(queue.Rejected("container failed to exit normally", log))
  }
}

/// Collect declared files only after Docker confirms successful action exit.
fn complete(
  name: String,
  outputs: List(String),
  log: String,
  status: Int,
  spool: fn(BitArray) -> Result(String, String),
) -> Result(queue.Completion, Fault) {
  // Only a successful action may publish declared outputs.
  case status {
    0 -> {
      let files =
        list.try_map(outputs, fn(path) { read_artifact(name, path, spool) })

      // Keep the action log when a declared output is invalid.
      case files {
        Ok(files) -> Ok(queue.Succeeded(files, log))
        Error(Rejected(reason)) -> Ok(queue.Rejected(reason, log))
        Error(other) -> Error(other)
      }
    }
    code ->
      Ok(queue.Rejected(
        "action exited with status " <> int.to_string(code),
        log,
      ))
  }
}

/// Read one regular file through the isolated, read-only collector.
fn read_artifact(
  name: String,
  path: String,
  spool: fn(BitArray) -> Result(String, String),
) -> Result(queue.Artifact, Fault) {
  let reason =
    "missing, linked, unreadable or oversized declared output: " <> path
  use command <- result.try(
    ffi_worker.docker(
      [
        "exec",
        name <> "-collector",
        "/bin/sh",
        "-c",
        read_output,
        "gantry-collector",
        path,
        int.to_string(blobs.limit),
      ],
      60_000,
      blobs.limit,
      ffi_worker.Stdout,
    )
    |> result.map_error(Unavailable),
  )

  // Require a complete, successful capture before hashing artifact data.
  case command {
    ffi_worker.Command(0, bytes, ffi_worker.Complete) ->
      spool(bytes)
      |> result.map_error(JournalFault)
      |> result.map(queue.Artifact(path, _))
    _ -> Error(Rejected(reason))
  }
}

/// Build an input archive mount with its fixed destination and read-only mode.
fn bind(directory: String, file: String) -> String {
  "type=bind,src="
  <> directory
  <> "/"
  <> file
  <> ",dst=/"
  <> file
  <> ",readonly"
}

/// Retain the log prefix and tell the reader when more bytes were written.
fn with_truncation(command: ffi_worker.Command) -> BitArray {
  // Expose when the action wrote more bytes than the log budget.
  case command {
    ffi_worker.Command(_, bytes, ffi_worker.Clipped) -> <<
      bytes:bits,
      "\n[output truncated]\n":utf8,
    >>
    ffi_worker.Command(_, bytes, ffi_worker.Complete) -> bytes
  }
}

fn remove_container(name: String) -> Result(String, Fault) {
  control(["rm", "-fv", name], "no such container")
}

/// Require Docker to acknowledge a control request or a known missing resource.
fn control(args: List(String), missing: String) -> Result(String, Fault) {
  use reply <- result.try(
    ffi_worker.docker(args, 30_000, 16_384, ffi_worker.Combined)
    |> result.map_error(Unavailable),
  )
  let diagnostic =
    bit_array.to_string(reply.bytes)
    |> result.unwrap("Docker returned non-UTF-8 output")

  // A missing container or volume is already clean.
  case
    reply.status == 0
    || {
      missing != "" && string.contains(string.lowercase(diagnostic), missing)
    }
  {
    True -> Ok(diagnostic)
    False ->
      Error(Unavailable(
        "Docker: " <> string.slice(string.trim(diagnostic), 0, 512),
      ))
  }
}

/// Bound an operator-supplied reservation before constructing Docker flags.
fn resource(
  key: String,
  fallback: String,
  low: Int,
  high: Int,
) -> Result(String, String) {
  let value = envoy.get(key) |> result.unwrap(fallback)

  // Docker only receives limits within the supported resource range.
  case int.parse(value) {
    Ok(number) if number >= low && number <= high -> Ok(int.to_string(number))
    _ ->
      Error(
        key
        <> " must be between "
        <> int.to_string(low)
        <> " and "
        <> int.to_string(high),
      )
  }
}

/// Check the image argument before it crosses Docker's CLI boundary.
fn validate_image(image: String) -> Result(Nil, Fault) {
  let allowed =
    string.to_utf_codepoints(image)
    |> list.all(fn(point) {
      let code = string.utf_codepoint_to_int(point)
      { code >= 48 && code <= 57 }
      || { code >= 65 && code <= 90 }
      || { code >= 97 && code <= 122 }
      || list.contains([45, 46, 47, 58, 64, 95], code)
    })

  // Reject option-like or malformed image arguments.
  case allowed && image != "" && !string.starts_with(image, "-") {
    True -> Ok(Nil)
    False -> Error(Rejected("invalid image reference"))
  }
}

/// Preserve the distinction between an invalid blob and an offline controller.
fn transfer_fault(error: controllers.Fault) -> Fault {
  case error {
    controllers.Offline(reason) -> Unavailable(reason)
    controllers.Invalid(reason) -> Rejected(reason)
  }
}
