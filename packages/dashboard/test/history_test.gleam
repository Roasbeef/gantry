//// The history's reading of grants, results and samples, on snapshots made
//// by the core's own transitions.

import dashboard/board
import dashboard/history
import gantry_core/fleet
import gantry_core/graph
import gantry_core/queue
import gantry_core/sandbox
import gleam/option.{None, Some}
import gleam/set

fn task(name: String, needs: List(String)) -> queue.Task {
  let action = graph.Action(name, [name], [], [], needs, [], 60)
  queue.Task(
    action,
    "source",
    "recipe-" <> name,
    "linux",
    "image",
    sandbox.Strict,
  )
}

fn read(state: queue.State, now: Int, events, samples, since) {
  let snapshot =
    fleet.Fleet(now:, since:, slots: [], runs: state.runs, events:, samples:)
  history.read(snapshot, board.build(snapshot))
}

fn chain() -> queue.State {
  let assert Ok(#(state, _)) =
    queue.admit(queue.empty(), "r", "repo", "rev", "check", queue.Build, [
      task("a", []),
      task("b", ["a"]),
      task("c", []),
    ])
  state
}

pub fn a_grant_and_its_result_make_one_bar_test() {
  let state = chain()
  let h =
    read(
      state,
      1000,
      [
        fleet.Granted(1, "r", "a", "w1", "linux", 900, 1600),
        fleet.Settled(1, fleet.Succeeded, 940),
        fleet.Granted(2, "r", "c", "w2", "linux", 910, 1600),
        fleet.Settled(2, fleet.Rejected, 920),
      ],
      [],
      0,
    )
  assert history.duration(h, "r", "a") == Some(40)
  assert history.duration(h, "r", "b") == None
  let assert [slow, ..] = history.slowest(h, 5)
  assert slow.action == "a"
  let assert [failure] = history.failures(h, 5)
  assert failure.outcome == history.Failed
}

pub fn a_grant_without_a_result_lapses_unless_still_leased_test() {
  let state = chain()
  let assert #(state, Some(job)) = queue.claim(state, "w1", "linux", 900)
  let serial = queue.lease_serial(job.lease)
  let h =
    read(
      state,
      1000,
      [
        fleet.Granted(
          serial,
          "r",
          job.task.action.name,
          "w1",
          "linux",
          900,
          1600,
        ),
        fleet.Granted(99, "r", "c", "w2", "linux", 100, 700),
      ],
      [],
      0,
    )
  let assert [running] = history.lane(h, "w1")
  assert running.outcome == history.Running
  assert running.end == 1000
  let assert [lapsed] = history.lane(h, "w2")
  assert lapsed.outcome == history.Lapsed
  assert lapsed.end == 700
}

pub fn a_live_lease_the_history_forgot_is_recovered_test() {
  let state = chain()
  let assert #(state, Some(_)) = queue.claim(state, "w1", "linux", 950)
  let h = read(state, 1000, [], [], 980)
  let assert [bar] = history.lane(h, "w1")
  assert bar.start == 950
  assert bar.outcome == history.Running
}

pub fn backlog_since_stops_at_an_empty_sample_or_a_gap_test() {
  let h =
    read(
      chain(),
      1000,
      [],
      [
        fleet.Sample(960, [#("linux", 0)]),
        fleet.Sample(970, [#("linux", 2)]),
        fleet.Sample(980, [#("linux", 3)]),
        fleet.Sample(990, [#("linux", 1)]),
        fleet.Sample(998, [#("linux", 4)]),
      ],
      0,
    )
  assert history.backlog_since(h, "linux") == Some(970)
  assert history.backlog_since(h, "gpu") == None
  let gapped =
    read(
      chain(),
      1000,
      [],
      [fleet.Sample(900, [#("linux", 2)]), fleet.Sample(995, [#("linux", 2)])],
      0,
    )
  assert history.backlog_since(gapped, "linux") == Some(995)
}

pub fn throughput_counts_results_per_minute_test() {
  let h =
    read(
      chain(),
      1000,
      [
        fleet.Settled(1, fleet.Succeeded, 990),
        fleet.Settled(2, fleet.Succeeded, 995),
        fleet.Settled(3, fleet.Rejected, 50),
      ],
      [],
      0,
    )
  let minutes = history.throughput(h)
  assert minutes != []
  let assert [_, ..] = minutes
  assert sum(minutes) == 2
}

fn sum(values: List(Int)) -> Int {
  case values {
    [] -> 0
    [first, ..rest] -> first + sum(rest)
  }
}

pub fn the_critical_path_follows_the_longest_chain_test() {
  let state = chain()
  let snapshot =
    fleet.Fleet(
      1000,
      0,
      [],
      state.runs,
      [
        fleet.Granted(1, "r", "c", "w1", "linux", 100, 900),
        fleet.Settled(1, fleet.Succeeded, 400),
      ],
      [],
    )
  let b = board.build(snapshot)
  let h = history.read(snapshot, b)
  let assert Ok(run) = board.find(b, "r")
  // c took 300 s alone, which beats the a then b chain at 1 s each.
  assert history.critical(h, run) == set.from_list(["c"])
  let quiet = history.read(fleet.Fleet(..snapshot, events: []), b)
  assert history.critical(quiet, run) == set.from_list(["a", "b"])
}
