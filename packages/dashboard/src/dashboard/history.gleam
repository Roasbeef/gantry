//// The recent past, read from the snapshot's events and samples: one bar per
//// lease on its slot's lane, each action's duration, the ready backlog and
//// throughput over the window, how long each pool has had work waiting, and
//// a run's critical path. It imports no Lustre, so its tests run under Node.
////
//// ## Flow
////
//// `read` pairs each grant with its result into a `Bar`, adds a bar for each
//// live lease the history no longer holds (a controller restart forgets the
//// grant, but the queue still has the lease), and returns them with the
//// window. `duration`, `backlog_since`, `ready_series`, `throughput`,
//// `slowest`, `failures`, and `critical` each read the result.
////
//// ## What a bar can say
////
//// | Outcome | Evidence |
//// | --- | --- |
//// | `Running` | the run's step is still the active lease with that serial |
//// | `Passed`, `Failed` | the controller recorded the result |
//// | `Lapsed` | no result was recorded and the lease is no longer active |
////
//// A lease whose result reached another voter reads as `Lapsed` here, the
//// same per-controller limit as a slot's presence.

import dashboard/board.{type Board, type RunRow}
import gantry_core/fleet.{type Fleet}
import gantry_core/queue
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}

/// How a bar ended.
pub type Outcome {
  Running

  Passed

  Failed

  Lapsed
}

/// One lease on one slot's lane, from grant to result.
pub type Bar {
  Bar(
    worker: String,
    run: String,
    action: String,
    pool: String,
    start: Int,
    end: Int,
    outcome: Outcome,
  )
}

/// The window the page draws and what is known inside it.
pub type History {
  History(
    now: Int,
    from: Int,
    since: Int,
    bars: List(Bar),
    samples: List(fleet.Sample),
    settled: List(Int),
  )
}

/// How far back the timeline reaches, in seconds.
pub const window = 900

/// A sample gap longer than this many seconds means nobody was reading.
pub const sample_gap = 10

