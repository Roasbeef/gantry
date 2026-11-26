//// SQLite keeps one worker assignment across restarts. Pending rows move
//// through ready, interrupted on a possible start, and recorded. A receipt
//// and its blobs remain publishable until one transaction deletes the
//// attempt row and clears the spool, so the journal holds at most the one
//// attempt the slot is working on.
////
//// ```text
//// claim -> Ready --mark_started--> Interrupted --record--> Recorded
////            \---------record (rejected before start)------^
//// Recorded --acknowledge (delete row, clear spool)--> idle
//// ```
////
//// Deleting on acknowledgement is deliberate. The spool is cleared in the
//// same transaction, so an acknowledged receipt could never be published
//// again; keeping its row only grew the table and made a re-delivered lease
//// look like a replay whose blobs no longer exist. A lease the controller
//// issues again after a store rollback is new work and runs again.

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
import gleam/uri
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
  use Nil <- result.try(lock(db))
  use ddl <- result.try(
    application.priv_directory("gantry")
    |> result.replace_error("cannot locate the worker journal schema")
    |> result.try(fn(path) {
      simplifile.read(path <> "/worker-schema.sql")
      |> result.replace_error("cannot read the worker journal schema")
    }),
  )
  use Nil <- result.try(exec(db, "PRAGMA synchronous=FULL;" <> ddl))
  use Nil <- result.try(migrate_attempts(db))
  use Nil <- result.try(update(db, sql.delete_acknowledged_attempts()))
  use identity <- result.try(query(db, sql.worker_identity()))

  // Each slot directory is bound to exactly one worker identity.
  case identity {
    [] -> update(db, sql.register_worker(worker:)) |> result.replace(db)
    [sql.WorkerIdentity(existing)] if existing == worker -> Ok(db)
    _ -> Error("GANTRY_WORKER_DIR already belongs to a different worker ID")
  }
}

/// Preserve an established slot's existing tables and identity on restart.
fn reopen(path: String, worker: String) -> Result(sqlight.Connection, String) {
  use info <- result.try(
    simplifile.file_info(path)
    |> result.replace_error("cannot check the managed worker journal"),
  )

  // Taking the exclusive lock on an empty file makes SQLite write its header,
  // so an empty journal is refused before it is opened. It has no identity.
  use Nil <- result.try(case info.size {
    0 -> Error("managed worker journal has no readable identity")
    _ -> Ok(Nil)
  })

  let db_uri = "file:" <> uri.percent_encode(path) <> "?mode=rw"
  use db <- result.try(sqlight.open(db_uri) |> result.map_error(sql_fault))
  use Nil <- result.try(lock(db))
  use identity <- result.try(
    query(db, sql.worker_identity())
    |> result.replace_error("managed worker journal has no readable identity"),
  )

  // Only matching custody can advance to validation and migration.
  case identity {
    [sql.WorkerIdentity(existing)] if existing == worker -> {
      use Nil <- result.try(exec(
        db,
        "PRAGMA synchronous=FULL;"
          <> "SELECT name, assignment, receipt, acknowledged FROM attempts LIMIT 0;"
          <> "SELECT sha, data FROM blobs LIMIT 0;",
      ))
      use Nil <- result.try(migrate_attempts(db))
      update(db, sql.delete_acknowledged_attempts()) |> result.replace(db)
    }
    _ -> Error("managed worker journal does not contain the saved identity")
  }
}

/// Take SQLite's exclusive lock for the life of the connection.
///
/// In exclusive locking mode SQLite keeps the file lock after the first
/// transaction instead of releasing it at commit, so no second worker can
/// open this journal while the connection lives. The owner must keep the
/// connection referenced, because closing or collecting it ends the lock.
/// The operating system drops the lock when the process exits, however it
/// exits, and no helper process or external `flock` is needed. The lock
/// follows the journal file: a managed profile also keeps its custody
/// marker, which refuses to start a second worker for an established slot
/// whose journal went missing.
fn lock(db: sqlight.Connection) -> Result(Nil, String) {
  exec(db, "PRAGMA locking_mode=EXCLUSIVE;BEGIN EXCLUSIVE;COMMIT;")
  |> result.replace_error(
    "worker journal is locked: another worker already owns GANTRY_WORKER_DIR",
  )
}

/// Upgrade old attempt rows conservatively before resuming custody.
fn migrate_attempts(db: sqlight.Connection) -> Result(Nil, String) {
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
  case list.contains(columns, "started") {
    True -> Ok(Nil)
    False ->
      exec(db, "ALTER TABLE attempts ADD COLUMN started INTEGER DEFAULT 1")
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

  // The marker only restates this slot's identity, so reading it first is
  // safe. Opening the journal takes its exclusive lock before any write.
  case simplifile.read(marker) {
    Ok(saved) if saved == identity -> {
      use exists <- result.try(
        simplifile.is_file(path)
        |> result.replace_error("cannot check the managed worker journal"),
      )

      // An established slot may still have a lease or unpublished receipt.
      case exists {
        True -> reopen(path, worker)
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

/// Persist a claim before the slot can act on it.
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
  update(
    db,
    sql.insert_attempt(
      name:,
      assignment: json.to_string(protocol.encode_assignment(claim)),
    ),
  )
}

/// Commit the start marker before the action's container can start.
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
      #("worker", json.string(queue.lease_worker(assignment.lease))),
      #("run", json.string(assignment.run)),
      #("action", json.string(assignment.task.action.name)),
      #("serial", json.int(queue.lease_serial(assignment.lease))),
      #("completion", protocol.encode_completion(completion)),
    ])
  update(db, sql.save_receipt(receipt: Some(json.to_string(payload)), name:))
}

/// List the distinct digests a saved receipt refers to, log first.
///
/// ## Examples
///
/// ```gleam
/// // custody.referenced(receipt)
/// ```
pub fn referenced(receipt: String) -> Result(List(String), String) {
  let decoder = {
    use completion <- decode.field("completion", protocol.completion_decoder())
    decode.success(completion)
  }
  use completion <- result.try(
    json.parse(receipt, decoder)
    |> result.replace_error("invalid result envelope in the worker journal"),
  )

  // A rejection references only its log. A pass adds its output files. An
  // interruption references nothing.
  let digests = case completion {
    queue.Succeeded(files, log) -> [log, ..list.map(files, fn(f) { f.digest })]
    queue.Rejected(_, log) -> [log]
    queue.Interrupted -> []
  }

  Ok(list.unique(digests))
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

/// Delete the attempt and discard its spool in one transaction.
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
    use Nil <- result.try(update(db, sql.delete_attempt(name:)))
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
    queue.lease_worker(assignment.lease),
    assignment.run,
    assignment.task.action.name,
    queue.lease_serial(assignment.lease),
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
