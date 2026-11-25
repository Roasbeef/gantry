//// The operator fixes repository, ref and toolchain authority. Agents
//// select registered work within that policy.
////
//// ## Worker credentials
////
//// Each worker has its own token, and `controller.toml` lists the worker's
//// ID with the SHA-256 digest of that token. The controller never stores a
//// worker token. A request's bearer token selects the worker identity
//// through `worker_for`, and the API rejects a body that names any other
//// worker. Agent and submit tokens stay role tokens in the environment.
////
//// ```toml
//// [[worker]]
//// id = "linux-01"
//// token_sha256 = "<sha256 of the token, as 64 lowercase hex digits>"
//// ```
////
//// A configuration without any `[[worker]]` entry is the earlier format,
//// where every worker shared `GANTRY_WORKER_TOKEN`. It fails to load.

import envoy
import gantry/blobs
import gantry_core/job
import gantry_core/request
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tom

/// The operator chooses which GitHub branch policy to apply to a repository.
pub type GitHubTarget {
  DefaultBranch
  RegisteredBranch
}

/// The Git remote shape controls how source PR metadata is read.
pub type Provider {
  GitHub(target: GitHubTarget)
  Local(path: String)
}

/// Trusted execution and submission profile for a project.
pub type Repository {
  Repository(
    name: String,
    provider: Provider,
    branch: String,
    target: String,
    pool: String,
    image: String,
  )
}

/// One registered worker: its identity and the digest of its token.
pub type Worker {
  Worker(id: String, token_sha256: String)
}

/// Controller storage, listener and operator-registered projects.
pub type Config {
  Config(
    data: String,
    blobs: String,
    port: Int,
    seed: String,
    repositories: Dict(String, Repository),
    workers: List(Worker),
    agent_token: String,
    submit_token: String,
    github_token: String,
  )
}

/// The role credentials and GitHub token read from the environment.
pub type Secrets {
  Secrets(agent: String, submit: String, github: String)
}

/// The failure to report when a configuration uses the earlier shared worker
/// token.
const legacy_format =
  "controller.toml must list each worker as [[worker]] with id and token_sha256. The shared GANTRY_WORKER_TOKEN is no longer accepted. Hash each worker's token with sha256 and see docs/running.md"

/// Read configuration and role credentials.
///
/// ## Examples
///
/// ```gleam
/// // config.load()
/// ```
pub fn load() -> Result(Config, String) {
  use path <- result.try(env("GANTRY_CONFIG"))
  use agent <- result.try(secret("GANTRY_TOKEN"))
  use submit <- result.try(secret("GANTRY_SUBMIT_TOKEN"))
  use contents <- result.try(
    simplifile.read(path) |> result.replace_error("cannot read GANTRY_CONFIG"),
  )
  let github = envoy.get("GH_TOKEN") |> result.unwrap("")
  parse(contents, Secrets(agent, submit, github))
}

/// Decode a configuration document and check it against the role secrets.
///
/// ## Examples
///
/// ```gleam
/// assert config.parse("", secrets) == Error("invalid configuration TOML")
/// ```
pub fn parse(contents: String, secrets: Secrets) -> Result(Config, String) {
  use value <- result.try(
    tom.parse_to_dynamic(contents)
    |> result.replace_error("invalid configuration TOML"),
  )
  use #(data, blobs, port, seed, projects, workers) <- result.try(
    decode.run(value, config_decoder())
    |> result.replace_error("invalid controller configuration"),
  )
  use repositories <- result.try(list.try_map(projects, validate_repository))
  use workers <- result.try(validate_workers(workers, secrets))
  use Nil <- result.try(validate_controller(data, blobs, port, secrets))
  Ok(Config(
    data,
    blobs,
    port,
    seed,
    dict.from_list(repositories),
    workers,
    secrets.agent,
    secrets.submit,
    secrets.github,
  ))
}

/// The SHA-256 of a worker token, as the 64 lowercase hex digits that
/// `controller.toml` records.
///
/// ## Examples
///
/// ```gleam
/// assert string.length(config.token_digest("secret")) == 64
/// ```
pub fn token_digest(token: String) -> String {
  blobs.digest(bit_array.from_string(token))
}

/// The worker whose registered token digest matches a presented bearer
/// token. Every entry is compared, in constant time, so the time taken does
/// not reveal how many digests matched or where.
///
/// ## Examples
///
/// ```gleam
/// // config.worker_for(cfg, "bearer-token") == Ok("linux-01")
/// ```
pub fn worker_for(cfg: Config, token: String) -> Result(String, Nil) {
  let presented = bit_array.from_string(token_digest(token))
  list.fold(cfg.workers, Error(Nil), fn(found, worker) {
    case
      crypto.secure_compare(
        presented,
        bit_array.from_string(worker.token_sha256),
      )
    {
      True -> Ok(worker.id)
      False -> found
    }
  })
}

