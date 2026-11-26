//// Stage verified archives and run one action in a private Docker volume.
//// Cleanup looks up persisted names. Starting an action uses its immutable
//// container ID so a delayed request cannot start a replacement.
//// The transfer_fault boundary rejects bad evidence and retries offline reads.
////
//// The journal's start marker is committed immediately before `docker start`,
//// the only effect that runs action code. A fault before that point leaves
//// only Docker resources under the attempt's own name, which `execute`
//// removes before it begins, so the slot can retry the attempt unchanged.
////
//// ## Flow
////
//// ```text
//// boot:    limits -> preflight -> check_sandboxes -> try_sandboxes
//// attempt: execute -> action_flags -> cleanup -> fetcher -> stage -> run -> start
//// after:   cleanup -> unstage
//// ```
////
//// The sandbox profile is chosen by the task and turned into flags only by
//// `action_flags`. A strict task gets the fixed restrictions and limits. A
//// userns task gets the same flags with three appended, and a slot that
//// cannot honour them refuses at boot or rejects the action before staging.

import envoy
import gantry/blobs
import gantry/internal/ffi_host
import gantry/internal/ffi_worker
import gantry/worker/cache
import gantry/worker/controllers
import gantry/worker/inputs
import gantry_core/chunks
import gantry_core/graph
import gantry_core/queue
import gantry_core/sandbox
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import simplifile
import weft

const collector =
  "alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"

/// Flags every container gets. Process and file limits are added per role.
const restrictions = [
  "--pull=never", "--network=none", "--cap-drop=ALL", "--read-only",
  "--user=65534:65534", "--security-opt=no-new-privileges", "--log-driver=none",
]

/// The collector only sleeps and reads one file, so its limits stay small.
const collector_limits = ["--pids-limit=128", "--ulimit=nofile=1024:1024"]

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

/// Resource limits reserved for one physical worker slot, and the host
/// files a wider sandbox profile needs. Both come from the worker's own
/// environment, never from a task.
pub opaque type Limits {
  Limits(
    cpus: String,
    memory: String,
    workspace: String,
    pids: String,
    nofile: String,
    tmp: String,
    cache: Int,
    userns_seccomp: Option(String),
  )
}

/// Only action rejections are terminal. Infrastructure faults keep custody.
pub type Fault {
  Rejected(reason: String)
  Unavailable(reason: String)
  JournalFault(reason: String)
}

/// Read and bound the resource settings consumed by Docker.
///
/// | Variable | Default | Bounds |
/// | --- | --- | --- |
/// | `GANTRY_WORKER_CPUS` | 2 | 1 to 1024 |
/// | `GANTRY_WORKER_MEMORY_MIB` | 768 | 128 to 2097152 |
/// | `GANTRY_WORKSPACE_MIB` | 256 | 64 to 1048576 |
/// | `GANTRY_WORKER_PIDS` | 4096 | 64 to 1048576 |
/// | `GANTRY_WORKER_NOFILE` | 65536 | 256 to 1048576 |
/// | `GANTRY_WORKER_TMP_MIB` | 1024 | 16 to 65536 |
/// | `GANTRY_WORKER_CACHE_MIB` | 2048 | 0 to 1048576 |
/// | `GANTRY_WORKER_USERNS_SECCOMP` | unset | an absolute path |
///
/// The process default lets a BEAM build start its scheduler and dirty
/// threads on a many-core host. The `/tmp` tmpfs counts against the
/// container's memory limit, so a larger size only bounds the file it holds.
///
/// `GANTRY_WORKER_CACHE_MIB` bounds the slot's cache of fetched input blobs,
/// kept under `GANTRY_WORKER_DIR/chunks`. Zero turns the cache off.
///
/// `GANTRY_WORKER_USERNS_SECCOMP` names the seccomp profile that the `userns`
/// sandbox runs under. A worker without it is not capable of `userns` and
/// rejects such an action before creating anything.
///
/// ## Examples
///
/// ```gleam
/// // docker.limits()
/// ```
pub fn limits() -> Result(Limits, String) {
  limits_from(envoy.get)
}

