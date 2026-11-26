//// The fleet over time: the occupancy timeline (one lane per slot, grouped by
//// host, each lease a bar from grant to result), the two sparklines beside
//// it, and the fleet summary the detail pane shows when no run is chosen.
//// Every number comes from `history`, and time before the history's horizon
//// is drawn hatched as unknown, never as idle.

import dashboard/board.{type Board}
import dashboard/history.{type Bar, type History}
import dashboard/model.{type Msg}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute.{attribute, class}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/svg
import lustre/event

/// Draw the occupancy timeline with its sparklines.
///
/// ## Examples
///
/// ```gleam
/// // fleet_view.timeline(board, history)
/// ```
pub fn timeline(b: Board, h: History) -> Element(Msg) {
  html.section([class("timeline"), attribute.aria_label("Slot occupancy")], [
    html.header([class("tl-head")], [
      html.h2([class("pane-title")], [
        text("Occupancy"),
        html.span([class("pane-count")], [text("last 15 min")]),
      ]),
      html.div([class("sparks")], [
        spark_ready(h),
        spark_throughput(h),
      ]),
    ]),
    html.div([class("tl-grid")], [
      html.span([class("tl-label tl-axis-label")], []),
      axis(h),
      ..list.flat_map(board.hosts(b.slots), fn(host) {
        let name = option.unwrap(host.name, "unlabelled")
        [
          html.span([class("tl-host")], [
            text(name),
            html.span([class("tl-host-load")], [
              text(
                " "
                <> int.to_string(host.busy)
                <> "/"
                <> int.to_string(list.length(host.slots)),
              ),
            ]),
          ]),
          html.span([class("tl-host-rule")], []),
          ..list.flat_map(host.slots, fn(slot) {
            [
              html.span([class("tl-label")], [text(slot.worker)]),
              lane(h, slot.worker),
            ]
          })
        ]
      })
    ]),
  ])
}

/// The time axis: a tick and a label every five minutes, now at the right,
/// and a marker where the history begins when it begins inside the window.
fn axis(h: History) -> Element(Msg) {
  let start = h.since - h.from

  // A history younger than the window says where it starts.
  let marker = case start > 0 && start < history.window {
    True -> [
      html.span(
        [
          class("tl-start"),
          attribute.style(
            "left",
            int.to_string(start * 100 / history.window) <> "%",
          ),
        ],
        [text("history starts")],
      ),
    ]
    False -> []
  }

  html.div(
    [class("tl-axis")],
    list.append(
      marker,
      list.map([15, 10, 5, 0], fn(minutes) {
        let left = { history.window - minutes * 60 } * 100 / history.window
        html.span(
          [
            class("tl-tick"),
            attribute.style("left", int.to_string(left) <> "%"),
          ],
          [
            text(case minutes {
              0 -> "now"
              n -> "−" <> int.to_string(n) <> "m"
            }),
          ],
        )
      }),
    ),
  )
}

/// One slot's lane: the unknown stretch before the horizon, then one bar per
/// lease, each a button to its action.
fn lane(h: History, worker: String) -> Element(Msg) {
  let unknown = int.clamp(h.since - h.from, 0, history.window)
  let bars =
    list.map(history.lane(h, worker), fn(bar) {
      let x = int.max(bar.start - h.from, 0)
      let width = int.max(bar.end - int.max(bar.start, h.from), 3)
      svg.rect([
        class("bar o-" <> outcome_label(bar.outcome)),
        attribute("x", int.to_string(x)),
        attribute("y", "1"),
        attribute("width", int.to_string(width)),
        attribute("height", "10"),
        event.on_click(model.ActionChosen(bar.run, bar.action)),
      ])
      |> titled(bar)
    })
  html.svg(
    [
      class("tl-lane"),
      attribute("viewBox", "0 0 " <> int.to_string(history.window) <> " 12"),
      attribute("preserveAspectRatio", "none"),
      attribute.role("img"),
      attribute.aria_label(worker <> " occupancy"),
    ],
    [
      svg.rect([
        class("unknown"),
        attribute("x", "0"),
        attribute("y", "0"),
        attribute("width", int.to_string(unknown)),
        attribute("height", "12"),
      ]),
      ..bars
    ],
  )
}

/// Wrap a bar in a group that carries its tooltip.
fn titled(rect: Element(Msg), bar: Bar) -> Element(Msg) {
  svg.g([], [
    svg.title([], [
      text(
        bar.run
        <> " / "
        <> bar.action
        <> " · "
        <> outcome_label(bar.outcome)
        <> " · "
        <> board.span(bar.end - bar.start),
      ),
    ]),
    rect,
  ])
}

/// The word for a bar's outcome, which is also its colour class.
pub fn outcome_label(outcome: history.Outcome) -> String {
  case outcome {
    history.Running -> "running"
    history.Passed -> "passed"
    history.Failed -> "failed"
    history.Lapsed -> "lapsed"
  }
}

