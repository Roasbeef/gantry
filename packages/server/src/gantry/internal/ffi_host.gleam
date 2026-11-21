//// OTP's port primitives launch named host tools without a shell. The
//// Gleam port module exposes only the type, so the Erlang bridge owns
//// argument conversion, the wall deadline and bounded output collection.

/// Read an environment variable without making it part of the configuration file.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.getenv("GANTRY_TOKEN")
/// ```
@external(erlang, "gantry_host_ffi", "getenv")
pub fn getenv(name: String) -> Result(String, Nil)

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
@external(erlang, "gantry_host_ffi", "exit_failure")
pub fn exit_failure() -> Nil

/// Sync an atomically published file or directory through OTP's filesystem API.
///
/// ## Examples
///
/// ```gleam
/// // ffi_host.sync_path("/srv/gantry/objects")
/// ```
@external(erlang, "gantry_host_ffi", "sync_path")
pub fn sync_path(path: String) -> Result(Nil, String)
