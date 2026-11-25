//// The loopback API authenticates build, worker, and submission authority.
//// Large objects travel outside the replicated queue snapshot.

import gantry/api
import gantry/blobs
import gantry/config.{type Config}
import gantry/fault.{type Fault}
import gantry/store
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/http.{Get, Post, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import mist.{type Connection, type ResponseData}

type Reply =
  Response(ResponseData)

/// Route one request using its role and declared body size.
///
/// ## Examples
///
/// ```gleam
/// // mist.new(fn(request) { http_api.handle(config, request) })
/// ```
pub fn handle(cfg: Config, req: Request(Connection)) -> Reply {
  // The method and path select the operation and its required credential.
  case req.method, request.path_segments(req) {
    Get, ["health"] -> ready_reply("ok")
    Get, ["ready"] -> ready_reply("ready")
    Get, ["v1", "worker", "ready"] -> {
      use _ <- worker(req, cfg)
      ready_reply("ready")
    }
    Post, ["v1", "runs"] -> {
      use <- authorized(req, cfg.agent_token)
      with_json(req, fn(body) { api.build(cfg, body, api.Run) |> respond })
    }
    Post, ["v1", "plans"] -> {
      use <- authorized(req, cfg.agent_token)
      with_json(req, fn(body) { api.build(cfg, body, api.Plan) |> respond })
    }
    Post, ["v1", "submits"] -> {
      use <- authorized(req, cfg.submit_token)
      with_json(req, fn(body) { api.group(cfg, body) |> respond })
    }
    Get, ["v1", "runs", id] -> {
      use <- authorized_either(req, cfg.agent_token, cfg.submit_token)
      api.get(id) |> respond
    }
    Post, ["v1", "claims"] -> {
      use identity <- worker(req, cfg)
      with_json(req, fn(body) { claim_reply(identity, body) })
    }
    Post, ["v1", "results"] -> {
      use identity <- worker(req, cfg)
      with_json(req, fn(body) { api.finish(cfg, identity, body) |> respond })
    }
    Put, ["v1", "blobs", id] -> {
      use _ <- worker(req, cfg)
      use body <- with_body(req, blobs.limit)
      upload(cfg.blobs, id, body)
    }
    Get, ["v1", "blobs", id] -> {
      use <- agent_or_worker(req, cfg)
      download(cfg.blobs, id)
    }
    _, _ -> error(404, "route not found")
  }
}

/// Confirm quorum access for gateway and worker probes without claiming work
/// or transferring the queue snapshot. `/health` shares this check, because a
/// controller that cannot reach its quorum cannot serve any request.
fn ready_reply(status: String) -> Reply {
  respond(
    store.ready()
    |> result.map_error(fn(_) { fault.Unavailable("queue quorum unavailable") })
    |> result.map(fn(_) { json.object([#("status", json.string(status))]) }),
  )
}

/// Separate empty polls from errors and reserved work.
///
/// ## Examples
///
/// ```gleam
/// // claim_reply("worker-1", body)
/// ```
fn claim_reply(identity: String, body: String) -> Reply {
  case api.claim(identity, body) {
    Ok(None) ->
      response.new(204)
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(<<>>)))
    Ok(Some(assignment)) -> json_reply(200, assignment)
    Error(reason) -> fault_reply(reason)
  }
}

/// Authenticate before reading a request body.
///
/// ## Examples
///
/// ```gleam
/// // use <- authorized(request, token)
/// ```
fn authorized(
  req: Request(Connection),
  token: String,
  then: fn() -> Reply,
) -> Reply {
  case accepts(req, token) {
    True -> then()
    False -> fault_reply(fault.Unauthorized("authentication required"))
  }
}

/// Allow two roles to read shared state.
///
/// ## Examples
///
/// ```gleam
/// // use <- authorized_either(request, agent_token, submit_token)
/// ```
fn authorized_either(
  req: Request(Connection),
  first: String,
  second: String,
  then: fn() -> Reply,
) -> Reply {
  case accepts(req, first) || accepts(req, second) {
    True -> then()
    False -> fault_reply(fault.Unauthorized("authentication required"))
  }
}

/// Authenticate a worker and hand its registered ID to the handler. The
/// identity comes from the credential alone, so no field a client sends can
/// choose it.
///
/// ## Examples
///
/// ```gleam
/// // use identity <- worker(request, config)
/// ```
fn worker(
  req: Request(Connection),
  cfg: Config,
  then: fn(String) -> Reply,
) -> Reply {
  case bearer(req) |> result.try(config.worker_for(cfg, _)) {
    Ok(identity) -> then(identity)
    Error(Nil) -> fault_reply(fault.Unauthorized("authentication required"))
  }
}

/// Allow the build agent or any registered worker to read shared artifacts.
///
/// ## Examples
///
/// ```gleam
/// // use <- agent_or_worker(request, config)
/// ```
fn agent_or_worker(
  req: Request(Connection),
  cfg: Config,
  then: fn() -> Reply,
) -> Reply {
  let worker = bearer(req) |> result.try(config.worker_for(cfg, _))

  // The agent token or any registered worker credential may read.
  case accepts(req, cfg.agent_token), worker {
    True, _ | False, Ok(_) -> then()
    False, Error(Nil) ->
      fault_reply(fault.Unauthorized("authentication required"))
  }
}

/// The bearer token a request presents, if any.
fn bearer(req: Request(Connection)) -> Result(String, Nil) {
  case request.get_header(req, "authorization") {
    Ok("Bearer " <> supplied) -> Ok(supplied)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// Compare a bearer credential with the required role's token in constant time.
fn accepts(req: Request(Connection), token: String) -> Bool {
  case bearer(req) {
    Ok(supplied) ->
      crypto.secure_compare(
        bit_array.from_string(supplied),
        bit_array.from_string(token),
      )
    Error(Nil) -> False
  }
}

/// Limit JSON before decoding the body as UTF-8.
///
/// ## Examples
///
/// ```gleam
/// // use body <- with_json(request)
/// ```
fn with_json(req: Request(Connection), then: fn(String) -> Reply) -> Reply {
  use body <- with_body(req, 262_144)

  // Only valid UTF-8 can reach the JSON decoder.
  case bit_array.to_string(body) {
    Ok(text) -> then(text)
    Error(Nil) -> error(400, "expected UTF-8 JSON")
  }
}

/// Require a bounded Content-Length before Mist reads the body.
///
/// ## Examples
///
/// ```gleam
/// // use bytes <- with_body(request, 1024)
/// ```
fn with_body(
  req: Request(Connection),
  maximum: Int,
  then: fn(BitArray) -> Reply,
) -> Reply {
  let length =
    request.get_header(req, "content-length") |> result.try(int.parse)

  // Accept a fixed size within the endpoint limit and reject ambiguous framing.
  case length, request.get_header(req, "transfer-encoding") {
    Ok(size), Error(Nil) if size >= 0 && size <= maximum ->
      read_body(req, size, maximum, then)
    Ok(size), Error(Nil) if size > maximum ->
      error(413, "request body too large")
    Ok(_), _ | Error(Nil), _ -> error(411, "bounded Content-Length required")
  }
}

/// Read within the endpoint limit and verify the client's declared byte count.
fn read_body(
  req: Request(Connection),
  size: Int,
  maximum: Int,
  then: fn(BitArray) -> Reply,
) -> Reply {
  let read =
    mist.read_body(req, max_body_limit: maximum)
    |> result.map(fn(body) { body.body })

  // Forward bytes only after a complete read of the advertised length.
  case read {
    Ok(bytes) -> {
      case bit_array.byte_size(bytes) == size {
        True -> then(bytes)
        False -> error(400, "short request body")
      }
    }
    Error(_) -> error(400, "could not read request body")
  }
}

/// Check the claimed digest before publishing bytes to shared storage.
///
/// ## Examples
///
/// ```gleam
/// // upload(shared_root, digest, bytes)
/// ```
fn upload(root: String, id: String, body: BitArray) -> Reply {
  case blobs.valid(id) && blobs.digest(body) == id {
    False -> fault_reply(fault.Invalid("upload digest mismatch"))
    True ->
      blobs.put(root, body)
      |> result.map(fn(saved) { json.object([#("digest", json.string(saved))]) })
      |> respond
  }
}

/// Return a verified blob as bytes, or report that the object is unavailable.
fn download(root: String, id: String) -> Reply {
  case blobs.get(root, id) {
    Ok(body) ->
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
    Error(reason) -> fault_reply(reason)
  }
}

fn respond(answer: Result(json.Json, Fault)) -> Reply {
  case answer {
    Ok(value) -> json_reply(200, value)
    Error(reason) -> fault_reply(reason)
  }
}

/// Report a typed failure with the status its kind selects. Transient
/// dependency failures use 503 so clients retry, and corrupt state uses 500.
pub fn fault_reply(reason: Fault) -> Reply {
  error(fault.status(reason), fault.detail(reason))
}

fn error(code: Int, reason: String) -> Reply {
  json_reply(code, json.object([#("error", json.string(reason))]))
}

/// Serialize a JSON response with the requested HTTP status and media type.
fn json_reply(code: Int, value: json.Json) -> Reply {
  response.new(code)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(json.to_string(value))),
  )
}