/// The ready backlog over the window as a line, with its latest value.
fn spark_ready(h: History) -> Element(Msg) {
  let series = history.ready_series(h)
  let top = list.fold(series, 1, fn(n, point) { int.max(n, point.1) })
  let points =
    list.map(series, fn(point) {
      int.to_string(point.0 - h.from)
      <> ","
      <> float.to_string(
        28.0 -. int.to_float(point.1) *. 26.0 /. int.to_float(top),
      )
    })
    |> string.join(" ")

  // The newest sample is the value printed beside the line.
  let latest = case list.last(series) {
    Ok(point) -> int.to_string(point.1)
    Error(Nil) -> "—"
  }

  spark("ready", latest, [
    svg.polyline([class("spark-line"), attribute("points", points)]),
  ])
}

/// Results per minute over the window as bars, with the last full minute.
fn spark_throughput(h: History) -> Element(Msg) {
  let minutes = history.throughput(h)
  let top = list.fold(minutes, 1, int.max)
  let bars =
    list.index_map(minutes, fn(count, i) {
      let height = count * 26 / top
      svg.rect([
        class("spark-bar"),
        attribute("x", int.to_string(i * 60 + 6)),
        attribute("y", int.to_string(28 - height)),
        attribute("width", "48"),
        attribute("height", int.to_string(height)),
      ])
    })
  let latest =
    list.reverse(minutes)
    |> list.drop(1)
    |> list.first
    |> fn(found) {
      case found {
        Ok(n) -> int.to_string(n)
        Error(Nil) -> "—"
      }
    }
  spark("done/min", latest, bars)
}

/// Draw one sparkline: its plot, its latest value, and its label.
fn spark(
  label: String,
  value: String,
  marks: List(Element(Msg)),
) -> Element(Msg) {
  html.div([class("spark")], [
    html.svg(
      [
        class("spark-plot"),
        attribute("viewBox", "0 0 " <> int.to_string(history.window) <> " 30"),
        attribute("preserveAspectRatio", "none"),
        attribute.aria_hidden(True),
      ],
      marks,
    ),
    html.span([class("spark-value")], [text(value)]),
    html.span([class("spark-label")], [text(label)]),
  ])
}

/// The detail pane with no run chosen: throughput, outcomes and cache use in
/// the window, how long each backed-up pool has waited, the slowest actions,
/// and the recent failures.
///
/// ## Examples
///
/// ```gleam
/// // fleet_view.summary(board, history)
/// ```
pub fn summary(b: Board, h: History) -> Element(Msg) {
  let in_window = list.filter(h.bars, fn(bar) { bar.end >= h.from })
  let count = fn(outcome) {
    list.count(in_window, fn(bar) { bar.outcome == outcome })
  }
  let last_five = list.count(h.settled, fn(at) { at > h.now - 300 })
  let finished = b.totals.passed + b.totals.reused
  html.div([class("summary")], [
    html.h2([class("detail-id")], [text("Fleet")]),
    html.p([class("detail-meta")], [
      text(case h.since > h.from {
        True ->
          "History covers the last "
          <> board.span(h.now - h.since)
          <> ", since this controller started."
        False -> "Last 15 minutes, as this controller saw them."
      }),
    ]),
    html.dl([class("facts summary-facts")], [
      fact("rate", int.to_string(last_five / 5) <> " actions/min over 5 min"),
      fact(
        "leases",
        int.to_string(count(history.Passed))
          <> " passed · "
          <> int.to_string(count(history.Failed))
          <> " failed · "
          <> int.to_string(count(history.Lapsed))
          <> " lapsed · "
          <> int.to_string(count(history.Running))
          <> " running",
      ),
      fact("cache", case finished {
        0 -> "nothing finished yet"
        _ ->
          int.to_string(b.totals.reused * 100 / finished)
          <> "% of "
          <> int.to_string(finished)
          <> " retained results reused a proof"
      }),
      ..list.filter_map(b.pools, fn(pool) {
        case history.backlog_since(h, pool.name) {
          Some(at) ->
            Ok(fact(pool.name, "work waiting for " <> board.span(h.now - at)))
          None -> Error(Nil)
        }
      })
    ]),
    bar_list("Slowest", history.slowest(h, 5), "No lease has finished yet."),
    bar_list(
      "Recent failures",
      history.failures(h, 5),
      "No lease failed or lapsed in the window.",
    ),
  ])
}

fn fact(label: String, value: String) -> Element(Msg) {
  html.div([class("fact")], [
    html.dt([], [text(label)]),
    html.dd([], [text(value)]),
  ])
}

/// A titled list of leases, each a button to its action.
fn bar_list(title: String, bars: List(Bar), empty: String) -> Element(Msg) {
  html.section([class("bars")], [
    html.h3([class("band-title")], [text(title)]),
    case bars {
      [] -> html.p([class("quiet-note")], [text(empty)])
      _ ->
        html.ul(
          [class("bar-list")],
          list.map(bars, fn(bar) {
            html.li([], [
              html.button(
                [
                  class("bar-row o-" <> outcome_label(bar.outcome)),
                  event.on_click(model.ActionChosen(bar.run, bar.action)),
                ],
                [
                  html.span([class("bar-swatch")], []),
                  html.span([class("bar-action")], [text(bar.action)]),
                  html.span([class("bar-run")], [text(bar.run)]),
                  html.span([class("bar-time")], [
                    text(board.span(bar.end - bar.start)),
                  ]),
                ],
              ),
            ])
          }),
        )
    },
  ])
}
