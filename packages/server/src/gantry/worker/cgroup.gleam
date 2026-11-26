//// Per-attempt cgroups that give a `userns` action a cgroup v2 subtree of
//// its own, so a nested sandbox such as Loom's jail can set its own memory
//// and process ceilings.
////
//// The operator names a base cgroup that the worker's user owns, inside the
//// user manager's delegated subtree. For each `userns` attempt the worker
//// makes a child of the base, writes the slot's limits on it, and lets the
//// action's uid create and enter children below it. The container is placed
//// inside that child (`--cgroup-parent`), which only a Docker daemon on the
//// `cgroupfs` driver allows, so the action can move its own processes into
//// cgroups it creates. Processes moved there leave the container's cgroup,
//// which is why the slot's limits sit on the attempt cgroup that contains
//// both.
////
//// ## Flow
////
//// ```text
//// boot:    from_lookup -> prepare
//// attempt: create -> flags -> (docker create, start, wait) -> remove
//// ```
////
//// | Step      | Effect                                         | Invariant kept                                  |
//// | --------- | ---------------------------------------------- | ----------------------------------------------- |
//// | `prepare` | check the base, enable its child controllers   | the base is a process-empty cgroup v2 directory |
//// | `create`  | mkdir the attempt cgroup, write limits, open it | the action can manage children, not its limits  |
//// | `remove`  | rmdir the attempt cgroup depth first           | a removed attempt leaves no cgroup behind       |
////
//// See `docs/design-notes/sandbox-profiles.md`.

import gantry/internal/ffi_worker
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// Where cgroup v2 is mounted on a host and inside a container.
const root = "/sys/fs/cgroup"

/// The controllers the attempt cgroup must hand to the action's children.
const required = ["memory", "pids"]

/// The worker-owned cgroup under which each attempt gets its own child.
pub opaque type Base {
  Base(path: String)
}

/// The slot's limits, written on each attempt cgroup.
pub type Limits {
  Limits(memory_mib: Int, pids: Int, cpus: Int)
}

/// Read `GANTRY_WORKER_USERNS_CGROUP` through a lookup function. An unset
/// or empty value means the worker gives `userns` actions no cgroup.
///
/// ## Examples
///
/// ```gleam
/// assert cgroup.from_lookup(fn(_) { Error(Nil) }) == Ok(None)
/// ```
pub fn from_lookup(
  lookup: fn(String) -> Result(String, Nil),
) -> Result(Option(Base), String) {
  case lookup("GANTRY_WORKER_USERNS_CGROUP") {
    Error(Nil) | Ok("") -> Ok(None)
    Ok(path) ->
      case valid_path(path) {
        True -> Ok(Some(Base(path)))
        False ->
          Error(
            "GANTRY_WORKER_USERNS_CGROUP must be an absolute path below /sys/fs/cgroup using letters, digits, '.', '_', '-', '@' and '/'",
          )
      }
  }
}

/// The base cgroup's absolute path.
///
/// ## Examples
///
/// ```gleam
/// // cgroup.path(base)
/// ```
pub fn path(base: Base) -> String {
  base.path
}

/// Check the base at startup and enable the controllers its children need.
/// The base must be a cgroup v2 directory with `memory` and `pids`, and it
/// must hold no processes, because cgroup v2 forbids a cgroup with members
/// from distributing controllers. `cpu` is enabled when the base has it.
///
/// ## Examples
///
/// ```gleam
/// // cgroup.prepare(base)
/// ```
pub fn prepare(base: Base) -> Result(Nil, String) {
  use controllers <- result.try(read_words(base.path, "cgroup.controllers"))
  use procs <- result.try(read_words(base.path, "cgroup.procs"))
  use enabled <- result.try(
    check(controllers, procs)
    |> result.map_error(fn(reason) { base.path <> " " <> reason }),
  )
  enable(base.path, enabled)
}

