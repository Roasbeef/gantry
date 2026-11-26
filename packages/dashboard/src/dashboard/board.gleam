//// The board is every decision the dashboard draws, made from one fleet
//// snapshot and nothing else: each action's state, each pool's demand
//// against its supply, each slot's occupation, and one diagnosis per run
//// that names why it is or is not moving. It imports no Lustre and no DOM, so
//// its tests run under Node without a page.
////
//// ## Flow
////
//// `build` is the one entry: it places each run's actions with their cells
//// and layers, reads each slot's occupation from the leases, derives each
//// pool's numbers and `verdict`, and only then calls `diagnose` on each run,
//// because a run's diagnosis depends on its pools. The view then reads
//// `bands`, `by_layer`, `tally`, `rail_order` and `slot_pool` from the
//// finished board.
////
//// ## What the snapshot cannot say
////
//// Steps carry no timestamps, so a finished action's duration is known only
//// when `timing` saw it leased (see `observe`). A lease records no start
//// beyond its grant, so a leased action and a running one look the same and
//// the board calls both `Active`. A slot's pool is known only once this
//// controller served one of its polls, so a slot it never heard from is
//// `Unseen`, never idle.
////
//// ## Pool verdicts
////
//// | Verdict | Ready actions | Live free slots | Live slots |
//// | --- | --- | --- | --- |
//// | `Starved` | some | none | none |
//// | `Saturated` | some | none | some |
//// | `Draining` | some | some | some |
//// | `Busy` | none | any | some lease |
//// | `Idle` | none | any | no lease |

import gantry_core/fleet.{type Fleet}
import gantry_core/queue.{type Run}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string

/// How long after its latest poll an idle slot still counts as live. An idle
/// slot polls at least every 2 s, so missing several in a row means it is
/// stopped, wedged, or polling another controller.
pub const live_window = 15

/// How close to its deadline a lease must be before the board warns.
pub const deadline_warning = 60

/// One action's state as the board draws it.
pub type Cell {
  /// Waiting on an action it depends on.
  Blocked

  /// Every prerequisite passed and a slot in its pool may lease it now.
  Ready

  /// A slot holds the lease.
  Active

  /// A worker's verified result.
  Passed

  /// A stored proof was reused: a cache hit.
  Reused

  /// The worker rejected the action.
  Failed

  /// The lease lapsed on the last permitted attempt.
  Expired

  /// Another action failed first.
  Skipped
}

/// The lease behind an `Active` cell.
pub type Holder {
  Holder(
    worker: String,
    host: Option(String),
    attempt: Int,
    granted: Int,
    until: Int,
  )
}

/// One action, placed in its layer of the run's graph.
pub type Action {
  Action(
    name: String,
    cell: Cell,
    pool: String,
    layer: Int,
    argv: List(String),
    needs: List(String),
    timeout: Int,
    holder: Option(Holder),
    log: Option(String),
    reason: Option(String),
    attempts: Int,
  )
}

/// A pool's demand against its supply, and the verdict they give.
pub type Pool {
  Pool(
    name: String,
    ready: Int,
    busy: Int,
    free: Int,
    live: Int,
    known: Int,
    verdict: Verdict,
  )
}

/// What a pool's numbers mean for work waiting in it.
pub type Verdict {
  /// Work is ready and no live slot polls the pool.
  Starved

  /// Work is ready and every live slot holds a lease.
  Saturated

  /// Work is ready and a live slot is free to take it.
  Draining

  /// Nothing is ready and some slot holds a lease.
  Busy

  /// Nothing is ready and nothing is leased.
  Idle
}

/// What one slot is doing, as far as this controller knows.
pub type Occupation {
  /// It holds the lease on `action` of `run`.
  Working(run: String, action: String, holder: Holder, timeout: Int)

  /// It polled recently and holds nothing.
  Waiting(pool: String, at: Int)

  /// Its latest poll is older than `live_window` and it holds nothing.
  Quiet(pool: String, at: Int)

  /// This controller has not served a poll from it.
  Unseen
}

/// One slot row.
pub type Slot {
  Slot(worker: String, host: Option(String), occupation: Occupation)
}

/// How a run stands: moving, stalled for a named cause, or finished.
pub type Health {
  /// Work is being done or handed out.
  Moving

  /// Nothing can move until the named cause clears.
  Stalled

  /// The run reached a terminal state that passed or landed.
  Settled

  /// The run reached a terminal state that failed or was refused.
  Broken
}

