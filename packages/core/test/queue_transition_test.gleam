//// Focused transition cases that complement the generated and simulated ones.

import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gantry_core/sandbox
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn action(name: String, dependencies: List(String)) -> graph.Action {
  graph.action(name, [name], [], [], dependencies, [], 10)
}

fn task(id: String, name: String, dependencies: List(String)) -> queue.Task {
  queue.whole_task(
    action(name, dependencies),
    id,
    id <> name,
    "pool",
    "image",
    sandbox.Strict,
  )
}

fn member(id: String) -> queue.Member {
  queue.Member(1, id)
}

fn waiting(state: queue.State, id: String, branch: String) -> queue.State {
  let assert Ok(#(next, _)) =
    queue.admit(
      state,
      id,
      "repo",
      "",
      "check",
      queue.Waiting(branch, [member(id)]),
      [],
    )
  next
}

fn prepare(state: queue.State, id: String) -> queue.State {
  let assert [offer] = queue.preparations(state)
  assert queue.preparation_run(offer) == id
  let candidate = queue.candidate("main", "base", id, [member(id)])
  let assert Ok(next) =
    queue.record_preparation(
      state,
      offer,
      Ok(#(candidate, [task(id, "build", [])])),
    )
  next
}

pub fn failure_skips_pending_and_the_queue_goes_quiet_test() {
  let assert Ok(#(state, _)) =
    queue.admit(queue.empty(), "r", "repo", "r", "check", queue.Build, [
      task("r", "build", []),
      task("r", "test", ["build"]),
    ])
  let assert #(state, Some(job)) = queue.claim(state, "w", "pool", 0)
  assert !queue.quiescent(state)
  let assert Ok(state) =
    queue.finish(
      state,
      "r",
      "build",
      "w",
      queue.lease_serial(job.lease),
      queue.Rejected("exit 1", "log"),
    )
  let assert Ok(run) = queue.find(state, "r")
  assert run.work
    == [
      queue.Work(
        task("r", "build", []),
        queue.Failed(queue.Reported("exit 1"), "log"),
      ),
      queue.Work(task("r", "test", ["build"]), queue.Skipped),
    ]
  assert queue.quiescent(state)
  assert queue.terminal(run)
  assert queue.claim(state, "w", "pool", 1) == #(state, None)
}

pub fn failure_text_is_capped_where_it_is_recorded_test() {
  let assert Ok(#(state, _)) =
    queue.admit(queue.empty(), "r", "repo", "r", "check", queue.Build, [
      task("r", "build", []),
    ])
  let assert #(state, Some(job)) = queue.claim(state, "w", "pool", 0)
  let assert Ok(state) =
    queue.finish(
      state,
      "r",
      "build",
      "w",
      queue.lease_serial(job.lease),
      queue.Rejected(string.repeat("é", 300_000), "log"),
    )
  let assert Ok(run) = queue.find(state, "r")
  let assert [queue.Work(_, queue.Failed(queue.Reported(detail), _))] = run.work
  assert string.byte_size(detail) <= queue.max_detail_bytes
  assert string.byte_size(detail) > queue.max_detail_bytes - 4
}

pub fn waiting_groups_prepare_in_order_when_the_lane_frees_test() {
  let state = queue.empty() |> waiting("a", "main") |> waiting("b", "main")
  let state = waiting(state, "x", "release")

  // Only the head of each lane is offered, and a waiting run holds no graph.
  let offers = queue.preparations(state)
  assert list.map(offers, queue.preparation_run) == ["a", "x"]
  let assert [offer_a, ..] = offers
  let assert Ok(state) =
    queue.record_preparation(
      state,
      offer_a,
      Ok(
        #(queue.candidate("main", "base", "a", [member("a")]), [
          task("a", "build", []),
        ]),
      ),
    )
  assert list.map(queue.preparations(state), queue.preparation_run) == ["x"]

  // A repeat of the recorded offer is refused. A refusal frees the lane.
  assert queue.record_preparation(state, offer_a, Error(queue.MemberMoved(1)))
    == Error("preparation already recorded")
  let assert #(state, Some(job)) = queue.claim(state, "w", "pool", 0)
  let assert Ok(state) =
    queue.finish(
      state,
      "a",
      "build",
      "w",
      queue.lease_serial(job.lease),
      queue.Rejected("broken", "log"),
    )
  assert list.map(queue.preparations(state), queue.preparation_run)
    == ["b", "x"]
  let assert Ok(run_b) = queue.find(state, "b")
  assert run_b.work == []
}

pub fn a_refused_preparation_is_terminal_and_frees_the_lane_test() {
  let state = queue.empty() |> waiting("a", "main") |> waiting("b", "main")
  let assert [offer] = queue.preparations(state)
  let assert Ok(state) =
    queue.record_preparation(state, offer, Error(queue.MemberMoved(1)))
  let assert Ok(run) = queue.find(state, "a")
  assert queue.phase(run) == queue.PhaseUnprepared
  assert queue.terminal(run)
  let state = prepare(state, "b")
  let assert Ok(b) = queue.find(state, "b")
  assert b.revision == "b"
}

pub fn a_prepared_candidate_must_match_its_pins_test() {
  let state = queue.empty() |> waiting("a", "main")
  let assert [offer] = queue.preparations(state)
  let wrong = queue.candidate("main", "base", "a", [queue.Member(2, "other")])
  assert queue.record_preparation(
      state,
      offer,
      Ok(#(wrong, [task("a", "build", [])])),
    )
    == Error("candidate does not match the pinned members")
}

pub fn a_provider_denial_blocks_the_landing_with_a_typed_reason_test() {
  let state = queue.empty() |> waiting("a", "main") |> prepare("a")
  let assert #(state, Some(job)) = queue.claim(state, "w", "pool", 0)
  let assert Ok(state) =
    queue.finish(
      state,
      "a",
      "build",
      "w",
      queue.lease_serial(job.lease),
      queue.Succeeded([], "log"),
    )
  let assert #(state, [intent]) = queue.landings(state)
  let assert Ok(state) =
    queue.record_landing(
      state,
      intent,
      Error(queue.PolicyDenied(string.repeat("p", 5000))),
    )
  let assert Ok(run) = queue.find(state, "a")
  let assert queue.Blocked(_, queue.PolicyDenied(detail)) = run.submission
  assert string.byte_size(detail) == queue.max_detail_bytes
  assert queue.phase(run) == queue.PhaseBlocked
  assert queue.record_landing(state, intent, Ok(Nil))
    == Error("submit intent already reconciled")
}

pub fn retention_keeps_reuse_working_after_the_run_is_dropped_test() {
  let first_task =
    queue.whole_task(
      action("build", []),
      "s",
      "shared",
      "pool",
      "image",
      sandbox.Strict,
    )
  let assert Ok(#(state, _)) =
    queue.admit(queue.empty(), "one", "repo", "s", "check", queue.Build, [
      first_task,
    ])
  let assert #(state, Some(job)) = queue.claim(state, "w", "pool", 0)
  let assert Ok(state) =
    queue.finish(
      state,
      "one",
      "build",
      "w",
      queue.lease_serial(job.lease),
      queue.Succeeded([], "log"),
    )
  let state = queue.retain(state, queue.Retention(0, 4))
  assert state.runs == []
  let assert Ok(#(state, _)) =
    queue.admit(state, "two", "repo", "s", "check", queue.Build, [first_task])
  let assert #(state, None) = queue.claim(state, "w", "pool", 5)
  let assert Ok(run) = queue.find(state, "two")
  let assert [queue.Work(_, queue.Reused(_))] = run.work
}

pub fn retention_never_drops_live_runs_test() {
  let state =
    queue.empty()
    |> waiting("a", "main")
    |> prepare("a")
    |> waiting("b", "main")
  let assert Ok(#(state, _)) =
    queue.admit(state, "bo", "repo", "bo", "check", queue.Build, [
      task("bo", "build", []),
    ])
  assert queue.retain(state, queue.Retention(0, 0)) == state
}

pub fn decoders_reject_unissued_serials_and_repeated_names_test() {
  let state = queue.empty() |> waiting("a", "main") |> prepare("a")
  let #(state, _) = queue.claim(state, "w", "pool", 0)
  let text = json.to_string(protocol.encode_state(state))
  assert json.parse(text, protocol.state_decoder()) == Ok(state)

  // A lease serial or attempt below one was never issued.
  assert bad(text, "\"serial\":1,\"worker\"", "\"serial\":0,\"worker\"")
  assert bad(text, "\"attempt\":1", "\"attempt\":0")
  assert bad(text, "\"serial\":1,\"runs\"", "\"serial\":-1,\"runs\"")
  let pending =
    json.to_string(
      protocol.encode_state(prepare(waiting(queue.empty(), "a", "main"), "a")),
    )
  assert bad(pending, "\"attempts\":0", "\"attempts\":-1")

  // Two runs may not share an ID, nor two actions a name inside one run.
  let assert Ok(run) = queue.find(state, "a")
  let doubled = queue.State(..state, runs: [run, run])
  assert json.parse(
      json.to_string(protocol.encode_state(doubled)),
      protocol.state_decoder(),
    )
    != Ok(doubled)
  let twice = queue.Run(..run, work: list.append(run.work, run.work))
  assert json.parse(
      json.to_string(protocol.encode_run(twice)),
      protocol.run_decoder(),
    )
    != Ok(twice)
}

fn bad(text: String, from: String, to: String) -> Bool {
  assert string.contains(text, from)
  case json.parse(string.replace(text, from, to), protocol.state_decoder()) {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn the_durable_image_omits_the_derived_phase_test() {
  let state = queue.empty() |> waiting("a", "main")
  let text = json.to_string(protocol.encode_state(state))
  assert !string.contains(text, "\"phase\"")
  let assert Ok(run) = queue.find(state, "a")
  assert string.contains(
    json.to_string(protocol.encode_run(run)),
    "\"phase\":\"waiting\"",
  )
}
