//// Durations the page measured itself. A step carries no timestamps, so the
//// only way to learn how long a finished action ran is to have seen it
//// leased and then seen it finish. `observe` folds each snapshot into that
//// memory: a lease records its grant time, and the first snapshot that shows
//// the action finished records the controller's clock as its end. The end is
//// late by up to one poll interval, and an action that finished before the
//// page opened has no duration at all.

import dashboard/board.{type Board}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}

/// What the page has seen of one action.
type Seen {
  Seen(granted: Int, finished: Option(Int))
}

/// Every action the page has seen leased, by run and action name.
pub opaque type Memory {
  Memory(seen: Dict(#(String, String), Seen))
}

/// What the page knows about one action's time.
pub type Timing {
  /// The action is leased and has run this long.
  Running(elapsed: Int)

  /// The page saw the action leased and then finished.
  Took(seconds: Int)

  /// The page never saw the action leased.
  Unknown
}

/// A memory that has seen nothing.
///
/// ## Examples
///
/// ```gleam
/// // timing.new()
/// ```
pub fn new() -> Memory {
  Memory(dict.new())
}

/// Fold one board into the memory. A new lease replaces an earlier one for
/// the same action, so a retried action is timed from its latest grant.
///
/// ## Examples
///
/// ```gleam
/// // timing.observe(memory, board)
/// ```
pub fn observe(memory: Memory, board: Board) -> Memory {
  let seen =
    list.fold(board.runs, memory.seen, fn(seen, run) {
      list.fold(run.actions, seen, fn(seen, action) {
        let key = #(run.id, action.name)

        // The holder and the earlier record decide whether the action is new, still running, or finished.
        case action.holder, dict.get(seen, key) {
          Some(holder), Ok(Seen(granted, _)) if granted == holder.granted -> seen
          Some(holder), _ -> dict.insert(seen, key, Seen(holder.granted, None))
          None, Ok(Seen(granted, None)) ->
            case action.cell {
              board.Passed | board.Failed | board.Expired | board.Skipped ->
                dict.insert(seen, key, Seen(granted, Some(board.now)))
              board.Blocked | board.Ready | board.Active | board.Reused ->
                // A lapsed lease returns the action to pending; it is timed
                // again from its next grant.
                dict.delete(seen, key)
            }
          None, _ -> seen
        }
      })
    })
  Memory(seen)
}

/// What the page knows about one action's time at `now`.
///
/// ## Examples
///
/// ```gleam
/// // timing.of(memory, "check-1", "verify", board.now)
/// ```
pub fn of(memory: Memory, run: String, action: String, now: Int) -> Timing {
  case dict.get(memory.seen, #(run, action)) {
    Ok(Seen(granted, Some(finished))) -> Took(finished - granted)
    Ok(Seen(granted, None)) -> Running(now - granted)
    Error(Nil) -> Unknown
  }
}