/// One line saying why a run is where it is, with its evidence.
pub type Diagnosis {
  Diagnosis(health: Health, text: String)
}

/// The landing signal at the end of a group's lane.
pub type Signal {
  NoLane
  SignalWaiting
  SignalQueued
  SignalLanding
  SignalLanded
  SignalBlocked
  SignalUnprepared
}

/// One run row with its graph.
pub type RunRow {
  RunRow(
    id: String,
    repo: String,
    target: String,
    revision: String,
    phase: queue.Phase,
    signal: Signal,
    lane: Option(String),
    members: List(Int),
    actions: List(Action),
    layers: Int,
    diagnosis: Diagnosis,
  )
}

/// Totals for the bar across the top.
pub type Totals {
  Totals(
    live_runs: Int,
    ready: Int,
    active: Int,
    live_slots: Int,
    slots: Int,
    passed: Int,
    reused: Int,
    proofs: Int,
  )
}

/// Everything the page draws from one snapshot.
pub type Board {
  Board(
    now: Int,
    totals: Totals,
    pools: List(Pool),
    slots: List(Slot),
    runs: List(RunRow),
  )
}

/// Build the board from a snapshot. Runs come newest first, live before
/// finished, so a stuck run is never below the fold behind settled ones.
///
/// ## Examples
///
/// ```gleam
/// // board.build(snapshot).pools
/// ```
pub fn build(snapshot: Fleet) -> Board {
  let hosts =
    list.map(snapshot.slots, fn(slot) { #(slot.worker, slot.host) })
    |> dict.from_list
  let rows = list.map(snapshot.runs, row(_, hosts))
  let slots = list.map(snapshot.slots, slot(_, rows, snapshot.now))
  let pools = pools(rows, slots)
  let rows =
    list.map(rows, fn(run) {
      RunRow(..run, diagnosis: diagnose(run, rows, pools, snapshot.now))
    })
  Board(
    now: snapshot.now,
    totals: totals(rows, slots, snapshot.proofs),
    pools:,
    slots:,
    runs: order_runs(rows),
  )
}

/// Find one run's row.
///
/// ## Examples
///
/// ```gleam
/// // board.find(board, "check-1")
/// ```
pub fn find(board: Board, id: String) -> Result(RunRow, Nil) {
  list.find(board.runs, fn(run) { run.id == id })
}

/// Whether a run can still change.
///
/// ## Examples
///
/// ```gleam
/// // board.live(row)
/// ```
pub fn live(run: RunRow) -> Bool {
  case run.diagnosis.health {
    Moving | Stalled -> True
    Settled | Broken -> False
  }
}

/// Split runs into the list's three bands, each in board order: live runs
/// (moving or stalled), then broken ones, then settled ones. A failure stays
/// above the fold however many settled runs are retained.
///
/// ## Examples
///
/// ```gleam
/// // let #(live, broken, settled) = board.bands(board.runs)
/// ```
pub fn bands(
  runs: List(RunRow),
) -> #(List(RunRow), List(RunRow), List(RunRow)) {
  let of = fn(health) {
    list.filter(runs, fn(run) { run.diagnosis.health == health })
  }
  #(list.filter(runs, live), of(Broken), of(Settled))
}

/// The first failed or expired action of a run, which holds the run's log of
/// interest.
///
/// ## Examples
///
/// ```gleam
/// // board.first_failure(row)
/// ```
pub fn first_failure(run: RunRow) -> Result(Action, Nil) {
  list.find(run.actions, fn(a) { a.cell == Failed || a.cell == Expired })
}

/// The short word for a cell, used in labels and the legend.
///
/// ## Examples
///
/// ```gleam
/// board.cell_label(board.Reused) == "cached"
/// ```
pub fn cell_label(cell: Cell) -> String {
  case cell {
    Blocked -> "blocked"
    Ready -> "ready"
    Active -> "active"
    Passed -> "passed"
    Reused -> "cached"
    Failed -> "failed"
    Expired -> "expired"
    Skipped -> "skipped"
  }
}

/// The short word for a verdict.
///
/// ## Examples
///
/// ```gleam
/// board.verdict_label(board.Starved) == "starved"
/// ```
pub fn verdict_label(verdict: Verdict) -> String {
  case verdict {
    Starved -> "starved"
    Saturated -> "saturated"
    Draining -> "draining"
    Busy -> "busy"
    Idle -> "idle"
  }
}

/// The short word for a landing signal.
///
/// ## Examples
///
/// ```gleam
/// board.signal_label(board.SignalLanding) == "landing"
/// ```
pub fn signal_label(signal: Signal) -> String {
  case signal {
    NoLane -> "build"
    SignalWaiting -> "waiting"
    SignalQueued -> "queued"
    SignalLanding -> "landing"
    SignalLanded -> "landed"
    SignalBlocked -> "blocked"
    SignalUnprepared -> "unprepared"
  }
}

/// The phase's word, matching the controller's spelling.
///
/// ## Examples
///
/// ```gleam
/// board.phase_label(queue.PhasePending) == "pending"
/// ```
pub fn phase_label(phase: queue.Phase) -> String {
  case phase {
    queue.PhaseWaiting -> "waiting"
    queue.PhasePending -> "pending"
    queue.PhasePassed -> "passed"
    queue.PhaseFailed -> "failed"
    queue.PhaseLanding -> "landing"
    queue.PhaseLanded -> "landed"
    queue.PhaseBlocked -> "blocked"
    queue.PhaseUnprepared -> "unprepared"
  }
}

/// Count a run's actions in each state, in the board's fixed state order.
///
/// ## Examples
///
/// ```gleam
/// // board.tally(row.actions)
/// ```
pub fn tally(actions: List(Action)) -> List(#(Cell, Int)) {
  [Failed, Expired, Active, Ready, Blocked, Passed, Reused, Skipped]
  |> list.map(fn(cell) {
    #(cell, list.count(actions, fn(action) { action.cell == cell }))
  })
  |> list.filter(fn(pair) { pair.1 > 0 })
}

/// Group a run's actions by layer, first layer first.
///
/// ## Examples
///
/// ```gleam
/// // board.by_layer(row.actions)
/// ```
pub fn by_layer(actions: List(Action)) -> List(List(Action)) {
  actions
  |> list.map(fn(action) { action.layer })
  |> list.unique
  |> list.sort(int.compare)
  |> list.map(fn(layer) {
    list.filter(actions, fn(action) { action.layer == layer })
  })
}

/// Format a span of seconds compactly: `42s`, `3m 05s`, `1h 02m`.
///
/// ## Examples
///
/// ```gleam
/// board.span(185) == "3m 05s"
/// ```
pub fn span(seconds: Int) -> String {
  let seconds = int.max(seconds, 0)

  // The span is seconds only, minutes and seconds, or hours and minutes.
  case seconds < 60, seconds < 3600 {
    True, _ -> int.to_string(seconds) <> "s"
    False, True ->
      int.to_string(seconds / 60) <> "m " <> pad(seconds % 60) <> "s"
    False, False ->
      int.to_string(seconds / 3600) <> "h " <> pad(seconds % 3600 / 60) <> "m"
  }
}

fn pad(value: Int) -> String {
  string.pad_start(int.to_string(value), 2, "0")
}

// ---------------------------------------------------------------------------
// Runs and their graphs
// ---------------------------------------------------------------------------

/// Build the board row for one run: its actions with layers and cells, its landing signal, and its lane.
fn row(run: Run, hosts: Dict(String, Option(String))) -> RunRow {
  let servable = servable(run)
  let done =
    list.filter_map(run.work, fn(work) {
      case work.step {
        queue.Passed(_) | queue.Reused(_) -> Ok(work.task.action.name)
        queue.Pending(_)
        | queue.Active(_)
        | queue.Failed(_, _)
        | queue.Skipped -> Error(Nil)
      }
    })
    |> set.from_list

  // The work list is in dependency order, so each action's prerequisites
  // already have their layers when the fold reaches it.
  let #(_, actions) =
    list.fold(run.work, #(dict.new(), []), fn(acc, work) {
      let #(layers, actions) = acc
      let action = work.task.action
      let needs = list.append(action.dependencies, action.after)
      let layer =
        list.fold(needs, 0, fn(deepest, need) {
          int.max(deepest, { dict.get(layers, need) |> result.unwrap(-1) } + 1)
        })
      let placed = place(work, needs, layer, servable, done, hosts)
      #(dict.insert(layers, action.name, layer), [placed, ..actions])
    })
  let actions = list.reverse(actions)
  let #(signal, lane, members) = landing(run)
  RunRow(
    id: run.id,
    repo: run.repo,
    target: run.target,
    revision: run.revision,
    phase: queue.phase(run),
    signal:,
    lane:,
    members:,
    actions:,
    layers: list.fold(actions, 0, fn(n, action) { int.max(n, action.layer + 1) }),
    diagnosis: Diagnosis(Moving, ""),
  )
}

