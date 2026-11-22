//// SQLite keeps one worker assignment across restarts. Pending rows move
//// through ready, interrupted on a possible start, and recorded. A receipt
//// and its blobs remain publishable until the same transaction acknowledges
//// the assignment and clears the spool.

import gantry/blobs
import gantry/internal/ffi_host
import gantry/sql
import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gleam/dynamic/decode
import gleam/erlang/application
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import simplifile
import sqlight

/// The persisted state needed to recover one worker attempt.
pub type Pending {
  Ready(name: String, assignment: queue.Assignment)
  Interrupted(name: String, assignment: queue.Assignment)
  Recorded(name: String, receipt: String)
}

/// Open the existing journal format and bind it to this worker identity.
///
/// ## Examples
///
/// ```gleam
/// // custody.open("/srv/gantry/slot/custody.sqlite3", "linux-1")
/// ```
pub fn open(
  path: String,
  worker: String,
) -> Result(sqlight.Connection, String) {
  use db <- result.try(sqlight.open(path) |> result.map_error(sql_fault))
  use ddl <- result.try(
    application.priv_directory("gantry")
    |> result.replace_error("cannot locate the worker journal schema")
    |> result.try(fn(path) {
      simplifile.read(path <> "/worker-schema.sql")
      |> result.replace_error("cannot read the worker journal schema")
    }),
  )
  use Nil <- result.try(exec(db, "PRAGMA synchronous=FULL;" <> ddl))
  use columns <- result.try(
    sqlight.query(
      "PRAGMA table_info(attempts)",
      on: db,
      with: [],
      expecting: decode.at([1], decode.string),
    )
    |> result.map_error(sql_fault),
  )

  // Old journals conservatively treat every unresolved attempt as started.
  use Nil <- result.try(case list.contains(columns, "started") {
    True -> Ok(Nil)
    False ->
      exec(db, "ALTER TABLE attempts ADD COLUMN started INTEGER DEFAULT 1")
  })

  use identity <- result.try(query(db, sql.worker_identity()))

  // Each slot directory is bound to exactly one worker identity.
  case identity {
    [] -> update(db, sql.register_worker(worker:)) |> result.replace(db)
    [sql.WorkerIdentity(existing)] if existing == worker -> Ok(db)
    _ -> Error("GANTRY_WORKER_DIR already belongs to a different worker ID")
  }
}

/// Bind managed custody to a durable marker outside the worker directory.
///
/// ## Examples
///
/// ```gleam
/// // custody.open_managed("/srv/gantry/slot", "/srv/gantry/slot/journal", "linux-1")
/// ```
pub fn open_managed(
  profile: String,
  directory: String,
  worker: String,
) -> Result(sqlight.Connection, String) {
  let path = directory <> "/custody.sqlite3"
  let marker = profile <> "/worker-established"
  let identity = worker <> "\n" <> path <> "\n"

  // The profile must survive deletion of its child journal directory.
  use Nil <- result.try(case directory == profile <> "/journal" {
    True -> Ok(Nil)
    False ->
      Error("managed worker journal directory does not match the profile")
  })

  // The worker owns the slot lock before either opening or marking custody.
  case simplifile.read(marker) {
    Ok(saved) if saved == identity -> {
      use exists <- result.try(
        simplifile.is_file(path)
        |> result.replace_error("cannot check the managed worker journal"),
      )

      // An established slot may still have a lease or unpublished receipt.
      case exists {
        True -> open(path, worker)
        False ->
          Error(
            "managed worker journal is missing; restore it before restarting",
          )
      }
    }
    Ok(_) -> Error("managed worker identity does not match its custody marker")
    Error(simplifile.Enoent) -> {
      use db <- result.try(open(path, worker))
      use Nil <- result.try(ffi_host.sync_path(path))
      use Nil <- result.try(ffi_host.sync_path(directory))
      use Nil <- result.try(publish_marker(profile, marker, identity))
      Ok(db)
    }
    Error(_) -> Error("cannot read the managed worker custody marker")
  }
}

/// Persist a recoverable startup boundary before the slot can claim work.
fn publish_marker(
  profile: String,
  marker: String,
  identity: String,
) -> Result(Nil, String) {
  let staged = marker <> ".next"
  use Nil <- result.try(
    simplifile.write(identity, to: staged)
    |> result.replace_error("cannot stage the managed worker custody marker"),
  )
  use Nil <- result.try(ffi_host.sync_path(staged))
  use Nil <- result.try(
    simplifile.rename(staged, marker)
    |> result.replace_error("cannot publish the managed worker custody marker"),
  )
  ffi_host.sync_path(profile)
}