/// Read the same settings through a lookup function.
///
/// ## Examples
///
/// ```gleam
/// docker.limits_from(fn(_) { Error(Nil) })
/// ```
pub fn limits_from(
  lookup: fn(String) -> Result(String, Nil),
) -> Result(Limits, String) {
  use cpus <- result.try(resource(lookup, "GANTRY_WORKER_CPUS", "2", 1, 1024))
  use memory <- result.try(resource(
    lookup,
    "GANTRY_WORKER_MEMORY_MIB",
    "768",
    128,
    2_097_152,
  ))
  use workspace <- result.try(resource(
    lookup,
    "GANTRY_WORKSPACE_MIB",
    "256",
    64,
    1_048_576,
  ))
  use pids <- result.try(resource(
    lookup,
    "GANTRY_WORKER_PIDS",
    "4096",
    64,
    1_048_576,
  ))
  use nofile <- result.try(resource(
    lookup,
    "GANTRY_WORKER_NOFILE",
    "65536",
    256,
    1_048_576,
  ))
  use tmp <- result.try(resource(
    lookup,
    "GANTRY_WORKER_TMP_MIB",
    "1024",
    16,
    65_536,
  ))

  use cache <- result.try(resource(
    lookup,
    "GANTRY_WORKER_CACHE_MIB",
    "2048",
    0,
    1_048_576,
  ))
  let cache = int.parse(cache) |> result.unwrap(0)

  // The userns profile is optional. When named, its path must be absolute.
  use userns_seccomp <- result.try(case lookup("GANTRY_WORKER_USERNS_SECCOMP") {
    Error(Nil) | Ok("") -> Ok(None)
    Ok(path) ->
      case string.starts_with(path, "/") {
        True -> Ok(Some(path))
        False -> Error("GANTRY_WORKER_USERNS_SECCOMP must be an absolute path")
      }
  })

  Ok(Limits(cpus, memory, workspace, pids, nofile, tmp, cache, userns_seccomp))
}

/// Check that the host files the configured sandbox profiles need exist
/// before the slot claims work, as `preflight` checks the collector image.
///
/// ## Examples
///
/// ```gleam
/// // docker.check_sandboxes(limits)
/// ```
pub fn check_sandboxes(limits: Limits) -> Result(Nil, String) {
  // The fields Docker requires of a seccomp profile document.
  let profile = {
    use _ <- decode.field("defaultAction", decode.string)
    use _ <- decode.field("syscalls", decode.list(decode.dynamic))
    decode.success(Nil)
  }

  // Docker reads the file at each container create. An unreadable or
  // malformed file would fail there as a retryable fault on every attempt,
  // so a configured path must hold a profile before the slot claims work.
  let readable = case limits.userns_seccomp {
    None -> Ok(Nil)
    Some(path) ->
      simplifile.read(path)
      |> result.replace_error(path)
      |> result.try(fn(text) {
        json.parse(text, profile) |> result.replace_error(path)
      })
  }

  result.map_error(readable, fn(path) {
    "GANTRY_WORKER_USERNS_SECCOMP names "
    <> path
    <> ", which is not a readable seccomp profile"
  })
}

/// The command a trial container runs to show that the host lets the
/// `userns` profile create what a nested `bwrap` creates: a user namespace
/// mapped to root, a mount namespace, and a PID namespace with a fresh /proc.
const userns_trial = "unshare -U -r -m -p -f --mount-proc true"

