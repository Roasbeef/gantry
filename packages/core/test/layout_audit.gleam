//// Runs one queue operation twice, once on the whole state and once through
//// the indexed layout on a reference image, and reports any difference in
//// the receipt, the runs, the proofs, the serial, or the index entries. A
//// simulation calls `replay` with the state before each committed operation.

import gantry_core/image.{type Image}
import gantry_core/layout
import gantry_core/queue
import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/set
import gleam/string

/// One committed queue operation with the inputs a controller supplied.
pub type Op {
  Claim(worker: String, pool: String, now: Int)
  Expire(now: Int)
  Finish(
    run: String,
    action: String,
    worker: String,
    serial: Int,
    completion: queue.Completion,
  )
  Prepare(
    preparation: queue.Preparation,
    outcome: Result(#(queue.Candidate, List(queue.Task)), queue.PrepareFailure),
  )
  Landings
  RecordLanding(intent: queue.Intent, outcome: Result(Nil, queue.Block))
  Retain(retention: queue.Retention)
}

/// An image holding exactly the given whole state.
pub fn import_state(state: queue.State) -> Image {
  image.apply(image.empty(), layout.import_state(state))
}

/// Admit a run on both sides and return the image, or the first difference.
pub fn admit(
  store: Image,
  state: queue.State,
  id: String,
  repo: String,
  revision: String,
  target: String,
  submission: queue.Submission,
  tasks: List(queue.Task),
) -> Result(Image, String) {
  let expected =
    queue.admit(state, id, repo, revision, target, submission, tasks)
  let planned =
    layout.admit(
      image.reader(store),
      id,
      repo,
      revision,
      target,
      submission,
      tasks,
    )
  case expected, planned {
    Ok(#(after, run)), Ok(plan) ->
      conclude(store, plan, layout.receipt(plan) == run, after, "admit")
    Error(_), Error(layout.Refused(_)) -> Ok(store)
    Error(_), Error(layout.Unreadable(detail))
    | Error(_), Error(layout.Corrupt(detail))
    -> Error("admit: unreadable: " <> detail)
    Ok(_), Error(_) -> Error("admit: layout refused an accepted run")
    Error(_), Ok(_) -> Error("admit: layout accepted a refused run")
  }
}

/// Apply the operation to the whole `state` and to the image, and return the
/// new image, or the first difference found.
pub fn replay(
  store: Image,
  state: queue.State,
  op: Op,
) -> Result(Image, String) {
  let reader = image.reader(store)
  case op {
    Claim(worker, pool, now) -> {
      let #(after, receipt) = queue.claim(state, worker, pool, now)
      planned(store, layout.claim(reader, worker, pool, now), "claim", fn(plan) {
        case layout.receipt(plan) == receipt {
          True -> conclude(store, plan, True, after, "claim")
          False ->
            Error(
              "claim: receipts differ: whole="
              <> string.inspect(receipt)
              <> " layout="
              <> string.inspect(layout.receipt(plan))
              <> " worker="
              <> worker
              <> " now="
              <> string.inspect(now)
              <> " state="
              <> string.inspect(state),
            )
        }
      })
    }
    // Only a claim expires leases, so a quiet claim by a stranger is expiry.
    Expire(now) -> {
      let after = queue.expire(state, now)
      let pool = "\u{0}pool"
      planned(
        store,
        layout.claim(reader, "\u{0}expire", pool, now),
        "expire",
        fn(plan) {
          conclude(store, plan, layout.receipt(plan) == None, after, "expire")
        },
      )
    }
    Finish(run, action, worker, serial, completion) ->
      agree(
        store,
        queue.finish(state, run, action, worker, serial, completion),
        layout.finish(reader, run, action, worker, serial, completion),
        "finish",
      )
    Prepare(preparation, outcome) ->
      agree(
        store,
        queue.record_preparation(state, preparation, outcome),
        layout.record_preparation(reader, preparation, outcome),
        "prepare",
      )
    Landings -> {
      let #(after, intents) = queue.landings(state)
      planned(store, layout.landings(reader), "landings", fn(plan) {
        conclude(
          store,
          plan,
          layout.receipt(plan) == intents,
          after,
          "landings",
        )
      })
    }
    RecordLanding(intent, outcome) ->
      agree(
        store,
        queue.record_landing(state, intent, outcome),
        layout.record_landing(reader, intent, outcome),
        "record_landing",
      )
    Retain(retention) -> {
      let after = queue.retain(state, retention)
      planned(
        store,
        layout.retain(reader, retention, 1_000_000),
        "retain",
        fn(plan) {
          conclude(store, plan, !layout.receipt(plan), after, "retain")
        },
      )
    }
  }
}

/// Turn a planning failure into a difference, or continue with the plan.
fn planned(
  _store: Image,
  outcome: Result(layout.Plan(a), layout.Failure),
  label: String,
  then: fn(layout.Plan(a)) -> Result(Image, String),
) -> Result(Image, String) {
  case outcome {
    Ok(plan) -> then(plan)
    Error(layout.Refused(detail)) -> Error(label <> ": refused: " <> detail)
    Error(layout.Unreadable(detail)) | Error(layout.Corrupt(detail)) ->
      Error(label <> ": unreadable: " <> detail)
  }
}

/// Both sides must accept or both must refuse.
fn agree(
  store: Image,
  expected: Result(queue.State, String),
  outcome: Result(layout.Plan(Nil), layout.Failure),
  label: String,
) -> Result(Image, String) {
  case expected, outcome {
    Ok(after), Ok(plan) -> conclude(store, plan, True, after, label)
    Error(_), Error(layout.Refused(_)) -> Ok(store)
    Error(_), Error(layout.Unreadable(detail))
    | Error(_), Error(layout.Corrupt(detail))
    -> Error(label <> ": unreadable: " <> detail)
    Ok(_), Error(_) -> Error(label <> ": layout refused an accepted change")
    Error(_), Ok(_) -> Error(label <> ": layout accepted a refused change")
  }
}

/// Commit a plan on the image and compare the result with `after`.
fn conclude(
  store: Image,
  plan: layout.Plan(a),
  receipt_matches: Bool,
  after: queue.State,
  label: String,
) -> Result(Image, String) {
  use next <- result.try(
    image.commit(store, plan)
    |> result.replace_error(label <> ": an expectation failed on a quiet store"),
  )
  use found <- result.try(
    layout.materialize(image.reader(next))
    |> result.map_error(fn(_) { label <> ": image does not decode" }),
  )
  case receipt_matches, found == after, indexed(next, after) {
    False, _, _ -> Error(label <> ": receipts differ")
    True, False, _ -> Error(label <> ": state differs")
    True, True, False -> Error(label <> ": index differs from runs")
    True, True, True -> Ok(next)
  }
}

/// Whether the index keys of the image are exactly those the runs derive.
fn indexed(store: Image, state: queue.State) -> Bool {
  let numbered = result.unwrap(layout.numbered(image.reader(store)), [])
  let wanted =
    list.flat_map(numbered, fn(pair) { layout.entries(pair.0, pair.1) })
    |> dict.from_list
  let _ = state
  let present =
    image.keys(store)
    |> list.filter(fn(key) {
      case key {
        ["ready", ..]
        | ["active", ..]
        | ["waiting", ..]
        | ["holds", ..]
        | ["landing", ..]
        | ["done", ..] -> True
        _ -> False
      }
    })
  set.from_list(present) == set.from_list(dict.keys(wanted))
  && list.all(dict.to_list(wanted), fn(pair) {
    image.get(store, pair.0) == Ok(pair.1)
  })
}
