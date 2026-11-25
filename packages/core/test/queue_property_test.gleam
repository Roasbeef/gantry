//// Generated worker reports exercise ownership, path matching, and persistence.

import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gantry_core/sandbox
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import qcheck

const cases = 120

pub fn generated_receipts_require_the_current_owner_and_exact_paths_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(cases)
    |> qcheck.with_seed(qcheck.seed(2461))
  qcheck.run(config, receipt(), fn(input) {
    let #(number, digests, reverse) = input
    let #(pending, artifacts) = pending_run(number, digests)
    let #(active, assignment) = claim(pending, number)
    let worker = queue.lease_worker(assignment.lease)
    let serial = queue.lease_serial(assignment.lease)
    let paths = case reverse % 2 {
      0 -> list.reverse(artifacts)
      _ -> artifacts
    }
    let log = "log-" <> int.to_string(number)
    let completion = queue.Succeeded(paths, log)
    let attempt_error = Error("attempt is no longer active")
    let assert True =
      finish(active, assignment, worker <> "-other", serial, completion)
      == attempt_error
    let assert True =
      finish(active, assignment, worker, serial - 1, completion)
      == attempt_error
    let assert True =
      finish(active, assignment, worker, serial + 1, completion)
      == attempt_error

    // Cardinality and exact paths must match even when the supplied digest
    // belongs to a declared file.
    let assert [first, ..rest] = paths
    let wrong = queue.Artifact(..first, path: first.path <> "/child")
    list.each([rest, [first, ..paths], [wrong, ..rest]], fn(files) {
      let assert Error("output manifest does not match declared paths") =
        finish(active, assignment, worker, serial, queue.Succeeded(files, log))
      Nil
    })

    let assert Ok(next) = finish(active, assignment, worker, serial, completion)
    let assert Ok(run) = queue.find(next, assignment.run)
    let assert [queue.Work(_, queue.Passed(proof))] = run.work
    let assert True =
      proof == queue.proof(queue.lease_key(assignment.lease), paths, log)
    let assert True =
      finish(next, assignment, worker, serial, completion) == attempt_error
    Nil
  })
}

pub fn generated_queue_snapshots_and_wire_values_round_trip_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(cases)
    |> qcheck.with_seed(qcheck.seed(7139))
  qcheck.run(config, receipt(), fn(input) {
    let #(number, digests, outcome) = input
    let #(pending, artifacts) = pending_run(number, digests)
    let #(active, assignment) = claim(pending, number)
    let suffix = int.to_string(number)
    let completion = case outcome {
      0 -> queue.Rejected("failure-" <> suffix, "log-" <> suffix)
      1 -> queue.Interrupted
      _ -> queue.Succeeded(artifacts, "log-" <> suffix)
    }
    let assert True =
      json.parse(
        json.to_string(protocol.encode_assignment(assignment)),
        protocol.assignment_decoder(),
      )
      == Ok(assignment)
    let assert True =
      json.parse(
        json.to_string(protocol.encode_completion(completion)),
        protocol.completion_decoder(),
      )
      == Ok(completion)

    let assert Ok(settled) =
      finish(
        active,
        assignment,
        queue.lease_worker(assignment.lease),
        queue.lease_serial(assignment.lease),
        completion,
      )
    list.each([pending, active, settled], assert_persistence)

    // A restored snapshot must preserve the lease and replay the same decision.
    let assert Ok(restored) =
      json.parse(
        json.to_string(protocol.encode_state(active)),
        protocol.state_decoder(),
      )
    let assert True =
      queue.claim(
        restored,
        queue.lease_worker(assignment.lease),
        assignment.task.pool,
        number + 1,
      )
      == #(active, option.Some(assignment))
    let assert True =
      finish(
        restored,
        assignment,
        queue.lease_worker(assignment.lease),
        queue.lease_serial(assignment.lease),
        completion,
      )
      == Ok(settled)
    case completion {
      queue.Succeeded(_, _) -> assert_landing_persistence(settled, suffix)
      queue.Rejected(_, _) -> {
        let assert #(unchanged, []) = queue.landings(settled)
        let assert True = unchanged == settled
        Nil
      }

      // An interruption returns the action for a second attempt under a
      // fresh serial, and the old serial is fenced from then on.
      queue.Interrupted -> {
        let worker = queue.lease_worker(assignment.lease)
        let assert #(_, option.Some(again)) =
          queue.claim(settled, worker, assignment.task.pool, number + 1)
        let assert 2 = queue.lease_attempt(again.lease)
        let assert True =
          queue.lease_serial(again.lease) > queue.lease_serial(assignment.lease)
        let assert Error(_) =
          finish(
            settled,
            assignment,
            worker,
            queue.lease_serial(assignment.lease),
            queue.Succeeded(artifacts, "late"),
          )
        Nil
      }
    }
  })
}