/// Turn one work item into an action whose cell and evidence follow from its queue step; a pending action is ready only when its pool is servable and its prerequisites passed.
fn place(
  work: queue.Work,
  needs: List(String),
  layer: Int,
  servable: Bool,
  done: set.Set(String),
  hosts: Dict(String, Option(String)),
) -> Action {
  let task = work.task
  let base =
    Action(
      name: task.action.name,
      cell: Blocked,
      pool: task.pool,
      layer:,
      argv: task.action.argv,
      needs:,
      timeout: task.action.timeout,
      holder: None,
      log: None,
      reason: None,
      attempts: 0,
    )

  // Each step kind maps to one cell, and only its own evidence comes along.
  case work.step {
    queue.Pending(attempts) -> {
      let ready = servable && list.all(needs, set.contains(done, _))
      Action(
        ..base,
        cell: case ready {
          True -> Ready
          False -> Blocked
        },
        attempts:,
      )
    }
    queue.Active(lease) -> {
      let worker = queue.lease_worker(lease)
      let holder =
        Holder(
          worker:,
          host: dict.get(hosts, worker) |> result.unwrap(None),
          attempt: queue.lease_attempt(lease),
          granted: fleet.granted(lease, task.action.timeout),
          until: queue.lease_until(lease),
        )
      Action(
        ..base,
        cell: Active,
        holder: Some(holder),
        attempts: queue.lease_attempt(lease) - 1,
      )
    }
    queue.Passed(proof) ->
      Action(..base, cell: Passed, log: Some(queue.proof_log(proof)))
    queue.Reused(proof) ->
      Action(..base, cell: Reused, log: Some(queue.proof_log(proof)))
    queue.Failed(queue.Reported(detail), log) ->
      Action(..base, cell: Failed, log: Some(log), reason: Some(detail))
    queue.Failed(queue.LeaseExpired(attempts), log) ->
      Action(
        ..base,
        cell: Expired,
        log: Some(log),
        attempts:,
        reason: Some(
          "lease lapsed on attempt " <> int.to_string(attempts) <> " of 3",
        ),
      )
    queue.Skipped -> Action(..base, cell: Skipped)
  }
}

