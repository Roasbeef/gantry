import gantry/worker/controllers
import gantry/worker/custody
import gantry/worker/docker
import gantry/worker/slot
import gantry_core/queue
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import sqlight
import worker_fixture

/// How a fake Docker adapter answers.
type Script {
  Script(
    execute: fn(
      fn() -> Result(Nil, String),
      fn(BitArray) -> Result(String, String),
    ) -> Result(queue.Completion, docker.Fault),
    cleanup: fn() -> Result(Nil, docker.Fault),
  )
}

fn finished(
  _start: fn() -> Result(Nil, String),
  spool: fn(BitArray) -> Result(String, String),
) -> Result(queue.Completion, docker.Fault) {
  let assert Ok(log) = spool(<<"action log":utf8>>)
  Ok(queue.Succeeded([], log))
}

/// A slot whose journal already holds the claimed attempt `serial`.
fn claimed(
  script: Script,
  calls: process.Subject(String),
) -> #(String, slot.Slot, String) {
  let #(directory, db) = worker_fixture.journal()
  let name = worker_fixture.name(1)
  let assert Ok(Nil) = custody.claim(db, name, worker_fixture.assignment(1))
  let engine =
    slot.Engine(
      execute: fn(_name, _assignment, _network, start, spool) {
        process.send(calls, "execute")
        script.execute(start, spool)
      },
      cleanup: fn(_name) {
        process.send(calls, "cleanup")
        script.cleanup()
      },
    )
  #(directory, slot.Slot(directory, "w1", "linux", db, engine), name)
}

fn offline() -> slot.Cursor {
  // Port 1 refuses connections, so publication fails after cleanup.
  let assert Ok(network) = controllers.new("http://127.0.0.1:1", "token")
  slot.Cursor(network, None)
}

fn drain(calls: process.Subject(String)) -> List(String) {
  case process.receive(calls, 0) {
    Ok(call) -> [call, ..drain(calls)]
    Error(Nil) -> []
  }
}

fn pending(db: sqlight.Connection) -> option.Option(custody.Pending) {
  let assert Ok(pending) = custody.pending(db)
  pending
}

pub fn result_is_recorded_before_any_cleanup_test() {
  let calls = process.new_subject()
  let script = Script(execute: finished, cleanup: fn() { Ok(Nil) })
  let #(directory, current, name) = claimed(script, calls)

  // Running the action must not touch Docker cleanup at all.
  let #(cursor, verdict) = slot.step(current, offline())
  assert verdict == slot.Advanced
  assert drain(calls) == ["execute"]
  let assert Some(custody.Recorded(recorded, _)) = pending(current.db)
  assert recorded == name

  // Cleanup runs from the Recorded phase, after the receipt is durable.
  let #(cursor, verdict) = slot.step(current, cursor)
  assert drain(calls) == ["cleanup"]
  assert cursor.cleaned == Some(name)
  let assert slot.Faulted(slot.Retry(_)) = verdict

  // The offline controller keeps the receipt, and cleanup is not repeated.
  let #(_, verdict) = slot.step(current, cursor)
  assert drain(calls) == []
  let assert slot.Faulted(slot.Retry(_)) = verdict
  let assert Some(custody.Recorded(_, _)) = pending(current.db)
  worker_fixture.remove(directory)
}

pub fn cleanup_fault_keeps_the_finished_result_test() {
  let calls = process.new_subject()
  let script =
    Script(execute: finished, cleanup: fn() {
      Error(docker.Unavailable("Docker: daemon restarting"))
    })
  let #(directory, current, _) = claimed(script, calls)
  let #(cursor, verdict) = slot.step(current, offline())
  assert verdict == slot.Advanced

  // The cleanup blip is retried and never turns the result into a failure.
  let #(cursor, verdict) = slot.step(current, cursor)
  assert verdict == slot.Faulted(slot.Retry("Docker: daemon restarting"))
  assert cursor.cleaned == None
  let assert Some(custody.Recorded(_, receipt)) = pending(current.db)
  assert string.contains(receipt, "\"kind\":\"succeeded\"")
  worker_fixture.remove(directory)
}

