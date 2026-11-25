//// Onboarding prepares a private profile, starts Gantry's own services from
//// the installed release, and proves the host can run a Docker build. It
//// replaces the Bash helper with the same profile layout, so a profile made
//// by an earlier release reopens unchanged.
////
//// ## Flow
////
//// Every command first finds its profile with `profile_directory` and takes
//// it with `open_profile`, which refuses a symlinked, shared, or foreign
//// directory and then holds an exclusive lock for the life of this VM, so
//// two onboarding commands cannot interleave writes to one profile.
////
//// `init_local` and `local_start` run `prepare_local`, which mints or
//// reopens the local profile, the fixture repository from `ensure_fixture`,
//// the controller configuration, and the client environment. They start
//// the controller with `start_controller`, which waits until this child,
//// and not some other listener, serves readiness on the profile's port.
//// After `check_docker` and the pinned image, init runs `smoke` against a
//// local worker and stops both services; `local_start` keeps both running
//// until one exits.
////
//// `worker_setup` binds a remote slot to a gateway and pool after
//// `check_remote` confirms authenticated readiness, and `worker_start` runs
//// the worker attached to this terminal.
////
//// ## Children and signals
////
//// Services run under `gantry/cli/service`, which tears down a process
//// group on every normal and failed path. The CLI launcher gives SIGINT,
//// SIGTERM, and SIGHUP their default actions, so a signalled command exits
//// 130, 143, or 129 at once, and `setpriv --pdeathsig TERM` stops each
//// direct child when this VM is gone.

import envoy
import gantry/cli/document.{type Fields}
import gantry/cli/failure.{
  type Failure, Conflict, Missing, Unauthorized, failed, invalid,
}
import gantry/cli/origin
import gantry/cli/profile
import gantry/cli/service.{type Service}
import gantry/internal/ffi_host
import gantry/internal/ffi_worker
import gantry/worker/docker
import gantry_core/protocol
import gantry_core/queue
import gantry_core/request
import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/http
import gleam/http/request as http_request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// The digest-pinned image of the smoke fixture.
pub const local_image =
  "alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"

const fixture_repo = "gantry/fixture"

const smoke_action =
  "{\"name\":\"check\",\"argv\":[\"sh\",\"-ec\",\"printf 'gantry smoke passed\\\\n' > result.txt\"],\"inputs\":[],\"outputs\":[\"result.txt\"],\"timeout\":30}\n"

const fixture_manifest =
  "{
  \"targets\": {\"check\": [\"check\"]},
  \"actions\": [
    {\"name\":\"check\",\"argv\":[\"sh\",\"-ec\",\"printf 'gantry smoke passed\\\\n' > result.txt\"],
     \"inputs\":[],\"outputs\":[\"result.txt\"],\"timeout\":30}
  ]
}
"

const interrupted = "worker interrupted before recording outcome"