/// Whether the queue can lease this run's pending actions, which mirrors the
/// core's own rule: a build or queued candidate that has not failed.
fn servable(run: Run) -> Bool {
  case run.submission, queue.phase(run) {
    queue.Build, queue.PhaseFailed | queue.Queued(_), queue.PhaseFailed -> False
    queue.Build, _ | queue.Queued(_), _ -> True
    queue.Waiting(_, _), _
    | queue.Landing(_), _
    | queue.Landed(_), _
    | queue.Blocked(_, _), _
    | queue.Unprepared(_, _, _), _
    -> False
  }
}

/// The landing signal, the lane it holds or waits on, and the member pulls.
fn landing(run: Run) -> #(Signal, Option(String), List(Int)) {
  let pulls = fn(members: List(queue.Member)) {
    list.map(members, fn(member) { member.pull })
  }
  let lane = fn(branch: String) { Some(run.repo <> ":" <> branch) }
  let held = fn(signal: Signal, candidate: queue.Candidate) {
    #(
      signal,
      lane(queue.candidate_branch(candidate)),
      pulls(queue.candidate_members(candidate)),
    )
  }

  // The submission state picks the signal; queued, landing, landed, and blocked candidates share one helper.
  case run.submission {
    queue.Build -> #(NoLane, None, [])
    queue.Waiting(branch, members) -> #(
      SignalWaiting,
      lane(branch),
      pulls(members),
    )
    queue.Unprepared(branch, members, _) -> #(
      SignalUnprepared,
      lane(branch),
      pulls(members),
    )
    queue.Queued(candidate) -> held(SignalQueued, candidate)
    queue.Landing(candidate) -> held(SignalLanding, candidate)
    queue.Landed(candidate) -> held(SignalLanded, candidate)
    queue.Blocked(candidate, _) -> held(SignalBlocked, candidate)
  }
}

