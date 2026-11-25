//// A private onboarding profile binds one local deployment or one remote
//// worker slot to its identity and credentials. The profile outlives every
//// process it configures, so it is decoded totally and written atomically.
////
//// ## Flow
////
//// `new_local` and `new_worker` mint a profile with fresh identities from
//// `token`. `parse_local` and `parse_worker` decode a saved file, closed
//// over the version and kind, and reject any field that `identity` or
//// `credential` would not accept. `encode_local` and `encode_worker` write
//// the same shape the Bash helper wrote, so a profile created by an earlier
//// release reopens unchanged. `save` publishes any file the profile owns by
//// writing a staged copy, syncing it, renaming it into place, and syncing
//// the directory, so a crash leaves the old file or the new one.
////
//// | Value | Invariant |
//// | --- | --- |
//// | `Local` | Node is `gantry_<16 hex>@127.0.0.1`, port is 1..65535, worker ID is an identifier, and all four credentials are at least 32 printable ASCII characters. |
//// | `Worker` | Pool and worker ID are identifiers and the worker token is a credential. |

import gantry/internal/ffi_host
import gantry_core/request
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// A single-host deployment: one loopback controller and one worker.
pub opaque type Local {
  Local(
    node: String,
    worker_id: String,
    directory: String,
    port: Int,
    agent_token: String,
    worker_token: String,
    submit_token: String,
    cookie: String,
  )
}

/// A remote worker slot bound to one gateway, pool, and journal.
pub opaque type Worker {
  Worker(
    endpoint: String,
    pool: String,
    worker_id: String,
    worker_token: String,
    journal: String,
  )
}

/// Mint a local profile with fresh identities and credentials.
///
/// ## Examples
///
/// ```gleam
/// // profile.new_local("/home/me/.local/state/gantry/local", 4737)
/// ```
pub fn new_local(directory: String, port: Int) -> Local {
  let identity = token(8)
  Local(
    node: "gantry_" <> identity <> "@127.0.0.1",
    worker_id: "local-" <> identity,
    directory:,
    port:,
    agent_token: token(32),
    worker_token: token(32),
    submit_token: token(32),
    cookie: token(20),
  )
}

/// Bind a new remote slot to a gateway, pool, and supplied worker token.
///
/// ## Examples
///
/// ```gleam
/// // profile.new_worker("https://gantry.example", "linux", supplied, journal)
/// ```
pub fn new_worker(
  endpoint: String,
  pool: String,
  worker_token: String,
  journal: String,
) -> Result(Worker, Nil) {
  use <- bool.guard(
    !request.valid_id(pool) || !credential(worker_token),
    Error(Nil),
  )
  Ok(Worker(endpoint, pool, "worker-" <> token(16), worker_token, journal))
}