/// Read and validate the recorded attempt before it can authorize an effect.
///
/// ## Examples
///
/// ```gleam
/// // custody.pending(db)
/// ```
pub fn pending(db: sqlight.Connection) -> Result(Option(Pending), String) {
  use rows <- result.try(query(db, sql.pending_attempts()))

  // An idle slot has no unacknowledged attempts.
  case rows {
    [] -> Ok(None)
    [row] -> {
      use Nil <- result.try(validate_name(row.name))
      use assignment <- result.try(assignment(row.assignment))

      // A saved receipt takes precedence over the earlier start marker.
      case row.receipt, row.started {
        Some(json), _ ->
          validate_receipt(json, assignment)
          |> result.replace(Some(Recorded(row.name, json)))
        None, 1 -> Ok(Some(Interrupted(row.name, assignment)))
        None, 0 -> Ok(Some(Ready(row.name, assignment)))
        None, _ -> Error("invalid worker attempt start marker")
      }
    }
    _ -> Error("worker journal has more than one unacknowledged attempt")
  }
}

/// Decode a controller or journal assignment with the core wire codec.
///
/// ## Examples
///
/// ```gleam
/// // custody.assignment("{}") == Error("invalid worker assignment")
/// ```
pub fn assignment(payload: String) -> Result(queue.Assignment, String) {
  use value <- result.try(
    json.parse(payload, protocol.assignment_decoder())
    |> result.replace_error("invalid worker assignment"),
  )
  graph.validate_action(value.task.action) |> result.replace(value)
}

/// Persist a claim and reuse any receipt already recorded for its identity.
///
/// ## Examples
///
/// ```gleam
/// // custody.claim(db, name, assignment)
/// ```
pub fn claim(
  db: sqlight.Connection,
  name: String,
  claim: queue.Assignment,
) -> Result(Nil, String) {
  use existing <- result.try(query(
    db,
    sql.find_attempt(
      serial: claim.lease.serial,
      run: claim.run,
      action: claim.task.action.name,
    ),
  ))

  // Re-admission reuses the previous Docker name only for the same assignment.
  case existing {
    [] ->
      update(
        db,
        sql.insert_attempt(
          name:,
          assignment: json.to_string(protocol.encode_assignment(claim)),
        ),
      )
    [old] -> {
      use stored <- result.try(assignment(old.assignment))

      // A conflicting claim cannot release or start work from this journal.
      case stored == claim {
        True -> update(db, sql.reopen_attempt(name: old.name))
        False -> Error("worker journal has different inputs for this lease")
      }
    }
    _ -> Error("worker journal has duplicate records for this lease")
  }
}

/// Commit the start marker before any Docker resource could exist.
///
/// ## Examples
///
/// ```gleam
/// // custody.mark_started(db, name)
/// ```
pub fn mark_started(
  db: sqlight.Connection,
  name: String,
) -> Result(Nil, String) {
  update(db, sql.mark_started(name:))
}

/// Stage bytes in the journal before a receipt can reference them.
///
/// ## Examples
///
/// ```gleam
/// // custody.spool(db, <<"log">>)
/// ```
pub fn spool(
  db: sqlight.Connection,
  bytes: BitArray,
) -> Result(String, String) {
  let digest = blobs.digest(bytes)
  update(db, sql.spool_blob(sha: digest, data: bytes)) |> result.replace(digest)
}

/// Save the result envelope in the format understood by the controller.
///
/// ## Examples
///
/// ```gleam
/// // custody.record(db, name, assignment, completion)
/// ```
pub fn record(
  db: sqlight.Connection,
  name: String,
  assignment: queue.Assignment,
  completion: queue.Completion,
) -> Result(Nil, String) {
  let payload =
    json.object([
      #("worker", json.string(assignment.lease.worker)),
      #("run", json.string(assignment.run)),
      #("action", json.string(assignment.task.action.name)),
      #("serial", json.int(assignment.lease.serial)),
      #("completion", protocol.encode_completion(completion)),
    ])
  update(db, sql.save_receipt(receipt: Some(json.to_string(payload)), name:))
}

