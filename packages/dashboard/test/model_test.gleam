//// The page's transitions on controller answers, and the timing and layout
//// decisions the view draws from.

import dashboard/board
import dashboard/layout
import dashboard/model
import gantry_core/fleet
import gantry_core/graph
import gantry_core/queue
import gantry_core/sandbox
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn task(name: String, needs: List(String)) -> queue.Task {
  let action = graph.action(name, [name], [], [], needs, [], 60)
  queue.whole_task(
    action,
    "source",
    "recipe-" <> name,
    "linux",
    "image",
    sandbox.Strict,
  )
}

/// A two-action chain, its first action leased at `granted`.
fn leased(granted: Int) -> queue.State {
  let assert Ok(#(state, _)) =
    queue.admit(queue.empty(), "r", "repo", "rev", "check", queue.Build, [
      task("build", []),
      task("test", ["build"]),
    ])
  let assert #(state, Some(_)) = queue.claim(state, "w1", "linux", granted)
  state
}

fn body(state: queue.State, now: Int) -> String {
  fleet.Fleet(
    now:,
    since: 0,
    slots: [],
    runs: state.runs,
    events: [],
    samples: [],
  )
  |> fleet.encode
  |> json.to_string
}

pub fn a_token_starts_connecting_and_none_signs_out_test() {
  assert model.initial("").connection == model.SignedOut(None)
  assert model.initial("t").connection == model.Connecting
  assert model.signed_in(model.initial("t"))
  assert !model.signed_in(model.initial(""))
}

pub fn a_snapshot_goes_live_and_chooses_nothing_test() {
  let m = model.receive(model.initial("t"), "t", 200, body(leased(10), 12))
  assert m.connection == model.Live
  assert m.chosen_run == None
  assert !m.in_flight
}

pub fn a_refused_token_signs_out_with_a_notice_test() {
  let m = model.receive(model.initial("t"), "t", 401, "{\"error\":\"no\"}")
  let assert model.SignedOut(Some(_)) = m.connection
  assert m.token == ""
}

pub fn an_error_keeps_the_last_board_and_marks_it_stale_test() {
  let live = model.receive(model.initial("t"), "t", 200, body(leased(10), 12))
  let m =
    model.receive(live, "t", 503, "{\"error\":\"queue quorum unavailable\"}")
  assert m.connection == model.Lost("HTTP 503: queue quorum unavailable")
  assert m.board == live.board
  let m = model.receive(live, "t", 0, "Failed to fetch")
  assert m.connection
    == model.Lost("cannot reach the controller: Failed to fetch")
}

pub fn an_unreadable_snapshot_is_lost_not_fatal_test() {
  let m = model.receive(model.initial("t"), "t", 200, "{\"now\":-1}")
  let assert model.Lost(_) = m.connection
}

pub fn choosing_an_action_with_a_log_asks_for_it_test() {
  let state = leased(10)
  let assert Ok(state) =
    queue.finish(state, "r", "build", "w1", 1, queue.Rejected("boom", "abc"))
  let m = model.receive(model.initial("t"), "t", 200, body(state, 20))
  let #(m, digest) = model.choose_action(m, "r", "build")
  assert digest == Some("abc")
  assert m.log == model.Loading("abc")
  assert m.tab == model.DetailTab
  // A stale answer for another digest is dropped; the wanted one lands.
  assert model.receive_log(m, "other", 200, "x").log == model.Loading("abc")
  assert model.receive_log(m, "abc", 200, "line").log
    == model.Loaded("abc", "line")
  assert model.receive_log(m, "abc", 404, "{\"error\":\"blob unavailable\"}").log
    == model.LogFailed("abc", "HTTP 404: blob unavailable")
  let #(m, none) = model.choose_action(m, "r", "test")
  assert none == None
  assert m.log == model.NoLog
}

pub fn a_long_log_keeps_its_tail_test() {
  assert model.tail("a\nb\nc", 2) == "b\nc"
  assert model.tail("a", 2) == "a"
  let long = list.repeat("x", 500) |> string.join("\n")
  assert list.length(string.split(model.tail(long, 400), "\n")) == 400
}

pub fn layout_places_layers_in_columns_and_links_each_need_test() {
  let state = leased(0)
  let b = board.build(fleet.Fleet(1, 0, [], state.runs, [], []))
  let assert Ok(run) = board.find(b, "r")
  let placed = layout.place(run.actions)
  let assert [first, second] = placed.nodes
  assert first.x < second.x
  assert first.y == second.y
  let assert [edge] = placed.edges
  assert edge.from == "build"
  assert edge.to == "test"
  assert string.starts_with(edge.path, "M")
  assert placed.width >= second.x + layout.node_width
  assert layout.place([]).nodes == []
}

pub fn a_broken_run_opens_on_its_failed_action_test() {
  let state = leased(10)
  let assert Ok(state) =
    queue.finish(state, "r", "build", "w1", 1, queue.Rejected("boom", "abc"))
  let m = model.receive(model.initial("t"), "t", 200, body(state, 20))
  let #(m, digest) = model.choose_run(m, "r")
  assert digest == Some("abc")
  assert m.chosen_action == Some("build")
  assert m.log == model.Loading("abc")
}

pub fn a_live_run_opens_with_no_action_test() {
  let m = model.receive(model.initial("t"), "t", 200, body(leased(10), 12))
  let #(m, digest) = model.choose_run(m, "r")
  assert digest == None
  assert m.chosen_action == None
}

pub fn runs_split_into_live_broken_and_settled_bands_test() {
  let live = leased(10)
  let assert Ok(#(state, _)) =
    queue.admit(live, "bad", "repo", "rev", "check", queue.Build, [
      task("other", []),
    ])
  let assert #(state, Some(job)) = queue.claim(state, "w2", "linux", 11)
  let assert Ok(state) =
    queue.finish(
      state,
      "bad",
      "other",
      "w2",
      queue.lease_serial(job.lease),
      queue.Rejected("no", "log"),
    )
  let b = board.build(fleet.Fleet(12, 0, [], state.runs, [], []))
  let #(l, broken, settled) = board.bands(b.runs)
  assert list.map(l, fn(r) { r.id }) == ["r"]
  assert list.map(broken, fn(r) { r.id }) == ["bad"]
  assert settled == []
}

pub fn an_answer_for_an_earlier_token_is_dropped_test() {
  let live = model.receive(model.initial("t"), "t", 200, body(leased(10), 12))
  // After a sign-out, an answer still in flight restores nothing.
  let out = model.initial("")
  assert model.receive(out, "t", 200, body(leased(10), 12)) == out
  // After a token change, the old token's refusal does not sign out.
  let next = model.initial("u")
  assert model.receive(next, "t", 401, "{}") == next
  assert model.receive(live, "t", 503, "{}").connection != model.Live
}