/// Decide whether a base with these controllers and member processes can
/// serve attempts, and which controllers to enable for its children. A base
/// that cannot pass on memory and pids, or that holds processes, cannot give
/// an attempt the ceilings Loom's jail needs.
///
/// ## Examples
///
/// ```gleam
/// assert cgroup.check(["cpu", "memory", "pids"], [])
///   == Ok(["cpu", "memory", "pids"])
/// ```
pub fn check(
  controllers: List(String),
  procs: List(String),
) -> Result(List(String), String) {
  let missing =
    list.filter(required, fn(name) { !list.contains(controllers, name) })

  // Missing controllers are named first: they are the operator's fix.
  case missing, procs {
    [], [] -> Ok(wanted(controllers))
    [_, ..], _ ->
      Error(
        "is not delegated the "
        <> string.join(missing, " and ")
        <> " controller(s); delegate them to the worker's user manager",
      )
    [], [_, ..] ->
      Error(
        "holds processes, so it cannot enable controllers for its children; name an empty cgroup",
      )
  }
}

/// Make the attempt cgroup for one attempt, write the slot's limits on it,
/// and let the action's uid create and enter its children. The limits
/// files stay the worker's, so the action cannot raise them.
///
/// ## Examples
///
/// ```gleam
/// // cgroup.create(base, "gantry-ab12", cgroup.Limits(768, 4096, 2))
/// ```
pub fn create(
  base: Base,
  name: String,
  limits: Limits,
) -> Result(String, String) {
  let attempt = base.path <> "/" <> name
  use controllers <- result.try(read_words(base.path, "cgroup.subtree_control"))
  use Nil <- result.try(
    simplifile.create_directory(attempt)
    |> result.map_error(fn(_) { "cannot create cgroup " <> attempt }),
  )
  use Nil <- result.try(enable(attempt, wanted(controllers)))
  use Nil <- result.try(
    list.try_each(limit_files(limits, controllers), fn(pair) {
      write(attempt, pair.0, pair.1)
    }),
  )

  // The directory and the files that create and move processes are opened
  // to the action's uid. The limit files keep the worker's 0644.
  [
    #(attempt, 0o777),
    #(attempt <> "/cgroup.procs", 0o666),
    #(attempt <> "/cgroup.threads", 0o666),
    #(attempt <> "/cgroup.subtree_control", 0o666),
  ]
  |> list.try_each(fn(pair) {
    simplifile.set_permissions_octal(pair.0, pair.1)
    |> result.map_error(fn(_) { "cannot change the mode of " <> pair.0 })
  })
  |> result.replace(attempt)
}

/// The Docker flags that place an action inside its attempt cgroup and give
/// it a writable view of that cgroup. The container shares the host's
/// cgroup namespace, so the paths it reads in `/proc/self/cgroup` match the
/// mounted directory. `GANTRY_CGROUP_BASE` names it, and `LOOM_CGROUP_BASE`
/// is the name Loom's jail reads.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(
///   cgroup.flags("/sys/fs/cgroup/u/gantry-1"),
///   "--cgroup-parent=/u/gantry-1",
/// )
/// ```
pub fn flags(attempt: String) -> List(String) {
  [
    "--cgroup-parent=" <> string.drop_start(attempt, string.length(root)),
    "--cgroupns=host",
    "--mount",
    "type=bind,src=" <> attempt <> ",dst=" <> attempt,
    "--env",
    "GANTRY_CGROUP_BASE=" <> attempt,
    "--env",
    "LOOM_CGROUP_BASE=" <> attempt,
  ]
}

/// Remove an attempt cgroup and everything the action left below it, depth
/// first. A missing cgroup is already removed. A cgroup that still holds
/// processes refuses with `ebusy`, and the caller retries.
///
/// ## Examples
///
/// ```gleam
/// // cgroup.remove(base, "gantry-ab12")
/// ```
pub fn remove(base: Base, name: String) -> Result(Nil, String) {
  remove_tree(base.path <> "/" <> name)
}