/// The effects onboarding needs beyond the filesystem and host tools.
pub type Effects {
  Effects(
    /// Read an environment variable.
    environment: fn(String) -> Result(String, Nil),
    /// Send one HTTP request with a deadline in milliseconds.
    transport: fn(http_request.Request(BitArray), Int) ->
      Result(Response(BitArray), Nil),
    /// Read standard input to end of file.
    read_stdin: fn() -> Result(BitArray, Nil),
    /// Write bytes to standard output.
    write: fn(BitArray) -> Nil,
    /// Write one notice line to standard error.
    report: fn(String) -> Nil,
    /// Read a monotonic clock in milliseconds.
    clock: fn() -> Int,
    /// Wait for a number of milliseconds.
    sleep: fn(Int) -> Nil,
    /// Run the CLI in this VM with environment overrides, returning its
    /// exit status, stdout bytes, and stderr text.
    client: fn(List(String), List(#(String, String))) ->
      #(Int, BitArray, String),
    /// The release's `bin` directory.
    bin: String,
  )
}

/// Where `worker setup` reads the worker token from.
pub type TokenSource {
  FromEnvironment
  FromStdin
}

type Kind {
  LocalKind
  WorkerKind
}

/// Whether the smoke build continues a run saved by an earlier init.
type Resume {
  Resumed
  Fresh
}

/// The local deployment after `prepare_local`.
type Prepared {
  Prepared(
    directory: String,
    local: profile.Local,
    endpoint: String,
    revision: String,
  )
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// Prepare the local profile, run an uncached Docker smoke build through a
/// local controller and worker, and stop both.
///
/// ## Examples
///
/// ```gleam
/// // onboarding.init_local(effects, None)
/// ```
pub fn init_local(
  effects: Effects,
  fields: Option(Fields),
) -> Result(Nil, Failure) {
  use binaries <- result.try(release(effects))
  use directory <- result.try(profile_directory(effects, LocalKind))
  use directory <- result.try(open_profile(directory))
  use prepared <- result.try(prepare_local(effects, directory))
  use _controller <- with_service(start_controller(effects, binaries, prepared))
  use Nil <- result.try(check_docker())
  use Nil <- result.try(ensure_image(directory))
  smoke(effects, binaries, prepared, fields)
}

/// Run the local controller and worker in the foreground until one exits.
///
/// ## Examples
///
/// ```gleam
/// // onboarding.local_start(effects)
/// ```
pub fn local_start(effects: Effects) -> Result(Nil, Failure) {
  use binaries <- result.try(release(effects))
  use directory <- result.try(profile_directory(effects, LocalKind))
  use <- bool.lazy_guard(!is_file(directory <> "/profile.json"), fn() {
    Error(failure.new(
      Missing,
      "missing_profile",
      "Run gantry init --local first.",
    ))
  })
  use directory <- result.try(open_profile(directory))
  use prepared <- result.try(prepare_local(effects, directory))
  use controller <- with_service(start_controller(effects, binaries, prepared))
  use Nil <- result.try(check_docker())
  use Nil <- result.try(ensure_image(directory))
  use worker <- with_service(start_local_worker(binaries, prepared))
  effects.report(
    "Local Gantry is listening at "
    <> prepared.endpoint
    <> ". Logs and client.env are under "
    <> directory
    <> ".",
  )

  // Either service ending ends the deployment. The teardown in
  // `with_service` stops the other one.
  let service.Exit(name, status) = service.await_first([controller, worker])
  Error(failed(
    "service_exited",
    "The local "
      <> name
      <> " exited (status "
      <> int.to_string(status)
      <> "). See the logs under "
      <> directory
      <> ".",
  ))
}

/// Bind one remote worker slot to an HTTPS gateway and pool, after Docker
/// and authenticated gateway readiness check out. Nothing is claimed.
///
/// ## Examples
///
/// ```gleam
/// // onboarding.worker_setup(effects, "https://gantry.example", "linux", FromStdin, None)
/// ```
pub fn worker_setup(
  effects: Effects,
  endpoint: String,
  pool: String,
  source: TokenSource,
  fields: Option(Fields),
) -> Result(Nil, Failure) {
  // One trailing slash is tolerated, as a shell user would type it.
  let endpoint = case string.ends_with(endpoint, "/") {
    True -> string.drop_end(endpoint, 1)
    False -> endpoint
  }

  use Nil <- result.try(remote_origin(endpoint))
  use <- bool.lazy_guard(!request.valid_id(pool), fn() {
    Error(invalid("Use a valid Gantry pool name.", "pool"))
  })
  use supplied <- result.try(supplied_token(effects, source))
  use directory <- result.try(profile_directory(effects, WorkerKind))
  use directory <- result.try(open_profile(directory))
  let file = directory <> "/profile.json"
  let journal = directory <> "/journal"

  // A saved slot keeps its gateway, pool, and token. A new slot needs a
  // token and a directory without an orphaned journal.
  use #(slot, fresh) <- result.try(case exists(file) {
    True -> {
      use saved <- result.try(read_worker(directory))
      use <- bool.lazy_guard(
        profile.endpoint(saved) != endpoint || profile.pool(saved) != pool,
        fn() {
          Error(conflict(
            "profile_conflict",
            "The saved slot is bound to its original gateway and pool.",
          ))
        },
      )
      use <- bool.lazy_guard(
        supplied != "" && supplied != profile.worker_token(saved),
        fn() {
          Error(conflict(
            "profile_conflict",
            "The supplied worker token differs from the saved token.",
          ))
        },
      )
      Ok(#(saved, False))
    }
    False -> {
      use <- bool.lazy_guard(exists(journal), fn() {
        Error(conflict(
          "missing_profile",
          "Recover the profile that belongs to the existing worker journal.",
        ))
      })
      use <- bool.lazy_guard(supplied == "", fn() {
        Error(failure.new(
          Unauthorized,
          "missing_credentials",
          "Set GANTRY_WORKER_TOKEN or supply it with --token-stdin.",
        ))
      })
      use slot <- result.try(
        profile.new_worker(endpoint, pool, supplied, journal)
        |> result.map_error(fn(_) { invalid_token() }),
      )
      Ok(#(slot, True))
    }
  })

  use <- bool.lazy_guard(!profile.credential(profile.worker_token(slot)), fn() {
    Error(invalid_token())
  })
  use Nil <- result.try(check_docker())
  use Nil <- result.try(check_remote(
    effects,
    endpoint,
    profile.worker_token(slot),
  ))

  // The slot is saved only after the host and gateway are both ready.
  use Nil <- result.try(case fresh {
    True ->
      profile.save(
        directory,
        "profile.json",
        json.to_string(profile.encode_worker(slot)),
      )
      |> result.map_error(local_io)
    False -> Ok(Nil)
  })

  emit(
    effects,
    fields,
    document.object([
      #("status", document.text("ready")),
      #("endpoint", document.text(endpoint)),
      #("pool", document.text(pool)),
      #("worker_id", document.text(profile.worker_id(slot))),
      #("profile", document.text(directory)),
      #("journal", document.text(journal)),
      #("worker", document.text("stopped")),
      #("start", document.text("gantry worker start")),
    ]),
  )
}

/// Run the saved remote worker slot attached to this terminal, returning
/// the worker's own exit status.
///
/// ## Examples
///
/// ```gleam
/// // onboarding.worker_start(effects)
/// ```
pub fn worker_start(effects: Effects) -> Result(Int, Failure) {
  use binaries <- result.try(release(effects))
  use directory <- result.try(profile_directory(effects, WorkerKind))
  use <- bool.lazy_guard(!is_file(directory <> "/profile.json"), fn() {
    Error(failure.new(
      Missing,
      "missing_profile",
      "Run gantry worker setup first.",
    ))
  })
  use directory <- result.try(open_profile(directory))
  use slot <- result.try(read_worker(directory))
  use Nil <- result.try(remote_origin(profile.endpoint(slot)))
  use Nil <- result.try(check_docker())
  let set = [
    #("GANTRY_ENDPOINT", profile.endpoint(slot)),
    #("GANTRY_POOL", profile.pool(slot)),
    #("GANTRY_WORKER_ID", profile.worker_id(slot)),
    #("GANTRY_WORKER_DIR", directory <> "/journal"),
    #("GANTRY_WORKER_GUARD", directory),
    #("GANTRY_WORKER_TOKEN", profile.worker_token(slot)),
  ]
  let unset = ["GANTRY_TOKEN", "GANTRY_SUBMIT_TOKEN", "GH_TOKEN"]

  // The worker's logs are its output, so it shares this terminal. The
  // death signal stops it if this VM is signalled.
  ffi_host.run_attached(
    "env",
    list.flatten([
      list.flat_map(unset, fn(key) { ["-u", key] }),
      list.map(set, fn(pair) { pair.0 <> "=" <> pair.1 }),
      ["setpriv", "--pdeathsig", "TERM", binaries.worker],
    ]),
    [],
  )
  |> result.map_error(fn(reason) { failed("worker_unavailable", reason) })
}

// ---------------------------------------------------------------------------
// Release and profile directories
// ---------------------------------------------------------------------------

/// The installed controller and worker launchers.
type Binaries {
  Binaries(controller: String, worker: String)
}

/// Find the controller and worker launchers beside this CLI. Onboarding
/// starts only the installed release, never a source build.
fn release(effects: Effects) -> Result(Binaries, Failure) {
  let binaries =
    Binaries(effects.bin <> "/gantryd", effects.bin <> "/gantry-worker")
  let present =
    list.all([binaries.controller, binaries.worker], fn(path) {
      ffi_host.run("test", ["-x", path], [], 5000) |> result.map(fn(r) { r.0 })
      == Ok(0)
    })
  use <- bool.lazy_guard(!present, fn() {
    Error(failed(
      "missing_release",
      "Run this command with the installed Linux release.",
    ))
  })
  Ok(binaries)
}

/// Find the profile directory under the private state directory.
fn profile_directory(effects: Effects, kind: Kind) -> Result(String, Failure) {
  // An empty XDG_STATE_HOME means unset, as the XDG specification says.
  let state = case effects.environment("XDG_STATE_HOME") {
    Ok(state) if state != "" -> Ok(state)
    _ ->
      effects.environment("HOME")
      |> result.map(fn(home) { home <> "/.local/state" })
  }

  // Profiles live under an absolute path that a shell can quote safely.
  let usable = case state {
    Ok("/" <> _ as state) -> !has_control(state)
    _ -> False
  }

  use <- bool.lazy_guard(!usable, fn() {
    Error(invalid(
      "Set XDG_STATE_HOME to an absolute path without control characters.",
      "XDG_STATE_HOME",
    ))
  })
  let state = result.unwrap(state, "")

  // The local deployment and a remote slot never share a profile.
  Ok(case kind {
    LocalKind -> state <> "/gantry/local"
    WorkerKind -> state <> "/gantry/worker"
  })
}

/// Take the profile directory for this command. The directory must be a
/// real directory owned by this user with mode 0700, and the lock it holds
/// lasts until this VM exits.
fn open_profile(path: String) -> Result(String, Failure) {
  let unsafe = fn(message) { failed("unsafe_profile", message) }
  let linked = simplifile.is_symlink(path) == Ok(True)
  use <- bool.lazy_guard(
    linked || { exists(path) && !is_directory(path) },
    fn() { Error(unsafe("Expected a private directory at " <> path <> ".")) },
  )
  use Nil <- result.try(private_directories(path) |> result.map_error(local_io))

  // Ownership and mode are checked on the directory itself, not a parent.
  use uid <- result.try(current_uid())
  use info <- result.try(
    simplifile.file_info(path)
    |> result.map_error(fn(_) { local_io("cannot inspect " <> path) }),
  )
  use <- bool.lazy_guard(
    info.user_id != uid || int.bitwise_and(info.mode, 0o777) != 0o700,
    fn() {
      Error(unsafe(
        "Set the profile directory to mode 0700 and owned by this user.",
      ))
    },
  )
  use real <- result.try(host_line("realpath", ["--", path]))
  use <- bool.lazy_guard(has_control(real), fn() {
    Error(failure.invalid_input(
      "Use a profile path without control characters.",
    ))
  })
  use Nil <- result.try(
    ffi_worker.lock(real <> "/.setup.lock")
    |> result.map_error(fn(_) {
      conflict("profile_busy", "Another Gantry command is using this profile.")
    }),
  )
  Ok(real)
}

/// Create each missing directory on the way to `path` with mode 0700. A
/// directory that already exists keeps its own mode.
fn private_directories(path: String) -> Result(Nil, String) {
  let parts = string.split(path, "/") |> list.filter(fn(part) { part != "" })
  list.try_fold(parts, "", fn(parent, part) {
    let next = parent <> "/" <> part
    use <- bool.guard(exists(next), Ok(next))
    use Nil <- result.try(
      simplifile.create_directory(next)
      |> result.try(fn(_) { simplifile.set_permissions_octal(next, 0o700) })
      |> result.map_error(fn(_) { "cannot create " <> next }),
    )
    Ok(next)
  })
  |> result.replace(Nil)
}

/// Read this user's numeric ID, which owns every profile file.
fn current_uid() -> Result(Int, Failure) {
  use line <- result.try(host_line("id", ["-u"]))
  int.parse(line)
  |> result.map_error(fn(_) { local_io("cannot read the current user ID") })
}

/// Run a host tool and return its trimmed output, or a local I/O failure.
fn host_line(
  program: String,
  arguments: List(String),
) -> Result(String, Failure) {
  case ffi_host.run(program, arguments, [], 10_000) {
    Ok(#(0, output)) -> Ok(string.trim(output))
    Ok(_) | Error(_) -> Error(local_io("cannot run " <> program))
  }
}

/// Read and validate a saved local profile in its own directory.
fn read_local(directory: String) -> Result(profile.Local, Failure) {
  use text <- result.try(read_private(directory))
  use local <- result.try(
    profile.parse_local(text)
    |> result.map_error(fn(_) { invalid_profile(directory) }),
  )
  use <- bool.lazy_guard(profile.directory(local) != directory, fn() {
    Error(conflict(
      "profile_conflict",
      "The local profile belongs in its original state directory.",
    ))
  })
  Ok(local)
}

/// Read and validate a saved worker profile beside its own journal.
fn read_worker(directory: String) -> Result(profile.Worker, Failure) {
  use text <- result.try(read_private(directory))
  use slot <- result.try(
    profile.parse_worker(text)
    |> result.map_error(fn(_) { invalid_profile(directory) }),
  )
  use <- bool.lazy_guard(profile.journal(slot) != directory <> "/journal", fn() {
    Error(conflict(
      "profile_conflict",
      "The saved slot belongs with its original journal directory.",
    ))
  })
  Ok(slot)
}

/// Read `profile.json` only if it is a private regular file of this user.
fn read_private(directory: String) -> Result(String, Failure) {
  let file = directory <> "/profile.json"
  use uid <- result.try(current_uid())

  // A symlink, a shared mode, or another owner could expose the tokens.
  let private = case simplifile.is_symlink(file), simplifile.file_info(file) {
    Ok(False), Ok(info) ->
      is_file(file)
      && info.user_id == uid
      && int.bitwise_and(info.mode, 0o777) == 0o600
    _, _ -> False
  }

  use <- bool.lazy_guard(!private, fn() {
    Error(failed(
      "unsafe_profile",
      "Expected a private profile file at " <> file <> ".",
    ))
  })
  simplifile.read(file)
  |> result.map_error(fn(_) { invalid_profile(directory) })
}

// ---------------------------------------------------------------------------
// The local deployment
// ---------------------------------------------------------------------------

/// Mint or reopen the local profile and every file the services read.
fn prepare_local(
  effects: Effects,
  directory: String,
) -> Result(Prepared, Failure) {
  let file = directory <> "/profile.json"
  let requested = effects.environment("GANTRY_LOCAL_PORT")

  // A first init mints identities. A fresh profile beside an existing
  // controller or journal would orphan their custody, so it is refused.
  use Nil <- result.try(case exists(file) {
    True -> Ok(Nil)
    False -> {
      use <- bool.lazy_guard(
        exists(directory <> "/controller") || exists(directory <> "/journal"),
        fn() {
          Error(conflict(
            "missing_profile",
            "Recover the profile that belongs to the existing controller and journal.",
          ))
        },
      )
      use port <- result.try(local_port(result.unwrap(requested, "4737")))
      profile.new_local(directory, port)
      |> profile.encode_local
      |> json.to_string
      |> profile.save(directory, "profile.json", _)
      |> result.map_error(local_io)
    }
  })

  use local <- result.try(read_local(directory))
  let stored = int.to_string(profile.port(local))
  use <- bool.lazy_guard(
    result.is_ok(requested) && requested != Ok(stored),
    fn() {
      Error(conflict(
        "profile_conflict",
        "The local profile already uses TCP port " <> stored <> ".",
      ))
    },
  )

  // An established voter whose Ra member file is gone must be restored, not
  // silently replaced by a new single-node queue.
  use <- bool.lazy_guard(
    exists(directory <> "/controller-established")
      && !is_file(directory <> "/controller/queue-ra/member"),
    fn() {
      Error(conflict(
        "missing_controller",
        "The established controller's Ra state is missing. Restore it before restarting.",
      ))
    },
  )

  let endpoint = "http://127.0.0.1:" <> stored
  use revision <- result.try(ensure_fixture(directory))
  use Nil <- result.try(
    write_local_files(directory, local, endpoint) |> result.map_error(local_io),
  )
  Ok(Prepared(directory, local, endpoint, revision))
}

/// Check `GANTRY_LOCAL_PORT`: one to five digits without a leading zero.
fn local_port(text: String) -> Result(Int, Failure) {
  let digits = string.to_graphemes(text)
  let shaped =
    digits != []
    && list.drop(digits, 5) == []
    && !string.starts_with(text, "0")
    && list.all(digits, string.contains("0123456789", _))

  // Port 0 and anything above 65535 cannot be a loopback listener.
  case shaped, int.parse(text) {
    True, Ok(port) if port <= 65_535 -> Ok(port)
    _, _ ->
      Error(invalid(
        "Set GANTRY_LOCAL_PORT to a port between 1 and 65535.",
        "GANTRY_LOCAL_PORT",
      ))
  }
}

/// Write the controller configuration and cookie once, and the client
/// environment every time, through atomic saves.
fn write_local_files(
  directory: String,
  local: profile.Local,
  endpoint: String,
) -> Result(Nil, String) {
  let quoted = fn(text) { json.to_string(json.string(text)) }
  let config =
    string.join(
      [
        "data_dir = " <> quoted(directory <> "/controller"),
        "blob_dir = " <> quoted(directory <> "/blobs"),
        "port = " <> int.to_string(profile.port(local)),
        "",
        "[[repository]]",
        "name = \"gantry/fixture\"",
        "branch = \"main\"",
        "target = \"check\"",
        "pool = \"local\"",
        "image = " <> quoted(local_image),
        "local_remote = " <> quoted(directory <> "/fixture.git"),
      ],
      "\n",
    )
    <> "\n"

  // The configuration is written once, so an operator's edits survive.
  use Nil <- result.try(case exists(directory <> "/controller.toml") {
    True -> Ok(Nil)
    False -> profile.save(directory, "controller.toml", config)
  })

  // The controller's HOME holds its distribution cookie, readable only by
  // this user.
  let home = directory <> "/home"
  use Nil <- result.try(private_directories(home))

  // The cookie is minted once with the profile and kept.
  use Nil <- result.try(case exists(home <> "/.erlang.cookie") {
    True -> Ok(Nil)
    False -> profile.save(home, ".erlang.cookie", profile.cookie(local) <> "\n")
  })

  use Nil <- result.try(
    simplifile.set_permissions_octal(home <> "/.erlang.cookie", 0o400)
    |> result.replace_error("cannot protect the Erlang cookie"),
  )

  // Only the client role is included in this opt-in shell environment.
  profile.save(
    directory,
    "client.env",
    "export GANTRY_URL="
      <> endpoint
      <> "\nexport GANTRY_TOKEN="
      <> profile.agent_token(local)
      <> "\n",
  )
}

/// Run Git with a cleared environment, so no caller setting or system
/// configuration can redirect the fixture repository.
fn fixture_git(
  directory: String,
  arguments: List(String),
) -> Result(String, Failure) {
  let path = envoy.get("PATH") |> result.unwrap("/usr/local/bin:/usr/bin:/bin")
  let reply =
    ffi_host.run(
      "env",
      [
        "-i",
        "PATH=" <> path,
        "HOME=" <> directory <> "/home",
        "GIT_CONFIG_NOSYSTEM=1",
        "git",
        ..arguments
      ],
      [],
      60_000,
    )

  // Git's own message is the useful part of a failure.
  case reply {
    Ok(#(0, output)) -> Ok(string.trim(output))
    Ok(#(_, output)) ->
      Error(local_io("git failed: " <> string.slice(output, 0, 300)))
    Error(reason) -> Error(local_io(reason))
  }
}

/// Create the fixture repository once, staged beside the profile and
/// published with one rename, and return the revision of its main branch.
fn ensure_fixture(directory: String) -> Result(String, Failure) {
  let remote = directory <> "/fixture.git"
  let main = "refs/heads/main^{commit}"
  use <- bool.lazy_guard(is_directory(remote), fn() {
    fixture_git(directory, ["-C", remote, "rev-parse", "--verify", main])
  })
  let staging = directory <> "/.fixture." <> profile.token(8)
  let work = staging <> "/work"
  let bare = staging <> "/remote"
  let built = {
    use Nil <- result.try(
      private_directories(staging) |> result.map_error(local_io),
    )
    use _ <- result.try(
      fixture_git(directory, [
        "init",
        "-q",
        "--bare",
        "--initial-branch=main",
        bare,
      ]),
    )
    use _ <- result.try(
      fixture_git(directory, ["init", "-q", "--initial-branch=main", work]),
    )
    use Nil <- result.try(
      simplifile.write(work <> "/gantry.json", fixture_manifest)
      |> result.map_error(fn(_) { local_io("cannot write the fixture") }),
    )
    use _ <- result.try(
      fixture_git(directory, ["-C", work, "add", "--", "gantry.json"]),
    )
    use _ <- result.try(
      fixture_git(directory, [
        "-C", work, "-c", "user.name=Gantry", "-c",
        "user.email=gantry@example.invalid", "-c", "commit.gpgsign=false",
        "commit", "-qm", "Add Gantry smoke fixture",
      ]),
    )
    use _ <- result.try(
      fixture_git(directory, [
        "-C",
        work,
        "push",
        "-q",
        bare,
        "HEAD:refs/heads/main",
      ]),
    )
    use revision <- result.try(
      fixture_git(directory, ["-C", bare, "rev-parse", "--verify", main]),
    )
    use Nil <- result.try(
      simplifile.rename(bare, remote)
      |> result.try(fn(_) {
        ffi_host.sync_path(directory)
        |> result.replace_error(simplifile.Unknown(""))
      })
      |> result.map_error(fn(_) { local_io("cannot publish the fixture") }),
    )
    Ok(revision)
  }

  // The staging directory never outlives this call.
  let _ = simplifile.delete(staging)
  built
}

/// Start the local controller and wait until this child serves readiness
/// on the profile's port and its Ra member file names the profile's node.
fn start_controller(
  effects: Effects,
  binaries: Binaries,
  prepared: Prepared,
) -> Result(Service, Failure) {
  let directory = prepared.directory
  let local = prepared.local
  let port = profile.port(local)
  use <- bool.lazy_guard(ffi_host.tcp_open("127.0.0.1", port, 1000), fn() {
    Error(conflict(
      "port_in_use",
      "Another process is listening at " <> prepared.endpoint <> ".",
    ))
  })
  let node = profile.node(local)

  // The controller sees only its own role tokens and none of the caller's
  // Git or Erlang settings.
  let git =
    envoy.all()
    |> dict.keys
    |> list.filter(string.starts_with(_, "GIT_"))
  let spec =
    service.Spec(
      name: "controller",
      program: binaries.controller,
      arguments: [],
      set: [
        #("HOME", directory <> "/home"),
        #("ERL_EPMD_ADDRESS", "127.0.0.1"),
        #(
          "ERL_FLAGS",
          "+S 2:2 -name "
            <> node
            <> " -start_epmd false -erl_epmd_port 0 -kernel inet_dist_use_interface '{127,0,0,1}'",
        ),
        #("GANTRY_CONFIG", directory <> "/controller.toml"),
        #("GANTRY_TOKEN", profile.agent_token(local)),
        #("GANTRY_WORKER_TOKEN", profile.local_worker_token(local)),
        #("GANTRY_SUBMIT_TOKEN", profile.submit_token(local)),
      ],
      unset: list.append(git, ["GH_TOKEN", "ERL_AFLAGS", "ERL_ZFLAGS"]),
      directory:,
      log: directory <> "/controller.log",
    )

  use controller <- result.try(
    service.start(spec)
    |> result.map_error(failed("controller_unavailable", _)),
  )
  let deadline = effects.clock() + 45_000
  let unavailable = fn() {
    service.stop(controller)
    Error(failed(
      "controller_unavailable",
      "Controller did not become ready. See " <> directory <> "/controller.log.",
    ))
  }
  use <- bool.lazy_guard(
    !await_ready(effects, controller, prepared, deadline),
    unavailable,
  )

  // Readiness on the right port must come from the profile's own voter.
  let member =
    simplifile.read(directory <> "/controller/queue-ra/member")
    |> result.map(string.trim)
  use <- bool.lazy_guard(member != Ok(node), fn() {
    service.stop(controller)
    Error(failed(
      "controller_unavailable",
      "The ready controller does not match the local profile.",
    ))
  })

  // The first ready start marks the voter as established, so a later start
  // refuses to replace lost Ra state with a fresh queue.
  use Nil <- result.try(case exists(directory <> "/controller-established") {
    True -> Ok(Nil)
    False ->
      profile.save(directory, "controller-established", node <> "\n")
      |> result.map_error(fn(reason) {
        service.stop(controller)
        local_io(reason)
      })
  })

  Ok(controller)
}

/// Poll until the controller logged its own bind, answers readiness, and
/// is still running, or until the deadline or its exit.
fn await_ready(
  effects: Effects,
  controller: Service,
  prepared: Prepared,
  deadline: Int,
) -> Bool {
  let bound =
    simplifile.read(prepared.directory <> "/controller.log")
    |> result.map(fn(log) {
      list.contains(
        string.split(log, "\n"),
        "Listening on " <> prepared.endpoint,
      )
    })
    == Ok(True)
  let ready = bound && answers_ready(effects, prepared.endpoint)
  let alive = service.running(controller)

  // Each condition alone can be satisfied by another process.
  case ready && alive, alive && effects.clock() < deadline {
    True, _ -> True
    False, True -> {
      effects.sleep(250)
      await_ready(effects, controller, prepared, deadline)
    }
    False, False -> False
  }
}

/// Whether the endpoint answers `/ready` with a ready status.
fn answers_ready(effects: Effects, endpoint: String) -> Bool {
  let reply = {
    use outgoing <- result.try(http_request.to(endpoint <> "/ready"))
    effects.transport(http_request.set_body(outgoing, <<>>), 6000)
  }

  // Readiness needs both the status and the body.
  case reply {
    Ok(reply) if reply.status == 200 -> ready_body(reply.body)
    Ok(_) | Error(Nil) -> False
  }
}

fn ready_body(body: BitArray) -> Bool {
  bit_array.to_string(body)
  |> result.try(document.parse)
  |> result.try(document.string(_, "status"))
  == Ok("ready")
}

/// Start the local worker slot against the local controller, with the
/// profile as its custody guard.
fn start_local_worker(
  binaries: Binaries,
  prepared: Prepared,
) -> Result(Service, Failure) {
  let directory = prepared.directory
  let local = prepared.local
  service.start(service.Spec(
    name: "worker",
    program: binaries.worker,
    arguments: [],
    set: [
      #("ERL_FLAGS", "+S 2:2"),
      #("GANTRY_ENDPOINT", prepared.endpoint),
      #("GANTRY_POOL", "local"),
      #("GANTRY_WORKER_ID", profile.local_worker_id(local)),
      #("GANTRY_WORKER_TOKEN", profile.local_worker_token(local)),
      #("GANTRY_WORKER_DIR", directory <> "/journal"),
      #("GANTRY_WORKER_GUARD", directory),
    ],
    unset: [
      "GANTRY_TOKEN",
      "GANTRY_SUBMIT_TOKEN",
      "GH_TOKEN",
      "ERL_AFLAGS",
      "ERL_ZFLAGS",
    ],
    directory:,
    log: directory <> "/worker.log",
  ))
  |> result.map_error(failed("worker_unavailable", _))
}

/// Run `body` with a started service and stop it afterwards, whatever the
/// body returns.
fn with_service(
  started: Result(Service, Failure),
  body: fn(Service) -> Result(a, Failure),
) -> Result(a, Failure) {
  use running <- result.try(started)
  let outcome = body(running)
  service.stop(running)
  outcome
}

// ---------------------------------------------------------------------------
// Docker and the smoke build
// ---------------------------------------------------------------------------

/// Require a reachable Docker daemon before any build is attempted.
fn check_docker() -> Result(Nil, Failure) {
  docker.probe()
  |> result.map_error(fn(_) {
    failed(
      "docker_unavailable",
      "Install Docker and verify this user can run docker info. Then rerun the command.",
    )
  })
}

/// Make the pinned fixture image local, keeping a failed pull's output in
/// the profile's `docker.log`.
fn ensure_image(directory: String) -> Result(Nil, Failure) {
  docker.prepare_image(local_image)
  |> result.map_error(fn(output) {
    let _ = profile.save(directory, "docker.log", output)
    failed(
      "image_unavailable",
      "Could not pull the pinned fixture image. See "
        <> directory
        <> "/docker.log.",
    )
  })
}

/// Run, or resume, the smoke build and verify its artifact bytes. A smoke
/// run that already passed is verified again without a new build.
fn smoke(
  effects: Effects,
  binaries: Binaries,
  prepared: Prepared,
  fields: Option(Fields),
) -> Result(Nil, Failure) {
  let directory = prepared.directory
  let local = prepared.local
  let run_cli = effects.client
  let overrides = [
    #("GANTRY_SUBMIT_TOKEN", ""),
    #("GANTRY_WORKER_TOKEN", ""),
    #("GANTRY_URL", prepared.endpoint),
    #("GANTRY_TOKEN", profile.agent_token(local)),
    #("GANTRY_WATCH_SECONDS", "90"),
  ]
  let client = fn(arguments) { run_cli(arguments, overrides) }
  let log = fn(text) { profile.save(directory, "smoke.log", text) }

  // A saved run ID is reused unless it ended badly, so a rerun neither
  // repeats a passed build nor resubmits a different one.
  use #(run, passed, resumed) <- result.try(
    case simplifile.read(directory <> "/smoke-run") {
      Error(_) -> Ok(#(None, None, Fresh))
      Ok(saved) -> {
        let saved = string.trim(saved)
        let #(status, out, err) = client(["status", saved])
        let _ = log(err)
        saved_smoke(saved, status, decode_run(out), directory)
      }
    },
  )

  // Only a run that has not passed needs the worker and a new attempt.
  use #(run, result) <- result.try(case passed {
    Some(result) -> Ok(#(option.unwrap(run, ""), result))
    None -> {
      use Nil <- result.try(
        profile.save(directory, "smoke-action.json", smoke_action)
        |> result.map_error(local_io),
      )
      use _worker <- with_service(start_local_worker(binaries, prepared))
      smoke_attempt(client, log, prepared, run, resumed, 1)
    }
  })

  // The proof must name the fixture's output, fetched and compared byte
  // for byte, so a cached or partial result cannot pass.
  use digest <- result.try(
    passed_digest(result)
    |> result.map_error(fn(_) {
      failed(
        "smoke_failed",
        "Smoke run " <> run <> " did not produce a fresh Docker result.",
      )
    }),
  )
  let #(status, bytes, err) = client(["blob", digest])
  let _ = log(err)
  let _ = simplifile.write_bits(directory <> "/smoke-result.txt", bytes)
  use <- bool.lazy_guard(status != 0, fn() {
    Error(failed(
      "smoke_failed",
      "Could not retrieve the smoke artifact. See "
        <> directory
        <> "/smoke.log.",
    ))
  })
  use <- bool.lazy_guard(bytes != <<"gantry smoke passed\n":utf8>>, fn() {
    Error(failed("smoke_failed", "Smoke artifact bytes did not match."))
  })

  emit(
    effects,
    fields,
    document.object([
      #("status", document.text("passed")),
      #("endpoint", document.text(prepared.endpoint)),
      #("node", document.text(profile.node(local))),
      #("worker_id", document.text(profile.local_worker_id(local))),
      #("pool", document.text("local")),
      #("run_id", document.text(run)),
      #("artifact", document.text(digest)),
      #("profile", document.text(directory)),
      #("services", document.text("stopped")),
      #("start", document.text("gantry local start")),
      #("client_env", document.text(directory <> "/client.env")),
    ]),
  )
}

/// Decide how to continue a saved smoke run from its status lookup: a
/// passed run is verified again, a failed or blocked one is replaced, an
/// unknown one is admitted under its saved ID, and anything else resumes.
fn saved_smoke(
  saved: String,
  status: Int,
  found: Result(queue.Run, Nil),
  directory: String,
) -> Result(#(Option(String), Option(queue.Run), Resume), Failure) {
  let phase = result.map(found, queue.phase)

  // Exit 4 means the controller lost the run, so it is admitted again.
  case status, phase, found {
    0, Ok(queue.PhaseFailed), _ | 0, Ok(queue.PhaseBlocked), _ ->
      Ok(#(None, None, Fresh))
    0, Ok(queue.PhasePassed), Ok(run) -> Ok(#(Some(saved), Some(run), Resumed))
    0, _, _ -> Ok(#(Some(saved), None, Resumed))
    4, _, _ -> Ok(#(Some(saved), None, Fresh))
    _, _, _ ->
      Error(failed(
        "smoke_status",
        "Could not look up the smoke run. See " <> directory <> "/smoke.log.",
      ))
  }
}

/// Admit and watch one smoke run. Recovery can fail an old attempt after
/// cleaning up its container, so a resumed run that failed that way is
/// retried once under a new ID.
fn smoke_attempt(
  client: fn(List(String)) -> #(Int, BitArray, String),
  log: fn(String) -> Result(Nil, String),
  prepared: Prepared,
  run: Option(String),
  resumed: Resume,
  attempt: Int,
) -> Result(#(String, queue.Run), Failure) {
  let directory = prepared.directory

  // A new attempt saves its ID before admission, so an interrupted init
  // resumes the same run instead of admitting a second one.
  use run <- result.try(case run {
    Some(run) -> Ok(run)
    None -> {
      let run = "smoke-" <> profile.token(8)
      profile.save(directory, "smoke-run", run <> "\n")
      |> result.map_error(local_io)
      |> result.replace(run)
    }
  })

  let #(status, out, err) =
    client([
      "run",
      run,
      fixture_repo,
      prepared.revision,
      "check",
      directory <> "/smoke-action.json",
    ])
  let _ = simplifile.write_bits(directory <> "/smoke-admission.json", out)
  let _ = log(err)
  use <- bool.lazy_guard(status != 0, fn() {
    Error(failed(
      "smoke_admission",
      "Could not admit the smoke run. See " <> directory <> "/smoke.log.",
    ))
  })

  // The watch stream's last state decides the attempt.
  let #(status, out, err) = client(["watch", run])
  let _ = simplifile.write_bits(directory <> "/smoke-watch.jsonl", out)
  let _ = log(err)
  let last =
    bit_array.to_string(out)
    |> result.try(fn(text) {
      string.split(string.trim(text), "\n") |> list.last
    })
    |> result.map(bit_array.from_string)
    |> result.try(decode_run)
  let fail = fn() {
    Error(failed(
      "smoke_failed",
      "Smoke run "
        <> run
        <> " did not pass. See "
        <> directory
        <> "/smoke-watch.jsonl and "
        <> directory
        <> "/worker.log.",
    ))
  }

  // Only a resumed run's first attempt may be replaced, and only when the
  // worker fenced it as interrupted.
  case status, last {
    0, Ok(run_state) -> Ok(#(run, run_state))
    _, Ok(run_state) if resumed == Resumed && attempt == 1 ->
      case was_interrupted(run_state) {
        True -> smoke_attempt(client, log, prepared, None, resumed, 2)
        False -> fail()
      }
    _, _ -> fail()
  }
}

/// Whether recovery fenced a run's attempt as interrupted, the one failure
/// a resumed smoke build may retry.
fn was_interrupted(run: queue.Run) -> Bool {
  queue.phase(run) == queue.PhaseFailed
  && list.any(run.work, fn(work) {
    case work.step {
      queue.Failed(queue.Reported(reason), _) -> reason == interrupted
      queue.Failed(queue.LeaseExpired(_), _)
      | queue.Pending(_)
      | queue.Active(_)
      | queue.Passed(_)
      | queue.Reused(_)
      | queue.Skipped -> False
    }
  })
}

/// The digest of `result.txt` from the first action of a passed run.
fn passed_digest(run: queue.Run) -> Result(String, Nil) {
  use <- bool.guard(queue.phase(run) != queue.PhasePassed, Error(Nil))
  use first <- result.try(list.first(run.work))

  // A reused proof came from a cache, which a smoke build must not trust.
  case first.step {
    queue.Passed(proof) ->
      list.find(queue.proof_files(proof), fn(file) { file.path == "result.txt" })
      |> result.map(fn(file) { file.digest })
    queue.Pending(_)
    | queue.Active(_)
    | queue.Reused(_)
    | queue.Failed(_, _)
    | queue.Skipped -> Error(Nil)
  }
}

/// Decode one run printed by the CLI.
fn decode_run(bytes: BitArray) -> Result(queue.Run, Nil) {
  bit_array.to_string(bytes)
  |> result.try(fn(text) {
    json.parse(string.trim(text), protocol.run_decoder())
    |> result.replace_error(Nil)
  })
}

// ---------------------------------------------------------------------------
// Remote slots
// ---------------------------------------------------------------------------

/// Check an HTTPS gateway origin without a path, query, or credentials.
///
/// ## Examples
///
/// ```gleam
/// assert onboarding.remote_origin("https://gantry.example") == Ok(Nil)
/// ```
pub fn remote_origin(endpoint: String) -> Result(Nil, Failure) {
  // Only an HTTPS origin may carry a worker token.
  let parsed = case endpoint {
    "https://" <> authority -> origin.parse_authority(authority)
    _ -> Error(Nil)
  }

  // A gateway is an HTTPS origin. Its port, when given, must be in range.
  case parsed {
    Ok(None) -> Ok(Nil)
    Ok(Some(port)) if port >= 1 && port <= 65_535 -> Ok(Nil)
    Ok(Some(_)) ->
      Error(invalid("Use a gateway port between 1 and 65535.", "endpoint"))
    Error(Nil) ->
      Error(invalid(
        "Use an HTTPS gateway origin without a path, query, or credentials.",
        "endpoint",
      ))
  }
}

/// Read the worker token from the environment, or one line from stdin.
fn supplied_token(
  effects: Effects,
  source: TokenSource,
) -> Result(String, Failure) {
  let environment =
    effects.environment("GANTRY_WORKER_TOKEN") |> result.unwrap("")

  // Stdin carries exactly one line, so a stray second token is an error.
  case source {
    FromEnvironment -> Ok(environment)
    FromStdin -> {
      let text =
        effects.read_stdin()
        |> result.try(bit_array.to_string)
        |> result.unwrap("")

      // One trailing newline ends the line.
      let line = case string.ends_with(text, "\n") {
        True -> string.drop_end(text, 1)
        False -> text
      }

      use <- bool.lazy_guard(string.contains(line, "\n"), fn() {
        Error(failure.new(
          Unauthorized,
          "invalid_credentials",
          "Provide one worker token on stdin.",
        ))
      })
      use <- bool.lazy_guard(line == "", fn() {
        Error(failure.new(
          Unauthorized,
          "missing_credentials",
          "Provide a worker token on stdin.",
        ))
      })
      Ok(line)
    }
  }
}

/// Confirm the gateway forwards authenticated worker readiness to a current
/// controller, without claiming work.
fn check_remote(
  effects: Effects,
  endpoint: String,
  token: String,
) -> Result(Nil, Failure) {
  let reply = {
    use outgoing <- result.try(http_request.to(endpoint <> "/v1/worker/ready"))
    outgoing
    |> http_request.set_method(http.Get)
    |> http_request.set_header("authorization", "Bearer " <> token)
    |> http_request.set_body(<<>>)
    |> effects.transport(10_000)
  }

  // Authorization, routing, and readiness failures need different fixes.
  case reply {
    Ok(reply) ->
      case reply.status, ready_body(reply.body) {
        200, True -> Ok(Nil)
        401, _ | 403, _ ->
          Error(failure.new(
            Unauthorized,
            "auth_failed",
            "The gateway rejected the worker token.",
          ))
        404, _ ->
          Error(failure.new(
            Missing,
            "worker_readiness_missing",
            "The gateway must forward the worker readiness route to a current controller.",
          ))
        status, _ ->
          Error(failed(
            "worker_readiness_failed",
            "The gateway did not confirm worker readiness (result: "
              <> case status {
              200 -> "invalid"
              _ -> int.to_string(status)
            }
              <> ").",
          ))
      }
    Error(Nil) ->
      Error(failed(
        "worker_readiness_failed",
        "The gateway did not confirm worker readiness (result: transport).",
      ))
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Print an onboarding result as one JSON line, projected by `--fields`.
fn emit(
  effects: Effects,
  fields: Option(Fields),
  result: document.Document,
) -> Result(Nil, Failure) {
  // A projection keeps only the requested paths.
  let printed = case fields {
    None -> result
    Some(fields) -> document.project(result, fields)
  }

  effects.write(bit_array.from_string(document.to_string(printed) <> "\n"))
  Ok(Nil)
}

fn exists(path: String) -> Bool {
  simplifile.is_symlink(path) == Ok(True)
  || simplifile.is_file(path) == Ok(True)
  || simplifile.is_directory(path) == Ok(True)
}

fn is_file(path: String) -> Bool {
  simplifile.is_file(path) == Ok(True)
}

fn is_directory(path: String) -> Bool {
  simplifile.is_directory(path) == Ok(True)
}

fn has_control(text: String) -> Bool {
  list.any(string.to_utf_codepoints(text), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    n < 32 || n == 127
  })
}

fn conflict(code: String, message: String) -> Failure {
  failure.new(Conflict, code, message)
}

fn invalid_profile(directory: String) -> Failure {
  failed(
    "invalid_profile",
    "Could not validate " <> directory <> "/profile.json.",
  )
}

/// A worker token too short, or with characters a header cannot carry.
fn invalid_token() -> Failure {
  failure.new(
    Unauthorized,
    "invalid_credentials",
    "Use a worker token of at least 32 printable ASCII characters without spaces.",
  )
}

/// An unexpected filesystem or host-tool failure, with its reason.
fn local_io(reason: String) -> Failure {
  failed(
    "local_io",
    "Onboarding could not finish ("
      <> reason
      <> "). Check the private profile and its logs, then rerun the command.",
  )
}