/// Run one throwaway container under the `userns` flags and refuse to start
/// the slot when the host cannot create the namespaces the profile exists
/// for. A host can permit every flag and still refuse the namespace, for
/// example when AppArmor restricts unprivileged user namespaces. Without this
/// check such a slot would claim `userns` actions and fail every one of them.
/// A worker without the profile configured skips the trial.
///
/// ## Examples
///
/// ```gleam
/// // docker.try_sandboxes(limits)
/// ```
pub fn try_sandboxes(limits: Limits) -> Result(Nil, String) {
  case action_flags(limits, sandbox.Userns) {
    // Only a worker configured for the profile is asked to prove it.
    Error(_) -> Ok(Nil)
    Ok(flags) -> {
      let reply =
        ffi_worker.docker(
          list.flatten([
            ["run", "--rm"],
            flags,
            ["--entrypoint", "/bin/sh", collector, "-c", userns_trial],
          ]),
          60_000,
          4096,
          ffi_host.Combined,
        )

      // Only a clean exit shows the namespaces were created.
      case reply {
        Ok(ffi_host.Command(exit: ffi_host.Exited(0), ..)) -> Ok(Nil)
        Ok(ffi_host.Command(bytes:, ..)) ->
          Error(
            "this host cannot create user namespaces under the userns sandbox, so the slot will not serve it ("
            <> {
              bit_array.to_string(bytes)
              |> result.unwrap("no output")
              |> string.trim
              |> string.slice(0, 256)
            }
            <> "); check kernel.apparmor_restrict_unprivileged_userns",
          )
        Error(reason) ->
          Error("could not run the userns sandbox trial: " <> reason)
      }
    }
  }
}

/// The sandbox flags an action container receives, apart from its mounts.
/// The strict restrictions and the limits come first for every profile, and
/// a wider profile only appends to them. A profile this worker is not
/// configured for is a rejection, never a narrower or wider run. The root is
/// read-only, so `/tmp` and `/var/tmp` are each a private tmpfs of the
/// configured size, writable as programs expect on any Linux host.
///
/// | Profile  | Appended flags                                              |
/// | -------- | ----------------------------------------------------------- |
/// | `Strict` | none                                                        |
/// | `Userns` | its seccomp profile, `systempaths` and `apparmor` unconfined |
///
/// All three `userns` flags were measured as necessary for a nested `bwrap`;
/// see `docs/design-notes/sandbox-profiles.md`.
///
/// ## Examples
///
/// ```gleam
/// // docker.action_flags(limits, sandbox.Strict)
/// ```
pub fn action_flags(
  limits: Limits,
  profile: sandbox.Profile,
) -> Result(List(String), Fault) {
  let strict =
    list.append(restrictions, [
      "--pids-limit=" <> limits.pids,
      "--ulimit=nofile=" <> limits.nofile <> ":" <> limits.nofile,
      "--memory=" <> limits.memory <> "m",
      "--cpus=" <> limits.cpus,
      "--tmpfs",
      "/tmp:rw,nosuid,nodev,size=" <> limits.tmp <> "m,mode=1777",
      "--tmpfs",
      "/var/tmp:rw,nosuid,nodev,size=" <> limits.tmp <> "m,mode=1777",
    ])

  // Only the profile chooses what is appended. The strict prefix is shared.
  case profile, limits.userns_seccomp {
    sandbox.Strict, _ -> Ok(strict)
    sandbox.Userns, Some(seccomp) ->
      Ok(
        list.append(strict, [
          "--security-opt=seccomp=" <> seccomp,
          "--security-opt=systempaths=unconfined",
          "--security-opt=apparmor=unconfined",
        ]),
      )
    sandbox.Userns, None ->
      Error(Rejected(
        "this worker is not configured for the userns sandbox; set GANTRY_WORKER_USERNS_SECCOMP",
      ))
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

/// Check that the collector image is present before the slot claims work.
///
/// ## Examples
///
/// ```gleam
/// // docker.preflight()
/// ```
pub fn preflight() -> Result(Nil, String) {
  case control(["image", "inspect", "--format", "{{.Id}}", collector], "") {
    Ok(_) -> Ok(Nil)
    Error(Unavailable(reason))
    | Error(Rejected(reason))
    | Error(JournalFault(reason)) ->
      Error(
        "the collector image is not usable; run `docker pull "
        <> collector
        <> "` on this host ("
        <> reason
        <> ")",
      )
  }
}

/// Check that the Docker daemon answers within ten seconds. Onboarding uses
/// it to check a host with the same cleared Docker environment the worker
/// runs with.
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
      ffi_host.Combined,
    )

  // Any answer other than a clean exit leaves the host unready.
  case reply {
    Ok(ffi_host.Command(exit: ffi_host.Exited(0), ..)) -> Ok(Nil)
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
      ffi_host.Combined,
    )

  // A local copy is enough. Otherwise one bounded pull fetches it.
  case inspect {
    Ok(ffi_host.Command(exit: ffi_host.Exited(0), ..)) -> Ok(Nil)
    Ok(_) | Error(_) -> {
      use pulled <- result.try(ffi_worker.docker(
        ["pull", image],
        120_000,
        65_536,
        ffi_host.Combined,
      ))

      // The pull output explains a failure better than its status.
      case pulled.exit {
        ffi_host.Exited(0) -> Ok(Nil)
        ffi_host.Exited(_) | ffi_host.TimedOut ->
          Error(
            bit_array.to_string(pulled.bytes)
            |> result.unwrap("docker pull failed"),
          )
      }
    }
  }
}

