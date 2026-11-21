//// The operator fixes repository, ref and toolchain authority. Agents
//// select registered work within that policy.

import gantry/internal/ffi_host
import gantry_core/job
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tom

/// The Git remote shape controls how source PR metadata is read.
pub type Provider {
  GitHub
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

/// Controller storage, listener and operator-registered projects.
pub type Config {
  Config(
    data: String,
    blobs: String,
    port: Int,
    seed: String,
    repositories: Dict(String, Repository),
    agent_token: String,
    worker_token: String,
    submit_token: String,
    github_token: String,
  )
}

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
  use worker <- result.try(secret("GANTRY_WORKER_TOKEN"))
  use submit <- result.try(secret("GANTRY_SUBMIT_TOKEN"))

  use contents <- result.try(
    simplifile.read(path) |> result.replace_error("cannot read GANTRY_CONFIG"),
  )
  use value <- result.try(
    tom.parse_to_dynamic(contents)
    |> result.replace_error("invalid configuration TOML"),
  )
  use #(data, blobs, port, seed, projects) <- result.try(
    decode.run(value, config_decoder())
    |> result.replace_error("invalid controller configuration"),
  )
  use repositories <- result.try(list.try_map(projects, validate_repository))

  use Nil <- result.try(validate_controller(
    data,
    blobs,
    port,
    agent,
    worker,
    submit,
  ))
  let github = ffi_host.getenv("GH_TOKEN") |> result.unwrap("")
  Ok(Config(
    data,
    blobs,
    port,
    seed,
    dict.from_list(repositories),
    agent,
    worker,
    submit,
    github,
  ))
}

/// Read a required runtime setting.
///
/// ## Examples
///
/// ```gleam
/// // config.env("GANTRY_CONFIG")
/// ```
pub fn env(key: String) -> Result(String, String) {
  ffi_host.getenv(key) |> result.map_error(fn(_) { key <> " is required" })
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
///
/// ## Examples
///
/// ```gleam
/// // validate_controller(data, blobs, port, agent, worker, submit)
/// ```
fn validate_controller(
  data: String,
  blobs: String,
  port: Int,
  agent: String,
  worker: String,
  submit: String,
) -> Result(Nil, String) {
  case
    string.starts_with(data, "/")
    && string.starts_with(blobs, "/")
    && port > 0
    && port <= 65_535
    && agent != worker
    && submit != agent
    && submit != worker
  {
    True -> Ok(Nil)
    False ->
      Error(
        "need absolute storage roots, a valid port and distinct role tokens",
      )
  }
}

/// Describe the configuration and its registered repositories.
///
/// ## Examples
///
/// ```gleam
/// // decode.run(toml, config_decoder())
/// ```
fn config_decoder() {
  let project = {
    use name <- decode.field("name", decode.string)
    use branch <- decode.optional_field("branch", "main", decode.string)
    use target <- decode.optional_field("target", "check", decode.string)
    use pool <- decode.optional_field("pool", "default", decode.string)

    use image <- decode.field("image", decode.string)
    use local <- decode.optional_field("local_remote", "", decode.string)
    decode.success(#(name, branch, target, pool, image, local))
  }
  use data <- decode.field("data_dir", decode.string)
  use blobs <- decode.field("blob_dir", decode.string)
  use port <- decode.optional_field("port", 4737, decode.int)
  use seed <- decode.optional_field("seed", "", decode.string)

  use projects <- decode.field("repository", decode.list(project))
  decode.success(#(data, blobs, port, seed, projects))
}

/// Validate a Git remote and its pinned executor image.
///
/// ## Examples
///
/// ```gleam
/// // validate_repository(project)
/// ```
fn validate_repository(
  row: #(String, String, String, String, String, String),
) -> Result(#(String, Repository), String) {
  let #(name, branch, target, pool, image, local) = row
  let name = string.lowercase(name)

  // An explicit local path selects the operator's local Git repository.
  let provider = case local {
    "" -> GitHub
    dir -> Local(dir)
  }

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