// ---------------------------------------------------------------------------
// Slots and pools
// ---------------------------------------------------------------------------

/// Build a board slot from a registered slot, taking the work it holds from the rows and otherwise its last poll.
fn slot(slot: fleet.Slot, rows: List(RunRow), now: Int) -> Slot {
  let holding =
    list.find_map(rows, fn(run) {
      list.find_map(run.actions, fn(action) {
        case action.holder {
          Some(holder) if holder.worker == slot.worker ->
            Ok(Working(run.id, action.name, holder, action.timeout))
          Some(_) | None -> Error(Nil)
        }
      })
    })

  // A running action wins; otherwise the last poll decides between waiting, quiet, and unseen.
  let occupation = case holding, slot.presence {
    Ok(working), _ -> working
    Error(Nil), fleet.Polled(pool, at) ->
      case now - at <= live_window {
        True -> Waiting(pool, at)
        False -> Quiet(pool, at)
      }
    Error(Nil), fleet.Unseen -> Unseen
  }

  Slot(slot.worker, slot.host, occupation)
}

/// The pool a slot serves, when the board can tell.
///
/// ## Examples
///
/// ```gleam
/// // board.slot_pool(slot, board.runs)
/// ```
pub fn slot_pool(slot: Slot, rows: List(RunRow)) -> Option(String) {
  case slot.occupation {
    Waiting(pool, _) | Quiet(pool, _) -> Some(pool)
    Working(run, action, _, _) ->
      list.find_map(rows, fn(row) {
        case row.id == run {
          True ->
            list.find(row.actions, fn(a) { a.name == action })
            |> result.map(fn(a) { a.pool })
          False -> Error(Nil)
        }
      })
      |> option.from_result
    Unseen -> None
  }
}

/// Build one pool per name that a slot serves or a live action needs, with its counts and verdict, sorted by name.
fn pools(rows: List(RunRow), slots: List(Slot)) -> List(Pool) {
  let live_actions = list.flat_map(rows, fn(run) { run.actions })
  let named =
    list.append(
      list.filter_map(slots, fn(slot) {
        slot_pool(slot, rows) |> option.to_result(Nil)
      }),
      list.filter_map(live_actions, fn(action) {
        case action.cell {
          Ready | Active | Blocked -> Ok(action.pool)
          Passed | Reused | Failed | Expired | Skipped -> Error(Nil)
        }
      }),
    )
    |> list.unique
    |> list.sort(string.compare)
  list.map(named, fn(name) {
    let in_pool =
      list.filter(slots, fn(slot) { slot_pool(slot, rows) == Some(name) })
    let ready =
      list.count(live_actions, fn(a) { a.pool == name && a.cell == Ready })
    let busy =
      list.count(live_actions, fn(a) { a.pool == name && a.cell == Active })
    let free =
      list.count(in_pool, fn(slot) {
        case slot.occupation {
          Waiting(_, _) -> True
          Working(_, _, _, _) | Quiet(_, _) | Unseen -> False
        }
      })
    let live =
      list.count(in_pool, fn(slot) {
        case slot.occupation {
          Waiting(_, _) | Working(_, _, _, _) -> True
          Quiet(_, _) | Unseen -> False
        }
      })
    Pool(
      name:,
      ready:,
      busy:,
      free:,
      live:,
      known: list.length(in_pool),
      verdict: verdict(ready, busy, free, live),
    )
  })
}

/// The verdict for one pool's numbers. See the table in the module header.
///
/// ## Examples
///
/// ```gleam
/// board.verdict(ready: 3, busy: 2, free: 0, live: 2) == board.Saturated
/// ```
pub fn verdict(
  ready ready: Int,
  busy busy: Int,
  free free: Int,
  live live: Int,
) -> Verdict {
  case ready > 0, live > 0, free > 0, busy > 0 {
    True, False, _, _ -> Starved
    True, True, False, _ -> Saturated
    True, True, True, _ -> Draining
    False, _, _, True -> Busy
    False, _, _, False -> Idle
  }
}