/// Run one attempt, committing the start marker just before Docker starts it.
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

  // An unsupported profile is refused before any resource exists.
  use flags <- result.try(action_flags(limits, assignment.task.sandbox))
  let path = directory <> "/" <> name <> ".staging"

  // An earlier try can have stopped after creating resources but before start.
  use Nil <- result.try(cleanup(directory, name))
  use Nil <- result.try(
    simplifile.create_directory(path)
    |> result.replace_error(Unavailable(
      "could not create attempt staging directory",
    )),
  )
  use Nil <- result.try(stage(
    path,
    assignment,
    fetcher(directory, limits, network),
  ))
  run(path, name, assignment.task, limits, flags, start, spool)
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

/// Fetch from the controller, through the slot's blob cache unless it is off.
/// The cache is pruned to its bound before each stage, so it never holds
/// more than one stage's inputs beyond the limit.
fn fetcher(
  directory: String,
  limits: Limits,
  network: controllers.Controllers,
) -> inputs.Fetch {
  let remote = controllers.fetch(network, _)
  let chunks = directory <> "/chunks"
  cache.prune(chunks, limits.cache * 1024 * 1024)

  // A zero bound has just emptied any earlier cache, so fetch straight through.
  case limits.cache {
    0 -> remote
    _ -> cache.wrap(chunks, remote)
  }
}