/// Read the history from a snapshot and the board built from it.
///
/// ## Examples
///
/// ```gleam
/// // history.read(snapshot, board.build(snapshot))
/// ```
pub fn read(snapshot: Fleet, b: Board) -> History {
  let now = snapshot.now

  // Results by serial, so each grant finds its own.
  let results =
    list.filter_map(snapshot.events, fn(event) {
      case event {
        fleet.Settled(serial, outcome, at) -> Ok(#(serial, #(outcome, at)))
        fleet.Granted(..) -> Error(Nil)
      }
    })
    |> dict.from_list
  let live = live_leases(snapshot)

  // One bar per recorded grant, ended by its result or by the queue.
  let recorded =
    list.filter_map(snapshot.events, fn(event) {
      case event {
        fleet.Granted(serial, run, action, worker, pool, at, until) ->
          Ok(bar(
            serial,
            run,
            action,
            worker,
            pool,
            at,
            until,
            results,
            live,
            now,
          ))
        fleet.Settled(..) -> Error(Nil)
      }
    })

  // Live leases whose grants the history lacks are drawn from the queue.
  let known =
    list.filter_map(snapshot.events, fn(event) {
      case event {
        fleet.Granted(serial: serial, ..) -> Ok(serial)
        fleet.Settled(..) -> Error(Nil)
      }
    })
    |> set.from_list
  let forgotten = recovered(b, known, now)

  History(
    now:,
    from: now - window,
    since: snapshot.since,
    bars: list.append(forgotten, recorded),
    samples: snapshot.samples,
    settled: list.filter_map(snapshot.events, fn(event) {
      case event {
        fleet.Settled(at: at, ..) -> Ok(at)
        fleet.Granted(..) -> Error(Nil)
      }
    }),
  )
}

/// The serial of every lease the queue holds now.
fn live_leases(snapshot: Fleet) -> Set(Int) {
  list.flat_map(snapshot.runs, fn(run) {
    list.filter_map(run.work, fn(work) {
      // Only an active step holds a lease.
      case work.step {
        queue.Active(lease) -> Ok(queue.lease_serial(lease))
        queue.Pending(_)
        | queue.Passed(_)
        | queue.Reused(_)
        | queue.Failed(_, _)
        | queue.Skipped -> Error(Nil)
      }
    })
  })
  |> set.from_list
}

/// Pair one grant with its result, or decide from the queue how it ended.
fn bar(
  serial: Int,
  run: String,
  action: String,
  worker: String,
  pool: String,
  at: Int,
  until: Int,
  results: Dict(Int, #(fleet.Outcome, Int)),
  live: Set(Int),
  now: Int,
) -> Bar {
  let base = Bar(worker, run, action, pool, at, now, Running)

  // A recorded result ends the bar; otherwise a lease still active is
  // running and one that is gone lapsed at its deadline.
  case dict.get(results, serial), set.contains(live, serial) {
    Ok(#(fleet.Succeeded, done)), _ -> Bar(..base, end: done, outcome: Passed)
    Ok(#(fleet.Rejected, done)), _ -> Bar(..base, end: done, outcome: Failed)
    Error(Nil), True -> base
    Error(Nil), False -> Bar(..base, end: int.min(until, now), outcome: Lapsed)
  }
}

/// Bars for the leases the queue holds whose grants the history no longer
/// has, drawn from the grant time the lease's deadline implies.
fn recovered(b: Board, known: Set(Int), now: Int) -> List(Bar) {
  list.flat_map(b.runs, fn(run) {
    list.filter_map(run.actions, fn(action) {
      case action.holder {
        Some(holder) ->
          case set.contains(known, holder.serial) {
            True -> Error(Nil)
            False ->
              Ok(Bar(
                holder.worker,
                run.id,
                action.name,
                action.pool,
                holder.granted,
                now,
                Running,
              ))
          }
        None -> Error(Nil)
      }
    })
  })
}

/// The seconds an action took or has taken so far, from its latest bar.
///
/// ## Examples
///
/// ```gleam
/// // history.duration(h, "check-1", "verify")
/// ```
pub fn duration(h: History, run: String, action: String) -> Option(Int) {
  h.bars
  |> list.filter(fn(bar) { bar.run == run && bar.action == action })
  |> list.sort(fn(a, b) { int.compare(b.start, a.start) })
  |> list.first
  |> result.map(fn(bar) { bar.end - bar.start })
  |> option.from_result
}

/// The bar a slot holds or held, newest first.
///
/// ## Examples
///
/// ```gleam
/// // history.lane(h, "linux-01")
/// ```
pub fn lane(h: History, worker: String) -> List(Bar) {
  list.filter(h.bars, fn(bar) { bar.worker == worker && bar.end >= h.from })
}

/// Since when a pool has had ready work waiting without a break, if it has
/// some now and the samples reach back without a gap. `None` when the pool
/// has nothing waiting or the samples cannot say.
///
/// ## Examples
///
/// ```gleam
/// // history.backlog_since(h, "linux")
/// ```
pub fn backlog_since(h: History, pool: String) -> Option(Int) {
  let newest_first = list.sort(h.samples, fn(a, b) { int.compare(b.at, a.at) })
  walk(newest_first, pool, h.now, None)
}

/// Walk samples from newest to oldest while the pool has work waiting and
/// no gap breaks the record, returning the oldest such sample's time.
fn walk(
  samples: List(fleet.Sample),
  pool: String,
  after: Int,
  earliest: Option(Int),
) -> Option(Int) {
  // Stop at the first sample with nothing waiting or at a gap in the record.
  case samples {
    [] -> earliest
    [sample, ..rest] -> {
      let waiting = list.key_find(sample.ready, pool) |> result.unwrap(0)

      // A sample with work waiting and no gap extends the backlog.
      case waiting > 0 && after - sample.at <= sample_gap {
        True -> walk(rest, pool, sample.at, Some(sample.at))
        False -> earliest
      }
    }
  }
}

/// The total ready work at each sample in the window, oldest first.
///
/// ## Examples
///
/// ```gleam
/// // history.ready_series(h)
/// ```
pub fn ready_series(h: History) -> List(#(Int, Int)) {
  h.samples
  |> list.filter(fn(sample) { sample.at >= h.from })
  |> list.sort(fn(a, b) { int.compare(a.at, b.at) })
  |> list.map(fn(sample) {
    #(sample.at, list.fold(sample.ready, 0, fn(n, pair) { n + pair.1 }))
  })
}

/// Results accepted in each minute of the window, oldest minute first.
///
/// ## Examples
///
/// ```gleam
/// // history.throughput(h)
/// ```
pub fn throughput(h: History) -> List(Int) {
  list.repeat(0, window / 60)
  |> list.index_map(fn(_, minute) {
    let start = h.from + minute * 60
    list.count(h.settled, fn(at) { at >= start && at < start + 60 })
  })
}

/// The finished bars that took longest, longest first.
///
/// ## Examples
///
/// ```gleam
/// // history.slowest(h, 5)
/// ```
pub fn slowest(h: History, most: Int) -> List(Bar) {
  h.bars
  |> list.filter(fn(bar) { bar.outcome == Passed || bar.outcome == Failed })
  |> list.sort(fn(a, b) { int.compare(b.end - b.start, a.end - a.start) })
  |> list.take(most)
}

/// The bars that failed or lapsed, newest first.
///
/// ## Examples
///
/// ```gleam
/// // history.failures(h, 5)
/// ```
pub fn failures(h: History, most: Int) -> List(Bar) {
  h.bars
  |> list.filter(fn(bar) { bar.outcome == Failed || bar.outcome == Lapsed })
  |> list.sort(fn(a, b) { int.compare(b.end, a.end) })
  |> list.take(most)
}

/// The actions on a run's longest chain, weighing each action by its known
/// duration and an unknown one as one second, so a chain reads even before
/// anything has finished. Ties go to the earlier action in queue order.
///
/// ## Examples
///
/// ```gleam
/// // history.critical(h, row)
/// ```
pub fn critical(h: History, run: RunRow) -> Set(String) {
  let weight = fn(name) {
    duration(h, run.id, name) |> option.unwrap(1) |> int.max(1)
  }

  // The run's actions are in dependency order, so each one's prerequisites
  // already have their best chains when the fold reaches it.
  let best =
    list.fold(run.actions, dict.new(), fn(best, action) {
      let #(length, path) =
        list.fold(action.needs, #(0, []), fn(longest, need) {
          case dict.get(best, need) {
            Ok(#(length, path)) ->
              case int.compare(length, longest.0) {
                order.Gt -> #(length, path)
                order.Eq | order.Lt -> longest
              }
            Error(Nil) -> longest
          }
        })
      dict.insert(
        best,
        action.name,
        #(length + weight(action.name), [action.name, ..path]),
      )
    })
  dict.values(best)
  |> list.fold(#(0, []), fn(longest, chain) {
    case chain.0 > longest.0 {
      True -> chain
      False -> longest
    }
  })
  |> fn(chain) { set.from_list(chain.1) }
}
