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
