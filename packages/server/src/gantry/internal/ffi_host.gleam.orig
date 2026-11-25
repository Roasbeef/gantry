//// OTP's port primitives launch named host tools without a shell. The
//// Gleam port module exposes only the type, so the Erlang bridge owns
//// argument conversion, the wall deadline and bounded output collection.
//// One runner serves host tools and the worker's Docker adapter. At the
//// deadline it kills the child by pid and returns the bytes captured so far.
//// The private `halt` binding reports a startup failure to the supervisor.

/// Which environment the child receives. `Inherit` is the VM's environment
/// with the overrides added or replaced. `Clear` is exactly the `KEY=VALUE`
/// settings and nothing else, through `env -i`.
pub type Environment {
  Inherit(overrides: List(#(String, String)))
  Clear(settings: List(String))
}

/// Select which bytes a subprocess may write to the captured stream.
pub type Stream {
  Combined
  Stdout
}

/// Whether the capture retained every byte written by the subprocess.
pub type Capture {
  Complete
  Clipped
}

/// How a subprocess ended.
pub type Exit {
  Exited(status: Int)
  TimedOut
}

/// A bounded stream and how its subprocess ended.
pub type Command {
  Command(exit: Exit, bytes: BitArray, capture: Capture)
}

/// Run a host tool with explicit arguments and environment overrides.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.run("git", ["--version"], [], 5_000)
/// ```
@external(erlang, "gantry_host_ffi", "run")
pub fn run(
  program: String,
  arguments: List(String),
  environment: List(#(String, String)),
  milliseconds: Int,
) -> Result(#(Int, String), String)

/// Run a host tool with a chosen environment and stream, keeping at most
/// `limit` bytes. A command that outlives `milliseconds` is killed and
/// reported as `TimedOut` with the output it had written. `Clear` takes
/// `KEY=VALUE` settings.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.capture("docker", ["version"], Clear([]), Combined, 4096, 30_000)
/// ```
@external(erlang, "gantry_host_ffi", "capture")
pub fn capture(
  program: String,
  arguments: List(String),
  environment: Environment,
  stream: Stream,
  limit: Int,
  milliseconds: Int,
) -> Result(Command, String)

/// Exit with failure when the daemon cannot acquire its startup dependencies.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.exit_failure()
/// ```
pub fn exit_failure() -> Nil {
  halt(1)
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

/// Sync an atomically published file or directory through OTP's filesystem API.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.sync_path("/srv/gantry/objects")
/// ```
@external(erlang, "gantry_host_ffi", "sync_path")
pub fn sync_path(path: String) -> Result(Nil, String)
