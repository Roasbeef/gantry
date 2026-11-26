//// The page's state and every transition that does not touch the browser.
//// `dashboard` wires these to fetches and timers; this module imports no
//// Lustre, so its tests run without a page.
////
//// ## Flow
////
//// | Message | From | To |
//// | --- | --- | --- |
//// | `TokenSubmitted` | `SignedOut` | `Connecting`, and the first fetch |
//// | `Tick` | any signed-in state with no fetch in flight | the same, with a fetch in flight |
//// | `FleetAnswered` 200 | any | `Live`, with the board rebuilt |
//// | `FleetAnswered` 401 | any | `SignedOut`, the token forgotten |
//// | `FleetAnswered` other | any | `Lost`, the last board kept and marked stale |
//// | `SignedOut` | any | `SignedOut`, the board dropped |
////
//// The path through the module: `initial` builds the signed-out or
//// connecting model, `receive` folds each fleet answer into it,
//// `choose_run` and `choose_action` move the selection, and `receive_log`
//// installs a log once its blob arrives.
////
//// A fetch in flight blocks the next tick, so a slow controller never sees
//// more than one request at a time from a page.

import dashboard/board.{type Board}
import dashboard/timing.{type Memory}
import gantry_core/fleet
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// How the page stands with the controller.
pub type Connection {
  /// No token yet, or the controller refused the last one.
  SignedOut(notice: Option(String))

  /// A token is set and the first answer has not arrived.
  Connecting

  /// The latest answer was a snapshot.
  Live

  /// The latest answer was an error; the board shown is the last good one.
  Lost(reason: String)
}

/// The log pane for the chosen action.
pub type Log {
  NoLog
  Loading(digest: String)
  Loaded(digest: String, text: String)
  LogFailed(digest: String, reason: String)
}

/// The pane a narrow screen shows.
pub type Tab {
  PoolsTab
  RunsTab
  DetailTab
}

/// The whole page.
pub type Model {
  Model(
    token: String,
    draft: String,
    connection: Connection,
    board: Option(Board),
    memory: Memory,
    chosen_run: Option(String),
    chosen_action: Option(String),
    log: Log,
    tab: Tab,
    in_flight: Bool,
  )
}

/// Everything that can happen to the page.
pub type Msg {
  DraftChanged(String)
  TokenSubmitted
  SignOut
  Tick
  FleetAnswered(status: Int, body: String)
  RunChosen(String)
  ActionChosen(run: String, action: String)
  LogAnswered(digest: String, status: Int, body: String)
  TabChosen(Tab)
}

/// The most log lines the pane holds. A longer log shows its tail.
pub const log_lines = 400

/// The page before anything is fetched, given the stored token.
///
/// ## Examples
///
/// ```gleam
/// model.initial("").connection == model.SignedOut(option.None)
/// ```
pub fn initial(token: String) -> Model {
  Model(
    token:,
    draft: "",
    connection: case token {
      "" -> SignedOut(None)
      _ -> Connecting
    },
    board: None,
    memory: timing.new(),
    chosen_run: None,
    chosen_action: None,
    log: NoLog,
    tab: RunsTab,
    in_flight: False,
  )
}

/// Whether the page holds a token it may fetch with.
///
/// ## Examples
///
/// ```gleam
/// model.signed_in(model.initial("t")) == True
/// ```
pub fn signed_in(model: Model) -> Bool {
  case model.connection {
    SignedOut(_) -> False
    Connecting | Live | Lost(_) -> True
  }
}

/// Fold one answer from `GET /v1/fleet` into the page.
///
/// ## Examples
///
/// ```gleam
/// // model.receive(model, 200, body)
/// ```
pub fn receive(model: Model, status: Int, body: String) -> Model {
  let model = Model(..model, in_flight: False)

  // The status picks between a snapshot, a refused token, an unreachable
  // controller, and any other failure.
  case status {
    200 ->
      case json.parse(body, fleet.decoder()) {
        Ok(snapshot) -> show(model, board.build(snapshot))
        Error(_) ->
          Model(
            ..model,
            connection: Lost(
              "the controller sent a snapshot this page cannot read",
            ),
          )
      }
    401 ->
      Model(
        ..initial(""),
        connection: SignedOut(Some("The controller refused that token.")),
      )
    0 ->
      Model(..model, connection: Lost("cannot reach the controller: " <> body))
    _ -> Model(..model, connection: Lost(failure(status, body)))
  }
}