/// Remove one cgroup after its child cgroups.
fn remove_tree(path: String) -> Result(Nil, String) {
  // A directory that is not there, or not a directory, needs nothing.
  case simplifile.is_directory(path) {
    Ok(False) | Error(_) -> Ok(Nil)
    Ok(True) -> {
      use entries <- result.try(
        simplifile.read_directory(path)
        |> result.map_error(fn(_) { "cannot list cgroup " <> path }),
      )
      use Nil <- result.try(
        list.try_each(entries, fn(entry) {
          let child = path <> "/" <> entry

          // Only child cgroups are directories. Interface files go with rmdir.
          case simplifile.is_directory(child) {
            Ok(True) -> remove_tree(child)
            Ok(False) | Error(_) -> Ok(Nil)
          }
        }),
      )
      ffi_worker.remove_directory(path)
      |> result.map_error(fn(reason) {
        "cannot remove cgroup " <> path <> " (" <> reason <> ")"
      })
    }
  }
}

/// The controllers to hand to children, out of those available: the
/// required pair, and `cpu` when it is there.
fn wanted(available: List(String)) -> List(String) {
  list.filter(["cpu", ..required], fn(name) { list.contains(available, name) })
}

/// The limit files written on an attempt cgroup, for the controllers its
/// parent hands it: memory and pids always, and a CPU quota when the cpu
/// controller is delegated.
///
/// ## Examples
///
/// ```gleam
/// assert cgroup.limit_files(cgroup.Limits(1, 64, 2), ["memory", "pids"])
///   == [#("memory.max", "1048576"), #("pids.max", "64")]
/// ```
pub fn limit_files(
  limits: Limits,
  controllers: List(String),
) -> List(#(String, String)) {
  let memory = #("memory.max", int.to_string(limits.memory_mib * 1_048_576))
  let pids = #("pids.max", int.to_string(limits.pids))
  let cpu = #("cpu.max", int.to_string(limits.cpus * 100_000) <> " 100000")

  // A CPU ceiling needs the cpu controller, which older delegation lacks.
  case list.contains(controllers, "cpu") {
    True -> [memory, pids, cpu]
    False -> [memory, pids]
  }
}

/// Enable controllers for a cgroup's children.
fn enable(path: String, controllers: List(String)) -> Result(Nil, String) {
  let line = list.map(controllers, fn(name) { "+" <> name }) |> string.join(" ")
  write(path, "cgroup.subtree_control", line)
}

/// Write one cgroup interface file.
fn write(path: String, file: String, value: String) -> Result(Nil, String) {
  simplifile.write(path <> "/" <> file, value)
  |> result.map_error(fn(_) { "cannot write " <> path <> "/" <> file })
}

/// The whitespace-separated words of a cgroup interface file, such as the
/// controller names in `cgroup.controllers` or the PIDs in `cgroup.procs`.
fn read_words(path: String, file: String) -> Result(List(String), String) {
  simplifile.read(path <> "/" <> file)
  |> result.map(string.split(_, " "))
  |> result.map(list.flat_map(_, string.split(_, "\n")))
  |> result.map(list.filter(_, fn(word) { word != "" }))
  |> result.map_error(fn(_) { "cannot read " <> path <> "/" <> file })
}

/// A base path is absolute, below the cgroup mount, free of `..`, and made
/// of characters that cannot end a Docker `--mount` option.
fn valid_path(path: String) -> Bool {
  string.starts_with(path, root <> "/")
  && !string.contains(path, "..")
  && !string.ends_with(path, "/")
  && list.all(string.to_utf_codepoints(path), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    { n >= 48 && n <= 57 }
    || { n >= 65 && n <= 90 }
    || { n >= 97 && n <= 122 }
    || n == 45
    || n == 46
    || n == 47
    || n == 64
    || n == 95
  })
}