pub fn fault_before_the_start_marker_retries_the_attempt_test() {
  let calls = process.new_subject()
  let script =
    Script(
      execute: fn(_start, _spool) { Error(docker.Unavailable("Docker: blip")) },
      cleanup: fn() { Ok(Nil) },
    )
  let #(directory, current, name) = claimed(script, calls)
  let #(_, verdict) = slot.step(current, offline())
  assert verdict == slot.Faulted(slot.Retry("Docker: blip"))
  let assert Some(custody.Ready(ready, _)) = pending(current.db)
  assert ready == name
  worker_fixture.remove(directory)
}

pub fn fault_after_the_start_marker_interrupts_after_cleanup_test() {
  let calls = process.new_subject()
  let script =
    Script(
      execute: fn(start, _spool) {
        let assert Ok(Nil) = start()
        Error(docker.Unavailable("Docker: lost the daemon"))
      },
      cleanup: fn() { Ok(Nil) },
    )
  let #(directory, current, _) = claimed(script, calls)
  let #(cursor, verdict) = slot.step(current, offline())
  assert verdict == slot.Faulted(slot.Retry("Docker: lost the daemon"))
  let assert Some(custody.Interrupted(_, _)) = pending(current.db)

  // The action may have run, so this slot never runs it again. It reports
  // the attempt interrupted, and the controller reassigns it.
  let #(_, verdict) = slot.step(current, cursor)
  assert verdict == slot.Advanced
  assert drain(calls) == ["execute", "cleanup"]
  let assert Some(custody.Recorded(_, receipt)) = pending(current.db)
  assert string.contains(receipt, "\"kind\":\"interrupted\"")
  assert custody.referenced(receipt) == Ok([])
  worker_fixture.remove(directory)
}

pub fn release_interrupts_an_unfinished_attempt_without_running_it_test() {
  let calls = process.new_subject()
  let script = Script(execute: finished, cleanup: fn() { Ok(Nil) })
  let #(directory, current, _) = claimed(script, calls)

  // The drain deadline gives the attempt up: cleanup, record, then publish.
  // The offline controller keeps the receipt for the next start.
  let assert Error(slot.Retry(_)) = slot.release(current, offline())
  assert drain(calls) == ["cleanup", "cleanup"]
  let assert Some(custody.Recorded(_, receipt)) = pending(current.db)
  assert string.contains(receipt, "\"kind\":\"interrupted\"")
  worker_fixture.remove(directory)
}

pub fn release_of_an_idle_journal_does_nothing_test() {
  let calls = process.new_subject()
  let script = Script(execute: finished, cleanup: fn() { Ok(Nil) })
  let #(directory, db) = worker_fixture.journal()
  let engine =
    slot.Engine(
      execute: fn(_name, _assignment, _network, start, spool) {
        process.send(calls, "execute")
        script.execute(start, spool)
      },
      cleanup: fn(_name) {
        process.send(calls, "cleanup")
        script.cleanup()
      },
    )
  let current = slot.Slot(directory, "w1", "linux", db, engine)
  assert slot.release(current, offline()) == Ok(Nil)
  assert drain(calls) == []
  worker_fixture.remove(directory)
}

pub fn rejected_action_records_its_reason_test() {
  let calls = process.new_subject()
  let script =
    Script(
      execute: fn(_start, _spool) {
        Error(docker.Rejected("unsafe path in source archive"))
      },
      cleanup: fn() { Ok(Nil) },
    )
  let #(directory, current, _) = claimed(script, calls)
  let #(_, verdict) = slot.step(current, offline())
  assert verdict == slot.Advanced
  let assert Some(custody.Recorded(_, receipt)) = pending(current.db)
  assert string.contains(receipt, "unsafe path in source archive")
  worker_fixture.remove(directory)
}