/// Fold one answer for a log blob into the page. An answer for a log that is
/// no longer chosen is dropped.
///
/// ## Examples
///
/// ```gleam
/// // model.receive_log(model, digest, 200, text)
/// ```
pub fn receive_log(
  model: Model,
  digest: String,
  status: Int,
  body: String,
) -> Model {
  case model.log {
    Loading(wanted) if wanted == digest ->
      Model(..model, log: case status {
        200 -> Loaded(digest, tail(body, log_lines))
        0 -> LogFailed(digest, "cannot reach the controller")
        _ -> LogFailed(digest, failure(status, body))
      })
    _ -> model
  }
}

/// Choose an action, and say which log digest to fetch when it has one.
///
/// ## Examples
///
/// ```gleam
/// // model.choose_action(model, "check-1", "verify")
/// ```
pub fn choose_action(
  model: Model,
  run: String,
  action: String,
) -> #(Model, Option(String)) {
  let digest =
    model.board
    |> option.to_result(Nil)
    |> result.try(board.find(_, run))
    |> result.try(fn(row) { list.find(row.actions, fn(a) { a.name == action }) })
    |> result.map(fn(a) { a.log })
    |> result.unwrap(None)
  let model =
    Model(
      ..model,
      chosen_run: Some(run),
      chosen_action: Some(action),
      tab: DetailTab,
      log: case digest {
        Some(digest) -> Loading(digest)
        None -> NoLog
      },
    )
  #(model, digest)
}

/// Choose a run, clearing the chosen action.
///
/// ## Examples
///
/// ```gleam
/// // model.choose_run(model, "check-1")
/// ```
pub fn choose_run(model: Model, run: String) -> Model {
  Model(
    ..model,
    chosen_run: Some(run),
    chosen_action: None,
    log: NoLog,
    tab: DetailTab,
  )
}

/// Keep at most the last `lines` lines of a log.
///
/// ## Examples
///
/// ```gleam
/// model.tail("a\nb\nc", 2) == "b\nc"
/// ```
pub fn tail(text: String, lines: Int) -> String {
  let all = string.split(text, "\n")
  let extra = list.length(all) - lines

  // Drop leading lines only when the log is longer than the limit.
  case extra > 0 {
    True -> list.drop(all, extra) |> string.join("\n")
    False -> text
  }
}

/// Install a new board. A chosen run that is no longer retained gives way to
/// the first stalled run, or the first run when none is stalled.
fn show(model: Model, next: Board) -> Model {
  let kept =
    model.chosen_run
    |> option.to_result(Nil)
    |> result.try(board.find(next, _))
    |> result.is_ok

  // A chosen run that was dropped gives way to a stalled run, then the
  // first run.
  let chosen = case kept {
    True -> model.chosen_run
    False ->
      list.find(next.runs, fn(run) { run.diagnosis.health == board.Stalled })
      |> result.lazy_or(fn() { list.first(next.runs) })
      |> result.map(fn(run) { run.id })
      |> option.from_result
  }

  Model(
    ..model,
    connection: Live,
    board: Some(next),
    memory: timing.observe(model.memory, next),
    chosen_run: chosen,
    chosen_action: case kept {
      True -> model.chosen_action
      False -> None
    },
    log: case kept {
      True -> model.log
      False -> NoLog
    },
  )
}

/// Describe an error answer from its `{"error": ...}` body, or its status.
fn failure(status: Int, body: String) -> String {
  let detail = json.parse(body, decode.at(["error"], decode.string))
  "HTTP "
  <> int.to_string(status)
  <> case detail {
    Ok(message) -> ": " <> message
    Error(_) -> ""
  }
}