/// Verify input bytes and build dependency archives without host extraction.
fn stage(
  directory: String,
  assignment: queue.Assignment,
  fetch: inputs.Fetch,
) -> Result(Nil, Fault) {
  let source_path = directory <> "/source.tar"
  use Nil <- result.try(
    inputs.stage(fetch, assignment.task.source, source_path)
    |> result.map_error(transfer_fault),
  )
  use entries <- result.try(
    ffi_worker.entries(source_path) |> result.map_error(Rejected),
  )
  use #(blocked, occupied) <- result.try(list.try_fold(
    entries,
    #(set.new(), set.new()),
    index_entry,
  ))
  use Nil <- result.try(stage_git(directory, assignment.task.git, fetch))

  let archive_path = directory <> "/dependencies.tar"
  use archive <- result.try(
    ffi_worker.archive_open(archive_path) |> result.map_error(Unavailable),
  )
  let added =
    list.try_fold(
      queue.lease_key(assignment.lease).dependencies,
      1024,
      fn(size, item) {
        use Nil <- result.try(check_destination(item.path, blocked, occupied))
        use bytes <- result.try(
          fetch(item.digest)
          |> result.map_error(transfer_fault),
        )

        // Account for the file header, block padding, and end-of-archive blocks.
        let total =
          size + 512 + { bit_array.byte_size(bytes) + 511 } / 512 * 512

        // The archive has the same byte budget as a chunked source.
        use Nil <- result.try(case total <= chunks.input_limit {
          True -> Ok(Nil)
          False ->
            Error(Rejected("dependency archive exceeds worker size limit"))
        })

        ffi_worker.archive_add(archive, item.path, bytes)
        |> result.map_error(Unavailable)
        |> result.replace(total)
      },
    )
  let closed =
    ffi_worker.archive_close(archive) |> result.map_error(Unavailable)
  use _ <- result.try(added)
  use Nil <- result.try(closed)
  use info <- result.try(
    simplifile.file_info(archive_path)
    |> result.replace_error(Unavailable("could not inspect dependency archive")),
  )

  // Long names can add PAX headers beyond the regular file blocks.
  use Nil <- result.try(case info.size <= chunks.input_limit {
    True -> Ok(Nil)
    False -> Error(Rejected("dependency archive exceeds worker size limit"))
  })

  list.try_fold(archives(assignment.task), Nil, fn(_, file) {
    simplifile.set_permissions_octal(directory <> "/" <> file, 420)
    |> result.replace_error(Unavailable("could not set archive permissions"))
  })
}

/// The archives staged for a task, in extraction order.
fn archives(task: queue.Task) -> List(String) {
  case task.git {
    option.Some(_) -> ["source.tar", "git.tar", "dependencies.tar"]
    option.None -> ["source.tar", "dependencies.tar"]
  }
}