/// Lowercase hex from a cryptographically strong source.
///
/// ## Examples
///
/// ```gleam
/// // profile.token(8)
/// // -> "9f2c41aa0b7e33d1"
/// ```
pub fn token(bytes: Int) -> String {
  crypto.strong_random_bytes(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Check a worker token or role credential: at least 32 printable ASCII
/// characters, without spaces.
///
/// ## Examples
///
/// ```gleam
/// assert profile.credential("short") == False
/// ```
pub fn credential(value: String) -> Bool {
  string.drop_start(value, 31) != ""
  && list.all(string.to_utf_codepoints(value), fn(point) {
    let n = string.utf_codepoint_to_int(point)
    n >= 33 && n <= 126
  })
}

/// Check a saved worker ID or pool name.
fn identity(value: String) -> Bool {
  request.valid_id(value)
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Decode a saved local profile.
///
/// ## Examples
///
/// ```gleam
/// assert profile.parse_local("{}") == Error(Nil)
/// ```
pub fn parse_local(text: String) -> Result(Local, Nil) {
  let decoder = {
    use Nil <- decode.field("version", exactly(decode.int, 1))
    use Nil <- decode.field("kind", exactly(decode.string, "local"))
    use node <- decode.field("node", decode.string)
    use worker_id <- decode.field("worker_id", decode.string)
    use directory <- decode.field("directory", decode.string)
    use port <- decode.field("port", decode.int)
    use agent_token <- decode.field("agent_token", decode.string)
    use worker_token <- decode.field("worker_token", decode.string)
    use submit_token <- decode.field("submit_token", decode.string)
    use cookie <- decode.field("cookie", decode.string)
    decode.success(Local(
      node,
      worker_id,
      directory,
      port,
      agent_token,
      worker_token,
      submit_token,
      cookie,
    ))
  }
  use local <- result.try(
    json.parse(text, decoder) |> result.replace_error(Nil),
  )
  let valid =
    local_node(local.node)
    && identity(local.worker_id)
    && local.port >= 1
    && local.port <= 65_535
    && list.all(
      [local.agent_token, local.worker_token, local.submit_token, local.cookie],
      credential,
    )
  use <- bool.guard(!valid, Error(Nil))
  Ok(local)
}

/// Check a loopback node name minted by `new_local`.
fn local_node(node: String) -> Bool {
  case node {
    "gantry_" <> rest ->
      case string.split_once(rest, "@") {
        Ok(#(hex, "127.0.0.1")) ->
          string.byte_size(hex) == 16
          && list.all(string.to_graphemes(hex), string.contains(
            "0123456789abcdef",
            _,
          ))
        Ok(_) | Error(Nil) -> False
      }
    _ -> False
  }
}

/// Decode a saved remote worker profile.
///
/// ## Examples
///
/// ```gleam
/// assert profile.parse_worker("[]") == Error(Nil)
/// ```
pub fn parse_worker(text: String) -> Result(Worker, Nil) {
  let decoder = {
    use Nil <- decode.field("version", exactly(decode.int, 1))
    use Nil <- decode.field("kind", exactly(decode.string, "worker"))
    use endpoint <- decode.field("endpoint", decode.string)
    use pool <- decode.field("pool", decode.string)
    use worker_id <- decode.field("worker_id", decode.string)
    use worker_token <- decode.field("worker_token", decode.string)
    use journal <- decode.field("journal", decode.string)
    decode.success(Worker(endpoint, pool, worker_id, worker_token, journal))
  }
  use worker <- result.try(
    json.parse(text, decoder) |> result.replace_error(Nil),
  )
  let valid =
    identity(worker.pool)
    && identity(worker.worker_id)
    && credential(worker.worker_token)
  use <- bool.guard(!valid, Error(Nil))
  Ok(worker)
}

/// Decode a field that must hold one exact value.
fn exactly(decoder: decode.Decoder(a), expected: a) -> decode.Decoder(Nil) {
  use value <- decode.then(decoder)

  // A version or kind this release does not know is not a profile.
  case value == expected {
    True -> decode.success(Nil)
    False -> decode.failure(Nil, "expected value")
  }
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Encode a local profile in the saved shape.
///
/// ## Examples
///
/// ```gleam
/// // profile.encode_local(local) |> json.to_string
/// ```
pub fn encode_local(local: Local) -> json.Json {
  json.object([
    #("version", json.int(1)),
    #("kind", json.string("local")),
    #("node", json.string(local.node)),
    #("worker_id", json.string(local.worker_id)),
    #("directory", json.string(local.directory)),
    #("port", json.int(local.port)),
    #("agent_token", json.string(local.agent_token)),
    #("worker_token", json.string(local.worker_token)),
    #("submit_token", json.string(local.submit_token)),
    #("cookie", json.string(local.cookie)),
  ])
}

/// Encode a worker profile in the saved shape.
///
/// ## Examples
///
/// ```gleam
/// // profile.encode_worker(worker) |> json.to_string
/// ```
pub fn encode_worker(worker: Worker) -> json.Json {
  json.object([
    #("version", json.int(1)),
    #("kind", json.string("worker")),
    #("endpoint", json.string(worker.endpoint)),
    #("pool", json.string(worker.pool)),
    #("worker_id", json.string(worker.worker_id)),
    #("worker_token", json.string(worker.worker_token)),
    #("journal", json.string(worker.journal)),
  ])
}

// ---------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------

/// The loopback Erlang node name of the local controller.
pub fn node(local: Local) -> String {
  local.node
}

/// The worker ID of the local slot.
pub fn local_worker_id(local: Local) -> String {
  local.worker_id
}

/// The directory the local profile was created in.
pub fn directory(local: Local) -> String {
  local.directory
}

/// The loopback TCP port of the local controller.
pub fn port(local: Local) -> Int {
  local.port
}

/// The build-agent credential.
pub fn agent_token(local: Local) -> String {
  local.agent_token
}

/// The worker credential of the local deployment.
pub fn local_worker_token(local: Local) -> String {
  local.worker_token
}

/// The submit credential.
pub fn submit_token(local: Local) -> String {
  local.submit_token
}

/// The Erlang distribution cookie of the local controller.
pub fn cookie(local: Local) -> String {
  local.cookie
}

/// The gateway origin of a remote slot.
pub fn endpoint(worker: Worker) -> String {
  worker.endpoint
}

/// The pool of a remote slot.
pub fn pool(worker: Worker) -> String {
  worker.pool
}

/// The worker ID of a remote slot.
pub fn worker_id(worker: Worker) -> String {
  worker.worker_id
}

/// The saved worker token of a remote slot.
pub fn worker_token(worker: Worker) -> String {
  worker.worker_token
}

/// The journal directory a remote slot belongs with.
pub fn journal(worker: Worker) -> String {
  worker.journal
}

// ---------------------------------------------------------------------------
// Durable writes
// ---------------------------------------------------------------------------

/// Publish a private file atomically. The staged copy is written, made
/// private, and synced before the rename, and the directory is synced
/// after it, so a reader sees the old file or the complete new one and a
/// crash cannot leave a torn file at `path`.
///
/// ## Examples
///
/// ```gleam
/// // profile.save(dir, "profile.json", text)
/// ```
pub fn save(
  directory: String,
  name: String,
  contents: String,
) -> Result(Nil, String) {
  let path = directory <> "/" <> name
  let staged = path <> ".tmp." <> token(8)
  let fault = fn(_) { "cannot save " <> path }
  let published = {
    use Nil <- result.try(
      simplifile.write(staged, contents) |> result.map_error(fault),
    )
    use Nil <- result.try(
      simplifile.set_permissions_octal(staged, 0o600)
      |> result.map_error(fault),
    )
    use Nil <- result.try(ffi_host.sync_path(staged))
    use Nil <- result.try(
      simplifile.rename(staged, path) |> result.map_error(fault),
    )
    ffi_host.sync_path(directory)
  }

  // A failed publication must not leave its staged copy behind.
  case published {
    Ok(Nil) -> Ok(Nil)
    Error(reason) -> {
      let _ = simplifile.delete(staged)
      Error(reason)
    }
  }
}