/// Read a required runtime setting.
///
/// ## Examples
///
/// ```gleam
/// // config.env("GANTRY_CONFIG")
/// ```
pub fn env(key: String) -> Result(String, String) {
  envoy.get(key) |> result.map_error(fn(_) { key <> " is required" })
}

/// Load a credential and enforce the configured token length floor.
fn secret(key: String) -> Result(String, String) {
  use value <- result.try(env(key))

  // Reject short credentials before exposing any authenticated endpoints.
  case string.byte_size(value) >= 32 {
    True -> Ok(value)
    False -> Error("Gantry tokens must have at least 32 bytes")
  }
}

/// Hold credentials and writable roots to the controller's local policy.
fn validate_controller(
  data: String,
  blobs: String,
  port: Int,
  secrets: Secrets,
) -> Result(Nil, String) {
  case
    string.starts_with(data, "/")
    && string.starts_with(blobs, "/")
    && port > 0
    && port <= 65_535
    && secrets.submit != secrets.agent
  {
    True -> Ok(Nil)
    False ->
      Error(
        "need absolute storage roots, a valid port and distinct role tokens",
      )
  }
}

/// Check the worker table: at least one worker, valid unique identifiers,
/// valid unique digests, and no digest that is also a role token's.
fn validate_workers(
  rows: List(#(String, String)),
  secrets: Secrets,
) -> Result(List(Worker), String) {
  let workers = list.map(rows, fn(row) { Worker(row.0, row.1) })
  let ids = list.map(workers, fn(worker) { worker.id })
  let digests = list.map(workers, fn(worker) { worker.token_sha256 })
  let roles = [token_digest(secrets.agent), token_digest(secrets.submit)]
  case workers {
    [] -> Error(legacy_format)
    _ ->
      case
        list.all(ids, request.valid_id)
        && list.all(digests, blobs.valid)
        && list.unique(ids) == ids
        && list.unique(digests) == digests
        && !list.any(roles, list.contains(digests, _))
      {
        True -> Ok(workers)
        False ->
          Error(
            "each [[worker]] needs a unique id and a unique token_sha256 of 64 lowercase hex digits that is not a role token's digest",
          )
      }
  }
}

/// Describe the configuration and its registered repositories.
fn config_decoder() {
  let project = {
    use name <- decode.field("name", decode.string)
    use branch <- decode.optional_field("branch", "main", decode.string)
    use target <- decode.optional_field("target", "check", decode.string)
    use pool <- decode.optional_field("pool", "default", decode.string)

    use image <- decode.field("image", decode.string)
    use local <- decode.optional_field("local_remote", "", decode.string)
    use github_target <- decode.optional_field(
      "github_target",
      "default",
      decode.string,
    )
    decode.success(#(name, branch, target, pool, image, local, github_target))
  }
  let worker = {
    use id <- decode.field("id", decode.string)
    use digest <- decode.field("token_sha256", decode.string)
    decode.success(#(id, digest))
  }
  use data <- decode.field("data_dir", decode.string)
  use blobs <- decode.field("blob_dir", decode.string)
  use port <- decode.optional_field("port", 4737, decode.int)
  use seed <- decode.optional_field("seed", "", decode.string)

  use projects <- decode.field("repository", decode.list(project))
  use workers <- decode.optional_field("worker", [], decode.list(worker))
  decode.success(#(data, blobs, port, seed, projects, workers))
}

/// Validate a Git remote and its pinned executor image.
///
/// ## Examples
///
/// ```gleam
/// // validate_repository(project)
/// ```
fn validate_repository(
  row: #(String, String, String, String, String, String, String),
) -> Result(#(String, Repository), String) {
  let #(name, branch, target, pool, image, local, github_target) = row
  let name = string.lowercase(name)

  // Only an explicit GitHub configuration can authorize a non-default branch.
  use provider <- result.try(case local, github_target {
    "", "default" -> Ok(GitHub(DefaultBranch))
    "", "registered" -> Ok(GitHub(RegisteredBranch))
    "", _ -> Error("github_target must be default or registered")
    path, "default" -> Ok(Local(path))
    _, _ -> Error("github_target is only supported for GitHub repositories")
  })

  // Archive and push operands come from the operator's registered policy.
  case
    job.valid_repository(name)
    && branch != ""
    && target != ""
    && pool != ""
    && !string.starts_with(image, "-")
    && string.contains(image, "@sha256:")
    && { local == "" || string.starts_with(local, "/") }
  {
    True -> Ok(#(name, Repository(name, provider, branch, target, pool, image)))
    False -> Error("invalid repository settings or unpinned OCI image")
  }
}