/// Stage the Git metadata archive when the task has one. Every member must
/// be a directory or regular file under `.git`, so this archive can write
/// nowhere else in the workspace.
fn stage_git(
  directory: String,
  git: option.Option(queue.Input),
  fetch: inputs.Fetch,
) -> Result(Nil, Fault) {
  // A task that declared no metadata has nothing to stage.
  case git {
    option.None -> Ok(Nil)
    option.Some(input) -> {
      let path = directory <> "/git.tar"
      use Nil <- result.try(
        inputs.stage(fetch, input, path)
        |> result.map_error(transfer_fault),
      )
      use entries <- result.try(
        ffi_worker.entries(path) |> result.map_error(Rejected),
      )
      list.try_each(entries, fn(entry) {
        let refusal = Rejected("unsafe path in Git metadata archive")

        // A link could redirect a later member out of `.git`, so only
        // directories and regular files pass.
        use name <- result.try(case entry {
          ffi_worker.Directory(name) -> Ok(name)
          ffi_worker.Regular(name) -> Ok(name)
          ffi_worker.Symlink(_) -> Error(refusal)
        })

        // A tar directory entry may end with a slash.
        let name = case string.ends_with(name, "/") {
          True -> string.drop_end(name, 1)
          False -> name
        }

        // Every member sits under `.git` with clean path components.
        case string.split(name, "/") {
          [".git", ..rest] ->
            case list.all(rest, fn(p) { p != "" && p != "." && p != ".." }) {
              True -> Ok(Nil)
              False -> Error(refusal)
            }
          _ -> Error(refusal)
        }
      })
    }
  }
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
  flags: List(String),
  start: fn() -> Result(Nil, String),
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
      // The action runs as 65534, and Git refuses a worktree another user owns.
      "o=size="
        <> limits.workspace
        <> "m,nr_inodes=1048576,mode=1777,uid=65534,gid=65534",
      name,
    ],
    "",
  ))
  let mount = "type=volume,src=" <> name <> ",dst=/work,volume-nocopy"
  use _ <- result.try(control(
    list.append(["run", "-d", ..list.append(restrictions, collector_limits)], [
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
    list.append(["create", ..flags], [
      "--name",
      name,
      "--mount",
      mount,
      "--workdir",
      "/work",
      ..list.append(
        list.flat_map(archives(task), fn(file) {
          ["--mount", bind(directory, file)]
        }),
        [
          "--entrypoint",
          "/bin/sh",
          task.image,
          "-c",
          // Unpack each staged archive in order: source, metadata, dependencies.
          "set -eu; "
            <> string.concat(
            list.map(archives(task), fn(file) { "tar xf /" <> file <> "; " }),
          )
            <> "exec \"$@\"",
          "gantry",
          ..task.action.argv
        ],
      )
    ]),
    "",
  ))

  // Start Docker by immutable container ID after validating its response.
  use container <- result.try(
    container_id(identity)
    |> result.replace_error(Unavailable(
      "Docker returned an invalid container ID",
    )),
  )

  // From here the action can run, so a restart must treat it as started.
  use Nil <- result.try(start() |> result.map_error(JournalFault))
  use command <- result.try(start_action(
    name,
    container,
    task.action.timeout * 1000,
  ))
  use log <- result.try(
    spool(with_truncation(command)) |> result.map_error(JournalFault),
  )

  // The runner killed the Docker client at the deadline. The container may
  // still be running, so remove it before reporting the timeout.
  case command.exit {
    // The outcome is decided here, so a failed removal must not hide it. The
    // recorded attempt's cleanup removes the container again.
    ffi_host.TimedOut -> {
      let _ = remove_container(name)
      Ok(queue.Rejected("action exceeded its wall deadline", log))
    }
    ffi_host.Exited(status) -> {
      use state <- result.try(control(
        [
          "inspect",
          "--format",
          "{{.State.Status}} {{.State.ExitCode}}",
          container,
        ],
        "",
      ))

      // Use Docker's exit state to confirm the action exited by itself.
      case string.split(string.trim(state), " ") {
        ["exited", number] -> {
          use code <- result.try(
            int.parse(number)
            |> result.replace_error(Unavailable("invalid Docker exit code")),
          )
          let _ = remove_container(name)
          complete(
            name,
            task.action.outputs,
            log,
            case code {
              0 -> status
              _ -> code
            },
            spool,
          )
        }
        _ -> Ok(queue.Rejected("container failed to exit normally", log))
      }
    }
  }
}

/// What the parked Docker client owner is told to do: `Launch` the client
/// and send its outcome to `reply`, or `Abandon` without starting it.
type Release {
  Launch(reply: process.Subject(Result(ffi_host.Command, String)))
  Abandon
}

/// How long past the action's own deadline Weft waits for the Docker client.
const client_grace = 15_000

/// Run `docker start -a` as a Weft task with a deadline.
///
/// The Docker client lives in a parked owner process that Weft monitors
/// before the client can start. Removing the containers is the task's cancel
/// capability, so every way the task can end early takes one path: the
/// runner's own deadline, Weft's backstop deadline, and the death of the
/// calling slot loop at shutdown. Each removes the container by name, which
/// ends the attached client. The command is `Completed` with `TimedOut` when
/// the runner's deadline fired first, and the log it captured survives.
fn start_action(
  name: String,
  container: String,
  wall: Int,
) -> Result(ffi_host.Command, Fault) {
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let release = process.new_subject()
      process.send(ready, release)

      // A scope that died before launching leaves nobody to cancel. Give up.
      case process.receive(release, client_grace) {
        Ok(Launch(reply)) ->
          process.send(
            reply,
            ffi_worker.docker(
              ["start", "-a", container],
              wall,
              65_536,
              ffi_host.Combined,
            ),
          )
        Ok(Abandon) | Error(Nil) -> Nil
      }
    })

  // The owner reports its release channel as soon as it is parked.
  case process.receive(ready, 5000) {
    Error(Nil) -> Error(Unavailable("could not start the Docker client owner"))
    Ok(release) -> {
      let cancel = fn() {
        process.send(release, Abandon)
        let _ = remove_container(name)
        let _ = remove_container(name <> "-collector")
        Nil
      }
      let begin = fn() {
        let reply = process.new_subject()
        process.send(release, Launch(reply))

        // The deadline below is the backstop. This wait outlasts it, so a
        // client that never returns always resolves as a timeout.
        wait_for_client(reply, wall + client_grace + 5000)
      }
      let outcomes =
        weft.new_prepared([weft.prepared_leaf(owner:, cancel:, begin:)])
        |> weft.deadline(wall + client_grace)
        |> weft.cancel_grace(10_000)
        |> weft.start

      // One task ran, so one outcome says how the Docker client ended.
      case outcomes {
        [weft.Completed(_, command)] -> Ok(command)
        [weft.Failed(_, reason)] -> Error(Unavailable(reason))

        // Weft's backstop fired, so the cancel path already removed the
        // container. Report a timeout without a log.
        [weft.Abandoned(_)] ->
          Ok(ffi_host.Command(ffi_host.TimedOut, <<>>, ffi_host.Complete))
        _ -> Error(Unavailable("Docker client ended abnormally"))
      }
    }
  }
}

