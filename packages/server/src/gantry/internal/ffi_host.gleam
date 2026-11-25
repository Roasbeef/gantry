//// OTP's port primitives launch named host tools without a shell. The
//// Gleam port module exposes only the type, so the Erlang bridge owns
//// argument conversion, the wall deadline and bounded output collection.
////
//// The CLI needs four host primitives that no Gleam binding provides. An
//// exit status: `erlang:halt/2` with a flush is the only way to end the VM
//// with a chosen code. Binary-safe standard output: `gleam/io` writes text
//// through an io server whose encoding a launcher may set to UTF-8, which
//// would rewrite blob bytes above 127, so `write_stdout` switches the
//// device to latin1 and writes bytes verbatim. Standard input to end of
//// file, for `--json -`, through `file:read/2` on the same device. And a
//// child attached to the caller's terminal, through a `nouse_stdio` port,
//// for a command whose output is the child's own logs.
////
//// Onboarding supervises long-running children. `open_service` owns one
//// child through a port whose output arrives as messages, `service_pid`
//// names its process group, and `service_event` turns a raw port message
//// into a typed event for the owning actor's selector. Each child of
//// `erl_child_setup` starts in a session of its own, so its pid is its
//// process group ID. `tcp_open` asks `gen_tcp` whether a port already has a
//// listener. `default_terminate` gives SIGTERM back to the operating system
//// so a signalled CLI exits 143 without running `init:stop`.

import gleam/dynamic.{type Dynamic}

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

/// Exit with failure when the daemon cannot acquire its startup dependencies.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.exit_failure()
/// ```
pub fn exit_failure() -> Nil {
  exit(1)
}

/// Flush pending port output and stop the VM with a status code.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.exit(2)
/// ```
@external(erlang, "gantry_host_ffi", "halt")
pub fn exit(status: Int) -> Nil

/// Write bytes to standard output without any character re-encoding. The
/// write has reached the port when this returns.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.write_stdout(<<0, 255>>)
/// ```
@external(erlang, "gantry_host_ffi", "write_stdout")
pub fn write_stdout(bytes: BitArray) -> Result(Nil, Nil)

/// Read standard input to end of file as bytes.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.read_stdin()
/// ```
@external(erlang, "gantry_host_ffi", "read_stdin")
pub fn read_stdin() -> Result(BitArray, Nil)

/// Run a host program attached to the VM's standard streams and wait for
/// its exit status. The child receives exactly the given environment
/// overrides on top of the VM's own environment.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.run_attached("bash", ["helper"], [])
/// ```
@external(erlang, "gantry_host_ffi", "run_attached")
pub fn run_attached(
  program: String,
  arguments: List(String),
  environment: List(#(String, String)),
) -> Result(Int, String)

/// Sync an atomically published file or directory through OTP's filesystem API.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.sync_path("/srv/gantry/objects")
/// ```
@external(erlang, "gantry_host_ffi", "sync_path")
pub fn sync_path(path: String) -> Result(Nil, String)

/// An OTP port that owns one supervised child process.
pub type ServicePort

/// Output or exit reported by a supervised child.
pub type ServiceEvent {
  Output(bytes: BitArray)
  Exited(status: Int)
}

/// Start a child in `directory` with its output captured as port messages.
/// The calling process owns the port and receives its events.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.open_service("env", ["-u", "GH_TOKEN", "gantryd"], [], dir)
/// ```
@external(erlang, "gantry_host_ffi", "open_service")
pub fn open_service(
  program: String,
  arguments: List(String),
  environment: List(#(String, String)),
  directory: String,
) -> Result(ServicePort, String)

/// The operating system pid of a supervised child, which is also its
/// process group ID.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.service_pid(port)
/// ```
@external(erlang, "gantry_host_ffi", "service_pid")
pub fn service_pid(port: ServicePort) -> Result(Int, Nil)

/// Read a port message received by the owning process.
///
/// ## Examples
///
/// ```gleam
/// // process.select_other(selector, ffi_host.service_event)
/// ```
@external(erlang, "gantry_host_ffi", "service_event")
pub fn service_event(message: Dynamic) -> Result(ServiceEvent, Nil)

/// Whether a TCP listener accepts a connection within the deadline.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.tcp_open("127.0.0.1", 4737, 1000)
/// ```
@external(erlang, "gantry_host_ffi", "tcp_open")
pub fn tcp_open(host: String, port: Int, milliseconds: Int) -> Bool

/// Let SIGTERM end the VM with the operating system's default action.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.default_terminate()
/// ```
@external(erlang, "gantry_host_ffi", "default_terminate")
pub fn default_terminate() -> Nil