fn receipt() -> qcheck.Generator(#(Int, List(Int), Int)) {
  qcheck.tuple3(
    qcheck.bounded_int(from: 0, to: 50_000),
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(from: 0, to: 65_535),
      length_from: qcheck.bounded_int(from: 1, to: 8),
    ),
    qcheck.bounded_int(from: 0, to: 2),
  )
}

fn pending_run(
  number: Int,
  digests: List(Int),
) -> #(queue.State, List(queue.Artifact)) {
  let suffix = int.to_string(number)
  let files =
    list.index_map(digests, fn(digest, index) {
      queue.Artifact(
        "out/" <> suffix <> "/" <> int.to_string(index),
        int.to_string(digest),
      )
    })
  let action =
    graph.action(
      "action-" <> suffix,
      ["make", suffix],
      ["."],
      list.map(files, fn(file) { file.path }),
      [],
      [],
      number % 3600 + 1,
    )
  let task =
    queue.whole_task(
      action,
      "tree-" <> suffix,
      "recipe-" <> suffix,
      "linux",
      "image",
      sandbox.Strict,
    )
  let candidate =
    queue.candidate("main", "base-" <> suffix, "commit-" <> suffix, [
      queue.Member(number + 1, "head-" <> suffix),
    ])
  let assert Ok(#(state, _)) =
    queue.admit(
      queue.empty(),
      "run-" <> suffix,
      "owner/project",
      queue.candidate_commit(candidate),
      "check",
      queue.Queued(candidate),
      [task],
    )
  #(state, files)
}

fn claim(state: queue.State, number: Int) -> #(queue.State, queue.Assignment) {
  let assert #(active, option.Some(assignment)) =
    queue.claim(state, "worker-" <> int.to_string(number), "linux", number)
  #(active, assignment)
}

fn finish(
  state: queue.State,
  assignment: queue.Assignment,
  worker: String,
  serial: Int,
  completion: queue.Completion,
) -> Result(queue.State, String) {
  queue.finish(
    state,
    assignment.run,
    assignment.task.action.name,
    worker,
    serial,
    completion,
  )
}

fn assert_persistence(state: queue.State) -> Nil {
  let assert True =
    json.parse(
      json.to_string(protocol.encode_state(state)),
      protocol.state_decoder(),
    )
    == Ok(state)
  list.each(state.runs, fn(run) {
    let assert True =
      json.parse(
        json.to_string(protocol.encode_run(run)),
        protocol.run_decoder(),
      )
      == Ok(run)
    Nil
  })
}

fn assert_landing_persistence(state: queue.State, suffix: String) -> Nil {
  let assert #(landing, [intent]) = queue.landings(state)
  assert_persistence(landing)
  let assert Ok(restored) =
    json.parse(
      json.to_string(protocol.encode_state(landing)),
      protocol.state_decoder(),
    )
  let assert True = queue.landings(restored) == #(landing, [intent])
  list.each(
    [
      Ok(Nil),
      Error(queue.TargetAdvanced),
      Error(queue.PolicyDenied("denied-" <> suffix)),
    ],
    fn(outcome) {
      let assert Ok(terminal) = queue.record_landing(restored, intent, outcome)
      assert_persistence(terminal)
    },
  )
}