/// Wait for the parked owner to report the Docker client's outcome.
fn wait_for_client(
  reply: process.Subject(Result(ffi_host.Command, String)),
  within: Int,
) -> Result(ffi_host.Command, String) {
  // A missing report means the owner died before the client finished.
  case process.receive(reply, within) {
    Ok(outcome) -> outcome
    Error(Nil) -> Error("Docker client did not report")
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
      ffi_host.Stdout,
    )
    |> result.map_error(Unavailable),
  )

  // Require a complete, successful capture before hashing artifact data.
  case command {
    ffi_host.Command(ffi_host.Exited(0), bytes, ffi_host.Complete) ->
      spool(bytes)
      |> result.map_error(JournalFault)
      |> result.map(queue.Artifact(path, _))
    _ -> Error(Rejected(reason))
  }
}

/// Read the container ID from `docker create` output.
///
/// The capture combines both streams so a failure keeps its diagnostic, and
/// Docker writes warnings to stderr before it prints the ID on stdout: a
/// platform mismatch, or a kernel without swap accounting. The ID is the last
/// line, and it must be a full 64-digit hexadecimal ID, so a warning can never
/// be mistaken for one.
///
/// ## Examples
///
/// ```gleam
/// // docker.container_id("WARNING: platform mismatch\n<64 hex digits>\n")
/// ```
pub fn container_id(output: String) -> Result(String, Nil) {
  use last <- result.try(
    string.split(output, "\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" })
    |> list.last,
  )

  // Accept only a full ID, so a trailing warning fails closed.
  case blobs.valid(last) {
    True -> Ok(last)
    False -> Error(Nil)
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
fn with_truncation(command: ffi_host.Command) -> BitArray {
  // Expose when the action wrote more bytes than the log budget.
  case command {
    ffi_host.Command(_, bytes, ffi_host.Clipped) -> <<
      bytes:bits,
      "\n[output truncated]\n":utf8,
    >>
    ffi_host.Command(_, bytes, ffi_host.Complete) -> bytes
  }
}

fn remove_container(name: String) -> Result(String, Fault) {
  control(["rm", "-fv", name], "no such container")
}

/// Require Docker to acknowledge a control request or a known missing resource.
fn control(args: List(String), missing: String) -> Result(String, Fault) {
  use reply <- result.try(
    ffi_worker.docker(args, 30_000, 16_384, ffi_host.Combined)
    |> result.map_error(Unavailable),
  )
  let diagnostic =
    bit_array.to_string(reply.bytes)
    |> result.unwrap("Docker returned non-UTF-8 output")

  // A missing container or volume is already clean.
  case
    reply.exit == ffi_host.Exited(0)
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
  lookup: fn(String) -> Result(String, Nil),
  key: String,
  fallback: String,
  low: Int,
  high: Int,
) -> Result(String, String) {
  let value = lookup(key) |> result.unwrap(fallback)

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
