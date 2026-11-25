import gantry/blobs
import gantry/worker/custody
import gantry_core/queue
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import sqlight
import worker_fixture

fn count(db: sqlight.Connection, table: String) -> Int {
  let assert Ok([rows]) =
    sqlight.query(
      "SELECT count(*) FROM " <> table,
      on: db,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  rows
}

pub fn claim_start_record_acknowledge_cycle_test() {
  let #(directory, db) = worker_fixture.journal()
  let name = worker_fixture.name(1)
  let assignment = worker_fixture.assignment(1)

  assert custody.claim(db, name, assignment) == Ok(Nil)
  assert custody.pending(db) == Ok(Some(custody.Ready(name, assignment)))

  assert custody.mark_started(db, name) == Ok(Nil)
  assert custody.pending(db) == Ok(Some(custody.Interrupted(name, assignment)))

  let assert Ok(log) = custody.spool(db, <<"log":utf8>>)
  let completion = queue.Rejected("failed", log)
  assert custody.record(db, name, assignment, completion) == Ok(Nil)
  let assert Ok(Some(custody.Recorded(recorded, _))) = custody.pending(db)
  assert recorded == name

  assert custody.acknowledge(db, name) == Ok(Nil)
  assert custody.pending(db) == Ok(None)
  worker_fixture.remove(directory)
}

pub fn acknowledging_deletes_the_attempt_and_the_spool_test() {
  let #(directory, db) = worker_fixture.journal()
  let name = worker_fixture.name(1)
  let assignment = worker_fixture.assignment(1)
  let assert Ok(Nil) = custody.claim(db, name, assignment)
  let assert Ok(log) = custody.spool(db, <<"log":utf8>>)
  let assert Ok(_) = custody.spool(db, <<"never referenced":utf8>>)
  let assert Ok(Nil) =
    custody.record(db, name, assignment, queue.Rejected("failed", log))

  assert count(db, "attempts") == 1
  assert count(db, "blobs") == 2
  assert custody.acknowledge(db, name) == Ok(Nil)
  assert count(db, "attempts") == 0
  assert count(db, "blobs") == 0
  worker_fixture.remove(directory)
}

pub fn journal_does_not_grow_across_many_attempts_test() {
  let #(directory, db) = worker_fixture.journal()
  list.each(
    int.range(from: 1, to: 41, with: [], run: fn(all, n) { [n, ..all] }),
    fn(serial) {
      let name = worker_fixture.name(serial)
      let assignment = worker_fixture.assignment(serial)
      let assert Ok(Nil) = custody.claim(db, name, assignment)
      let assert Ok(log) = custody.spool(db, <<int.to_string(serial):utf8>>)
      let assert Ok(Nil) =
        custody.record(db, name, assignment, queue.Rejected("failed", log))
      let assert Ok(Nil) = custody.acknowledge(db, name)
    },
  )
  assert count(db, "attempts") == 0
  assert count(db, "blobs") == 0
  worker_fixture.remove(directory)
}

pub fn a_lease_delivered_again_after_acknowledgement_is_new_work_test() {
  let #(directory, db) = worker_fixture.journal()
  let name = worker_fixture.name(7)
  let assignment = worker_fixture.assignment(7)
  let assert Ok(Nil) = custody.claim(db, name, assignment)
  let assert Ok(Nil) = custody.acknowledge(db, name)

  // A restored controller can issue the same serial. The slot runs it again.
  assert custody.claim(db, name, assignment) == Ok(Nil)
  assert custody.pending(db) == Ok(Some(custody.Ready(name, assignment)))
  worker_fixture.remove(directory)
}

pub fn opening_compacts_rows_acknowledged_by_older_workers_test() {
  let #(directory, db) = worker_fixture.journal()
  let assert Ok(Nil) =
    sqlight.exec(
      "INSERT INTO attempts(name, assignment, acknowledged, started) VALUES ('old', '{}', 1, 1)",
      on: db,
    )
  assert count(db, "attempts") == 1
  let assert Ok(Nil) = sqlight.close(db)

  let assert Ok(reopened) = custody.open(directory <> "/custody.sqlite3", "w1")
  assert count(reopened, "attempts") == 0
  worker_fixture.remove(directory)
}

pub fn receipt_references_only_its_own_digests_test() {
  let log = blobs.digest(<<"log":utf8>>)
  let first = blobs.digest(<<"first":utf8>>)
  let second = blobs.digest(<<"second":utf8>>)
  let #(directory, db) = worker_fixture.journal()
  let name = worker_fixture.name(1)
  let assignment = worker_fixture.assignment(1)
  let assert Ok(Nil) = custody.claim(db, name, assignment)

  // Spooled bytes of a rejected action are unrelated to its receipt.
  let assert Ok(_) = custody.spool(db, <<"stray output":utf8>>)
  let succeeded =
    queue.Succeeded(
      [queue.Artifact("a", first), queue.Artifact("b", second)],
      log,
    )
  let assert Ok(Nil) = custody.record(db, name, assignment, succeeded)
  let assert Ok(Some(custody.Recorded(_, receipt))) = custody.pending(db)
  assert custody.referenced(receipt) == Ok([log, first, second])

  let assert Ok(Nil) = custody.acknowledge(db, name)
  let rejected = queue.Rejected("failed", log)
  let assert Ok(Nil) = custody.claim(db, name, assignment)
  let assert Ok(Nil) = custody.record(db, name, assignment, rejected)
  let assert Ok(Some(custody.Recorded(_, receipt))) = custody.pending(db)
  assert custody.referenced(receipt) == Ok([log])
  worker_fixture.remove(directory)
}

pub fn identical_artifact_digests_are_listed_once_test() {
  let same = blobs.digest(<<"same":utf8>>)
  let #(directory, db) = worker_fixture.journal()
  let name = worker_fixture.name(1)
  let assignment = worker_fixture.assignment(1)
  let assert Ok(Nil) = custody.claim(db, name, assignment)
  let completion =
    queue.Succeeded(
      [queue.Artifact("a", same), queue.Artifact("b", same)],
      same,
    )
  let assert Ok(Nil) = custody.record(db, name, assignment, completion)
  let assert Ok(Some(custody.Recorded(_, receipt))) = custody.pending(db)
  assert custody.referenced(receipt) == Ok([same])
  worker_fixture.remove(directory)
}

pub fn a_second_open_of_a_held_journal_is_refused_test() {
  let #(directory, db) = worker_fixture.journal()
  let path = directory <> "/custody.sqlite3"
  let assert Error(reason) = custody.open(path, "w1")
  assert string.contains(reason, "another worker already owns")

  // Releasing the first connection frees the slot for its next owner.
  let assert Ok(Nil) = sqlight.close(db)
  let assert Ok(_) = custody.open(path, "w1")
  worker_fixture.remove(directory)
}

pub fn a_managed_journal_is_held_exclusively_too_test() {
  let directory = worker_fixture.temp_directory()
  let journal = directory <> "/journal"
  let assert Ok(Nil) = simplifile.create_directory_all(journal)
  let assert Ok(first) = custody.open_managed(directory, journal, "w1")
  let assert Error(reason) = custody.open_managed(directory, journal, "w1")
  assert string.contains(reason, "another worker already owns")

  // The lock ends with the connection, so the first owner must stay alive.
  let assert Ok(Nil) = sqlight.close(first)
  worker_fixture.remove(directory)
}