/// Count the live runs, ready and active actions, live slots, and finished actions for the header.
fn totals(rows: List(RunRow), slots: List(Slot), proofs: Int) -> Totals {
  let actions = list.flat_map(rows, fn(run) { run.actions })
  let count = fn(cell) { list.count(actions, fn(a) { a.cell == cell }) }
  Totals(
    live_runs: list.count(rows, live),
    ready: count(Ready),
    active: count(Active),
    live_slots: list.count(slots, fn(slot) {
      case slot.occupation {
        Waiting(_, _) | Working(_, _, _, _) -> True
        Quiet(_, _) | Unseen -> False
      }
    }),
    slots: list.length(slots),
    passed: count(Passed),
    reused: count(Reused),
    proofs:,
  )
}

/// Live runs first, then the queue's own order reversed, so the newest
/// admission of each kind is on top.
fn order_runs(rows: List(RunRow)) -> List(RunRow) {
  let #(live, finished) = list.partition(list.reverse(rows), live)
  list.append(live, finished)
}

// ---------------------------------------------------------------------------
// Diagnosis
// ---------------------------------------------------------------------------

/// Say in words what one run is doing and whether it is settled, moving, stalled, or broken.
fn diagnose(
  run: RunRow,
  rows: List(RunRow),
  pools: List(Pool),
  now: Int,
) -> Diagnosis {
  let active = list.filter(run.actions, fn(a) { a.cell == Active })
  let ready = list.filter(run.actions, fn(a) { a.cell == Ready })
  let failed =
    list.find(run.actions, fn(a) { a.cell == Failed || a.cell == Expired })

  // The run's phase picks the diagnosis; only failed and pending runs need further analysis.
  case run.phase {
    queue.PhaseLanded -> Diagnosis(Settled, "landed")
    queue.PhasePassed -> Diagnosis(Settled, passed_text(run.actions))
    queue.PhaseBlocked -> Diagnosis(Broken, "landing refused")
    queue.PhaseUnprepared ->
      Diagnosis(Broken, "group could not be turned into a candidate")
    queue.PhaseLanding ->
      Diagnosis(Moving, "every action passed; landing intent outstanding")
    queue.PhaseWaiting -> waiting(run, rows)
    queue.PhaseFailed ->
      case failed, active {
        Ok(first), [] -> Diagnosis(Broken, failed_text(first))
        Ok(first), _ ->
          Diagnosis(
            Broken,
            failed_text(first)
              <> "; "
              <> count_text(list.length(active), "lease")
              <> " still out",
          )
        Error(Nil), _ -> Diagnosis(Broken, "failed")
      }
    queue.PhasePending -> pending(run, active, ready, pools, now)
  }
}