/// List the blobs awaiting publication without loading their payloads.
///
/// ## Examples
///
/// ```gleam
/// // custody.digests(db)
/// ```
pub fn digests(db: sqlight.Connection) -> Result(List(String), String) {
  query(db, sql.pending_digests())
  |> result.map(list.map(_, fn(row) { row.sha }))
}

/// Read and verify one pending upload.
///
/// ## Examples
///
/// ```gleam
/// // custody.blob(db, digest)
/// ```
pub fn blob(
  db: sqlight.Connection,
  digest: String,
) -> Result(BitArray, String) {
  use rows <- result.try(query(db, sql.load_blob(sha: digest)))

  // A successful read must match the requested content address.
  case rows {
    [sql.LoadBlob(bytes)] ->
      case blobs.digest(bytes) == digest {
        True -> Ok(bytes)
        False -> Error("worker journal blob failed digest verification")
      }
    _ -> Error("worker journal blob is missing")
  }
}

/// Release the attempt and discard its spool in one transaction.
///
/// ## Examples
///
/// ```gleam
/// // custody.acknowledge(db, name)
/// ```
pub fn acknowledge(
  db: sqlight.Connection,
  name: String,
) -> Result(Nil, String) {
  use Nil <- result.try(exec(db, "BEGIN IMMEDIATE"))
  let done = {
    use Nil <- result.try(update(db, sql.acknowledge_attempt(name:)))
    use Nil <- result.try(update(db, sql.clear_spool()))
    exec(db, "COMMIT")
  }

  // A failed transaction leaves the attempt and its blobs available for replay.
  case done {
    Ok(Nil) -> done
    Error(_) -> {
      let _ = exec(db, "ROLLBACK")
      done
    }
  }
}

/// Check the recorded container name before passing it to Docker.
fn validate_name(name: String) -> Result(Nil, String) {
  case
    string.starts_with(name, "gantry-")
    && blobs.valid(string.drop_start(name, 7))
  {
    True -> Ok(Nil)
    False -> Error("invalid Docker identity in the worker journal")
  }
}

/// Bind a decoded receipt to its original worker, lease, and action.
fn validate_receipt(
  payload: String,
  assignment: queue.Assignment,
) -> Result(Nil, String) {
  let decoder = {
    use worker <- decode.field("worker", decode.string)
    use run <- decode.field("run", decode.string)
    use action <- decode.field("action", decode.string)
    use serial <- decode.field("serial", decode.int)
    use _ <- decode.field("completion", protocol.completion_decoder())
    decode.success(#(worker, run, action, serial))
  }
  let expected = #(
    assignment.lease.worker,
    assignment.run,
    assignment.task.action.name,
    assignment.lease.serial,
  )

  // Both the wire shape and the durable assignment identity must match.
  case json.parse(payload, decoder) == Ok(expected) {
    True -> Ok(Nil)
    False -> Error("invalid result envelope in the worker journal")
  }
}

fn exec(db: sqlight.Connection, statement: String) -> Result(Nil, String) {
  sqlight.exec(statement, on: db) |> result.map_error(sql_fault)
}

/// Bind generated parameters and decode rows with Parrot's generated decoder.
fn query(
  db: sqlight.Connection,
  statement: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), String) {
  let #(text, arguments, decoder) = statement
  use values <- result.try(list.try_map(arguments, parameter))
  sqlight.query(text, on: db, with: values, expecting: decoder)
  |> result.map_error(sql_fault)
}

fn update(
  db: sqlight.Connection,
  statement: #(String, List(dev.Param)),
) -> Result(Nil, String) {
  query(db, #(statement.0, statement.1, decode.dynamic)) |> result.replace(Nil)
}

/// Translate the generated journal parameter types to SQLite values.
fn parameter(value: dev.Param) -> Result(sqlight.Value, String) {
  case value {
    dev.ParamString(value) -> Ok(sqlight.text(value))
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamBitArray(value) -> Ok(sqlight.blob(value))
    dev.ParamNullable(None) -> Ok(sqlight.null())
    dev.ParamNullable(Some(value)) -> parameter(value)
    _ -> Error("unsupported worker journal SQL parameter")
  }
}

fn sql_fault(error: sqlight.Error) -> String {
  "worker journal: " <> error.message
}
