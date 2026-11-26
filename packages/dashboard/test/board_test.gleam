//// The board's decisions on snapshots made by the core's own transitions, so
//// each case is a state the controller can really be in.

import dashboard/board
import gantry_core/fleet
import gantry_core/graph
import gantry_core/queue
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn task(name: String, needs: List(String), pool: String) -> queue.Task {
  let action = graph.Action(name, [name], [], [], needs, [], 60)
  queue.Task(action, "source", "recipe-" <> name, pool, "image")
}

/// A build `fan` with one root and `width` leaves that depend on it.
fn fan_out(state: queue.State, id: String, width: Int, pool: String) {
  let leaves =
    list.repeat(Nil, width)
    |> list.index_map(fn(_, i) {
      task("leaf-" <> string.inspect(i), ["root"], pool)
    })
  let assert Ok(#(state, _)) =
    queue.admit(state, id, "repo", "rev", "check", queue.Build, [
      task("root", [], pool),
      ..leaves
    ])
  state
}

fn pass(state: queue.State, worker: String, pool: String, now: Int) {
  let assert #(state, Some(job)) = queue.claim(state, worker, pool, now)
  let assert Ok(state) =
    queue.finish(
      state,
      job.run,
      job.task.action.name,
      worker,
      queue.lease_serial(job.lease),
      queue.Succeeded([], "log-" <> job.task.action.name),
    )
  state
}

fn snapshot(state: queue.State, slots: List(fleet.Slot), now: Int) {
  board.build(fleet.Fleet(now:, slots:, runs: state.runs, proofs: 0))
}

fn pool_named(b: board.Board, name: String) -> board.Pool {
  let assert Ok(pool) = list.find(b.pools, fn(p) { p.name == name })
  pool
}

pub fn a_fan_out_lays_its_leaves_in_the_second_layer_test() {
  let state = fan_out(queue.empty(), "fan", 4, "linux")
  let state = pass(state, "w1", "linux", 100)
  let b =
    snapshot(state, [fleet.Slot("w1", None, fleet.Polled("linux", 100))], 101)
  let assert Ok(run) = board.find(b, "fan")
  assert run.layers == 2
  let assert [[root], leaves] = board.by_layer(run.actions)
  assert root.cell == board.Passed
  assert list.length(leaves) == 4
  assert list.all(leaves, fn(a) { a.cell == board.Ready })
  assert run.diagnosis
    == board.Diagnosis(board.Moving, "4 actions ready to dispatch")
}

pub fn ready_work_with_no_polling_slot_is_starved_test() {
  let state = fan_out(queue.empty(), "gpu-run", 0, "gpu")
  let b =
    snapshot(state, [fleet.Slot("w1", None, fleet.Polled("linux", 100))], 101)
  let gpu = pool_named(b, "gpu")
  assert gpu.verdict == board.Starved
  assert gpu.ready == 1
  let assert Ok(run) = board.find(b, "gpu-run")
  assert run.diagnosis.health == board.Stalled
  assert string.contains(run.diagnosis.text, "no live slot polls it")
}

pub fn ready_work_behind_busy_slots_is_saturated_test() {
  let state = fan_out(queue.empty(), "fan", 3, "linux")
  let state = pass(state, "w1", "linux", 100)
  let assert #(state, Some(_)) = queue.claim(state, "w1", "linux", 110)
  let b =
    snapshot(
      state,
      [fleet.Slot("w1", Some("box"), fleet.Polled("linux", 110))],
      111,
    )
  let linux = pool_named(b, "linux")
  assert linux.verdict == board.Saturated
  assert linux.busy == 1
  assert linux.free == 0
  assert linux.ready == 2
  let assert Ok(run) = board.find(b, "fan")
  assert string.contains(run.diagnosis.text, "pool linux is full")
  let assert [slot] = b.slots
  let assert board.Working("fan", _, holder, 60) = slot.occupation
  assert holder.host == Some("box")
  assert holder.granted == 110
}

pub fn a_free_live_slot_drains_ready_work_test() {
  assert board.verdict(ready: 2, busy: 1, free: 1, live: 2) == board.Draining
  assert board.verdict(ready: 0, busy: 1, free: 0, live: 1) == board.Busy
  assert board.verdict(ready: 0, busy: 0, free: 0, live: 0) == board.Idle
  assert board.verdict(ready: 1, busy: 0, free: 0, live: 0) == board.Starved
}

pub fn a_slot_silent_past_the_window_is_quiet_test() {
  let b =
    snapshot(
      queue.empty(),
      [
        fleet.Slot("a", None, fleet.Polled("linux", 100)),
        fleet.Slot("b", None, fleet.Polled("linux", 200)),
        fleet.Slot("c", None, fleet.Unseen),
      ],
      200,
    )
  let assert [a, b_slot, c] = b.slots
  assert a.occupation == board.Quiet("linux", 100)
  assert b_slot.occupation == board.Waiting("linux", 200)
  assert c.occupation == board.Unseen
  let linux = pool_named(b, "linux")
  assert linux.live == 1
  assert linux.known == 2
}

pub fn a_last_attempt_near_its_deadline_is_called_out_test() {
  let state = fan_out(queue.empty(), "late", 0, "linux")
  // Two lapsed leases bring the action to its last attempt.
  let assert #(state, Some(first)) = queue.claim(state, "w1", "linux", 0)
  let after_first = queue.lease_until(first.lease) + 1
  let assert #(state, Some(second)) =
    queue.claim(state, "w1", "linux", after_first)
  let after_second = queue.lease_until(second.lease) + 1
  let assert #(state, Some(third)) =
    queue.claim(state, "w1", "linux", after_second)
  assert queue.lease_attempt(third.lease) == 3
  let now = queue.lease_until(third.lease) - 30
  let b =
    snapshot(state, [fleet.Slot("w1", None, fleet.Polled("linux", now))], now)
  let assert Ok(run) = board.find(b, "late")
  assert run.diagnosis.health == board.Stalled
  assert string.contains(run.diagnosis.text, "last attempt")
  assert string.contains(run.diagnosis.text, "30s")
}

pub fn a_failure_names_the_action_and_skips_the_rest_test() {
  let state = fan_out(queue.empty(), "bad", 2, "linux")
  let assert #(state, Some(job)) = queue.claim(state, "w1", "linux", 0)
  let assert Ok(state) =
    queue.finish(
      state,
      "bad",
      "root",
      "w1",
      queue.lease_serial(job.lease),
      queue.Rejected("exit 2\nmore", "log"),
    )
  let b = snapshot(state, [], 1)
  let assert Ok(run) = board.find(b, "bad")
  assert run.diagnosis == board.Diagnosis(board.Broken, "root failed: exit 2")
  assert board.tally(run.actions) == [#(board.Failed, 1), #(board.Skipped, 2)]
}

pub fn a_cache_hit_is_counted_as_reused_test() {
  let state = fan_out(queue.empty(), "one", 0, "linux")
  let state = pass(state, "w1", "linux", 0)
  // The same recipe in a second run reuses the first run's proof.
  let state = fan_out(state, "two", 0, "linux")
  let assert #(state, None) = queue.claim(state, "w1", "linux", 5)
  let b = snapshot(state, [], 6)
  let assert Ok(two) = board.find(b, "two")
  assert two.diagnosis
    == board.Diagnosis(board.Settled, "passed, 1 of 1 from cache")
  assert b.totals.reused == 1
  assert b.totals.passed == 1
}

pub fn a_group_waits_behind_its_lane_head_test() {
  let member = fn(pull) { queue.Member(pull, "head") }
  let assert Ok(#(state, _)) =
    queue.admit(
      queue.empty(),
      "g1",
      "repo",
      "",
      "check",
      queue.Waiting("main", [member(1)]),
      [],
    )
  let assert Ok(#(state, _)) =
    queue.admit(
      state,
      "g2",
      "repo",
      "",
      "check",
      queue.Waiting("main", [member(2)]),
      [],
    )
  let b = snapshot(state, [], 0)
  let assert Ok(head) = board.find(b, "g1")
  let assert Ok(next) = board.find(b, "g2")
  assert head.diagnosis.health == board.Moving
  assert next.diagnosis
    == board.Diagnosis(board.Stalled, "behind g1 (waiting) in lane repo:main")
  assert next.signal == board.SignalWaiting
  assert next.members == [2]
}

pub fn live_runs_come_before_finished_ones_test() {
  let state = fan_out(queue.empty(), "done", 0, "linux")
  let state = pass(state, "w1", "linux", 0)
  let state = fan_out(state, "open", 1, "other")
  let b = snapshot(state, [], 1)
  assert list.map(b.runs, fn(run) { run.id }) == ["open", "done"]
}

pub fn slots_sort_by_occupation_then_deadline_test() {
  let state = fan_out(queue.empty(), "fan", 2, "linux")
  let state = pass(state, "w1", "linux", 0)
  let assert #(state, Some(_)) = queue.claim(state, "zz", "linux", 10)
  let assert #(state, Some(_)) = queue.claim(state, "aa", "linux", 20)
  let b =
    snapshot(
      state,
      [
        fleet.Slot("idle", None, fleet.Polled("linux", 20)),
        fleet.Slot("aa", None, fleet.Polled("linux", 20)),
        fleet.Slot("zz", None, fleet.Polled("linux", 10)),
      ],
      21,
    )
  assert list.map(board.rail_order(b.slots), fn(s) { s.worker })
    == ["zz", "aa", "idle"]
}

pub fn spans_read_at_a_glance_test() {
  assert board.span(-3) == "0s"
  assert board.span(42) == "42s"
  assert board.span(185) == "3m 05s"
  assert board.span(3720) == "1h 02m"
}