/// Diagnose a pending run: a last attempt about to lapse, then a pool that cannot take ready work, then plain progress.
fn pending(
  run: RunRow,
  active: List(Action),
  ready: List(Action),
  pools: List(Pool),
  now: Int,
) -> Diagnosis {
  let last_chance =
    list.find_map(active, fn(a) {
      case a.holder {
        Some(holder) ->
          case
            holder.attempt >= queue.max_attempts
            && holder.until - now <= deadline_warning
          {
            True -> Ok(#(a, holder))
            False -> Error(Nil)
          }
        None -> Error(Nil)
      }
    })
  let stuck_pools =
    ready
    |> list.map(fn(a) { a.pool })
    |> list.unique
    |> list.filter_map(fn(name) {
      list.find(pools, fn(pool) { pool.name == name })
      |> result.try(fn(pool) {
        case pool.verdict {
          Starved | Saturated -> Ok(pool)
          Draining | Busy | Idle -> Error(Nil)
        }
      })
    })

  // The most specific cause wins: a last attempt about to lapse, then a pool
  // that cannot take ready work, then plain progress.
  case last_chance, stuck_pools, active, ready {
    Ok(#(action, holder)), _, _, _ -> {
      Diagnosis(
        Stalled,
        action.name
          <> " is on its last attempt and its lease on "
          <> holder.worker
          <> " ends in "
          <> span(holder.until - now),
      )
    }
    Error(Nil), [pool, ..], _, _ -> {
      let waiting =
        list.count(ready, fn(a) { a.pool == pool.name })
        |> count_text("action")

      // A starved pool has no live slot, and any other verdict means its slots are all busy.
      case pool.verdict {
        Starved ->
          Diagnosis(
            Stalled,
            waiting
              <> " ready in pool "
              <> pool.name
              <> ", and no live slot polls it",
          )
        Saturated | Draining | Busy | Idle ->
          Diagnosis(
            Stalled,
            waiting
              <> " ready, pool "
              <> pool.name
              <> " is full ("
              <> int.to_string(pool.busy)
              <> " busy, 0 free)",
          )
      }
    }
    Error(Nil), [], [_, ..], _ ->
      Diagnosis(
        Moving,
        count_text(list.length(active), "action")
          <> " running"
          <> case ready {
          [] -> ""
          _ -> ", " <> int.to_string(list.length(ready)) <> " ready"
        },
      )
    Error(Nil), [], [], [_, ..] ->
      Diagnosis(
        Moving,
        count_text(list.length(ready), "action") <> " ready to dispatch",
      )
    Error(Nil), [], [], [] ->
      case run.actions {
        [] -> Diagnosis(Moving, "no actions yet")
        _ -> Diagnosis(Stalled, "nothing ready and nothing leased")
      }
  }
}

/// A waiting group either heads its lane or waits behind the run that holds
/// or heads it. Lane order is queue order, which `rows` keeps.
fn waiting(run: RunRow, rows: List(RunRow)) -> Diagnosis {
  let ahead =
    list.take_while(rows, fn(other) { other.id != run.id })
    |> list.filter(fn(other) {
      other.lane == run.lane
      && case other.signal {
        // A queued run whose actions failed no longer holds its lane, as
        // in the core's `holder_branch`, so nothing waits behind it.
        SignalQueued -> other.phase != queue.PhaseFailed
        SignalWaiting | SignalLanding -> True
        NoLane | SignalLanded | SignalBlocked | SignalUnprepared -> False
      }
    })

  // A run waits behind an earlier run on its lane, or has no lane to wait on.
  case ahead, run.lane {
    [first, ..], Some(lane) ->
      Diagnosis(
        Stalled,
        "behind "
          <> first.id
          <> " ("
          <> signal_label(first.signal)
          <> ") in lane "
          <> lane,
      )
    _, _ -> Diagnosis(Moving, "heads its lane; the controller prepares it next")
  }
}

/// Describe a passed run, naming how many actions were served from the cache.
fn passed_text(actions: List(Action)) -> String {
  let reused = list.count(actions, fn(a) { a.cell == Reused })

  // A run with no reused action reads plainly; otherwise it counts the cache hits.
  case reused {
    0 -> "passed"
    _ ->
      "passed, "
      <> int.to_string(reused)
      <> " of "
      <> int.to_string(list.length(actions))
      <> " from cache"
  }
}

/// Describe the first failed action, with the first line of the worker's reason when it gave one.
fn failed_text(action: Action) -> String {
  case action.cell, action.reason {
    Expired, _ -> action.name <> " expired after 3 attempts"
    _, Some(reason) -> action.name <> " failed: " <> first_line(reason)
    _, None -> action.name <> " failed"
  }
}

fn first_line(text: String) -> String {
  case string.split(text, "\n") {
    [line, ..] -> string.slice(line, 0, 120)
    [] -> ""
  }
}

/// Write a count with its noun, adding an s unless the count is one.
fn count_text(n: Int, noun: String) -> String {
  int.to_string(n)
  <> " "
  <> noun
  <> case n {
    1 -> ""
    _ -> "s"
  }
}

/// Order slots for the rail: working first by nearest deadline, then
/// waiting, quiet and unseen, each by worker ID.
///
/// ## Examples
///
/// ```gleam
/// // board.rail_order(board.slots)
/// ```
pub fn rail_order(slots: List(Slot)) -> List(Slot) {
  list.sort(slots, fn(a, b) {
    case int.compare(rank(a), rank(b)) {
      order.Eq ->
        case a.occupation, b.occupation {
          Working(_, _, x, _), Working(_, _, y, _) ->
            int.compare(x.until, y.until)
            |> order.break_tie(string.compare(a.worker, b.worker))
          _, _ -> string.compare(a.worker, b.worker)
        }
      other -> other
    }
  })
}

/// Give the rail position of a slot's occupation: working, waiting, quiet, then unseen.
fn rank(slot: Slot) -> Int {
  case slot.occupation {
    Working(_, _, _, _) -> 0
    Waiting(_, _) -> 1
    Quiet(_, _) -> 2
    Unseen -> 3
  }
}
