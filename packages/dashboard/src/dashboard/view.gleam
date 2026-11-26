//// The page. Three regions share one row on a wide screen: the rail with
//// each pool's demand against its supply and each slot's lease, the run list
//// with each run's graph as a strip of cells and its diagnosis, and the
//// chosen run's graph, action, and log. A narrow screen shows one region at
//// a time behind tabs. Every colour comes from a cell, verdict, or signal
//// class, so the stylesheet holds the one palette.

import dashboard/board.{
  type Action, type Board, type Pool, type RunRow, type Slot,
}
import dashboard/layout
import dashboard/model.{type Model, type Msg}
import dashboard/timing
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{attribute, class}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/svg
import lustre/event

/// Draw the page for one model.
///
/// ## Examples
///
/// ```gleam
/// // view.view(model.initial(""))
/// ```
pub fn view(m: Model) -> Element(Msg) {
  case m.connection, m.board {
    model.SignedOut(notice), _ -> sign_in(m, notice)
    _, None -> html.div([class("shell")], [top(m, None), waiting_note(m)])
    _, Some(b) ->
      html.div([class("shell")], [top(m, Some(b)), tabs(m), main(m, b)])
  }
}

// ---------------------------------------------------------------------------
// Sign in and the top bar
// ---------------------------------------------------------------------------

/// Draw the sign-in form with the controller's last notice, if any.
fn sign_in(m: Model, notice: Option(String)) -> Element(Msg) {
  html.div([class("gate")], [
    html.form(
      [class("gate-card"), event.on_submit(fn(_) { model.TokenSubmitted })],
      [
        brand(),
        html.p([class("gate-lede")], [
          text(
            "Paste a token this controller accepts. The view token (GANTRY_VIEW_TOKEN) reads runs, slots and logs and can change nothing.",
          ),
        ]),
        html.label([class("gate-label"), attribute("for", "token")], [
          text("Token"),
        ]),
        html.input([
          attribute.id("token"),
          class("gate-input"),
          attribute.type_("password"),
          attribute.autocomplete("off"),
          attribute.value(m.draft),
          event.on_input(model.DraftChanged),
        ]),
        case notice {
          Some(notice) -> html.p([class("gate-notice")], [text(notice)])
          None -> element.none()
        },
        html.button([class("gate-go"), attribute.type_("submit")], [
          text("Open the board"),
        ]),
        html.p([class("gate-foot")], [
          text("The token stays in this browser's local storage."),
        ]),
      ],
    ),
  ])
}

/// Draw the page's name mark.
fn brand() -> Element(Msg) {
  html.div([class("brand")], [
    html.span([class("brand-mark"), attribute.aria_hidden(True)], []),
    html.span([class("brand-name")], [text("gantry")]),
    html.span([class("brand-sub")], [text("board")]),
  ])
}

/// Draw the top bar with the totals, the connection state, and the sign-out control.
fn top(m: Model, b: Option(Board)) -> Element(Msg) {
  html.header([class("top")], [
    brand(),
    case b {
      Some(b) -> totals(b)
      None -> html.div([class("totals")], [])
    },
    link(m, b),
    html.button([class("signout"), event.on_click(model.SignOut)], [
      text("Sign out"),
    ]),
  ])
}

/// Draw the header counts, with the cache rate shown only once an action has finished.
fn totals(b: Board) -> Element(Msg) {
  let t = b.totals
  let finished = t.passed + t.reused

  // With nothing finished there is no cache rate to show.
  let cache = case finished {
    0 -> "—"
    _ -> int.to_string(t.reused * 100 / finished) <> "%"
  }

  html.dl([class("totals")], [
    stat("live runs", int.to_string(t.live_runs), "t-runs"),
    stat("ready", int.to_string(t.ready), case t.ready {
      0 -> "t-ready"
      _ -> "t-ready hot"
    }),
    stat("leased", int.to_string(t.active), "t-active"),
    stat(
      "slots live",
      int.to_string(t.live_slots) <> "/" <> int.to_string(t.slots),
      "t-slots",
    ),
    stat("cache reuse", cache, "t-cache"),
  ])
}

fn stat(label: String, value: String, extra: String) -> Element(Msg) {
  html.div([class("stat " <> extra)], [
    html.dt([], [text(label)]),
    html.dd([], [text(value)]),
  ])
}

/// Draw the connection dot and its words from the connection state.
fn link(m: Model, b: Option(Board)) -> Element(Msg) {
  // The connection and the board decide the dot's state and its words.
  let #(state, words) = case m.connection, b {
    model.Live, _ -> #("live", "live · polling every 2s")
    model.Connecting, _ -> #("connecting", "connecting")
    model.Lost(reason), Some(_) -> #("lost", "stale · " <> reason)
    model.Lost(reason), None -> #("lost", reason)
    model.SignedOut(_), _ -> #("lost", "signed out")
  }

  html.div([class("link link-" <> state), attribute.role("status")], [
    html.span([class("link-dot"), attribute.aria_hidden(True)], []),
    html.span([class("link-words")], [text(words)]),
  ])
}

/// Draw the note shown before the first snapshot arrives.
fn waiting_note(m: Model) -> Element(Msg) {
  html.p([class("empty")], [
    text(case m.connection {
      model.Lost(reason) -> reason
      model.SignedOut(_) | model.Connecting | model.Live -> "Reading the fleet…"
    }),
  ])
}

/// Draw the tab buttons that choose which pane a narrow screen shows.
fn tabs(m: Model) -> Element(Msg) {
  let tab = fn(which: model.Tab, label: String) {
    html.button(
      [
        class("tab"),
        attribute.aria_selected(m.tab == which),
        attribute.role("tab"),
        event.on_click(model.TabChosen(which)),
      ],
      [text(label)],
    )
  }
  html.nav([class("tabs"), attribute.role("tablist")], [
    tab(model.PoolsTab, "Pools"),
    tab(model.RunsTab, "Runs"),
    tab(model.DetailTab, "Detail"),
  ])
}

fn main(m: Model, b: Board) -> Element(Msg) {
  // The chosen tab picks the one pane a narrow screen shows.
  let shown = case m.tab {
    model.PoolsTab -> "show-pools"
    model.RunsTab -> "show-runs"
    model.DetailTab -> "show-detail"
  }

  html.main([class("board " <> shown)], [
    rail(b),
    runs(m, b),
    detail(m, b),
  ])
}

// ---------------------------------------------------------------------------
// The rail: pools and slots
// ---------------------------------------------------------------------------

/// Draw the left pane: one card per pool and the list of slots.
fn rail(b: Board) -> Element(Msg) {
  html.aside([class("rail"), attribute.aria_label("Pools and slots")], [
    html.h2([class("pane-title")], [text("Pressure")]),
    case b.pools {
      [] -> html.p([class("quiet-note")], [text("No pool has work or a slot.")])
      pools -> html.div([class("pools")], list.map(pools, pool(_, b)))
    },
    html.h2([class("pane-title")], [
      text("Slots"),
      html.span([class("pane-count")], [
        text(int.to_string(list.length(b.slots))),
      ]),
    ]),
    html.ul([class("slots")], list.map(board.rail_order(b.slots), slot(_, b))),
    html.p([class("rail-foot")], [
      text(
        "Pools and polls are what this controller has served since it started.",
      ),
    ]),
  ])
}

/// Draw one pool card with its slots, its ready work, and its counts.
fn pool(p: Pool, b: Board) -> Element(Msg) {
  // The slots that serve this pool, drawn as squares.
  let in_pool =
    board.rail_order(b.slots)
    |> list.filter(fn(s) { board.slot_pool(s, b.runs) == Some(p.name) })
  let squares =
    list.map(in_pool, fn(s) {
      // The slot's occupation picks the pip's colour class.
      let kind = case s.occupation {
        board.Working(_, _, _, _) -> "busy"
        board.Waiting(_, _) -> "free"
        board.Quiet(_, _) -> "gone"
        board.Unseen -> "gone"
      }

      html.span(
        [class("sq sq-" <> kind), attribute.title(s.worker <> " · " <> kind)],
        [],
      )
    })

  // One pip per ready action, up to a limit.
  let shown = int.min(p.ready, 24)
  let pips =
    list.repeat(Nil, shown)
    |> list.map(fn(_) { html.span([class("pip")], []) })

  // Only pending work past the pip limit gets an overflow marker.
  let overflow = case p.ready > shown {
    True -> [
      html.span([class("pip-more")], [
        text("+" <> int.to_string(p.ready - shown)),
      ]),
    ]
    False -> []
  }

  let label = board.verdict_label(p.verdict)

  html.section([class("pool v-" <> label)], [
    html.header([class("pool-head")], [
      html.span([class("pool-name")], [text(p.name)]),
      html.span([class("verdict")], [text(label)]),
    ]),
    html.div(
      [
        class("gauge"),
        attribute.role("img"),
        attribute.aria_label(
          int.to_string(p.busy)
          <> " busy, "
          <> int.to_string(p.free)
          <> " free, "
          <> int.to_string(p.ready)
          <> " ready",
        ),
      ],
      [
        html.span([class("supply")], case squares {
          [] -> [html.span([class("sq sq-none")], [])]
          _ -> squares
        }),
        html.span([class("gauge-sep"), attribute.aria_hidden(True)], []),
        html.span([class("demand")], list.append(pips, overflow)),
      ],
    ),
    html.p([class("pool-nums")], [
      num(p.busy, "busy"),
      num(p.free, "free"),
      num(p.ready, "ready"),
      html.span([class("num")], [
        text(int.to_string(p.live) <> "/" <> int.to_string(p.known) <> " live"),
      ]),
    ]),
  ])
}

fn num(value: Int, label: String) -> Element(Msg) {
  html.span([class("num")], [
    html.b([], [text(int.to_string(value))]),
    text(" " <> label),
  ])
}

/// Draw one slot: the action it holds with its lease bar, or its last poll.
fn slot(s: Slot, b: Board) -> Element(Msg) {
  let id =
    html.span([class("slot-id")], [
      html.span([class("slot-worker")], [text(s.worker)]),
      case s.host {
        Some(host) -> html.span([class("slot-host")], [text(host)])
        None -> element.none()
      },
    ])

  // A working slot shows its action; any other slot shows its last poll.
  case s.occupation {
    board.Working(run, action, holder, timeout) ->
      html.li([class("slot slot-busy")], [
        id,
        html.button(
          [class("slot-job"), event.on_click(model.ActionChosen(run, action))],
          [
            html.span([class("job-run")], [text(run)]),
            html.span([class("job-action")], [text(action)]),
          ],
        ),
        lease_bar(holder, timeout, b.now),
      ])
    board.Waiting(pool, at) ->
      html.li([class("slot slot-free")], [
        id,
        html.span([class("slot-state")], [
          text(
            "idle in "
            <> pool
            <> " · polled "
            <> board.span(b.now - at)
            <> " ago",
          ),
        ]),
      ])
    board.Quiet(pool, at) ->
      html.li([class("slot slot-gone")], [
        id,
        html.span([class("slot-state")], [
          text("silent " <> board.span(b.now - at) <> " · last polled " <> pool),
        ]),
      ])
    board.Unseen ->
      html.li([class("slot slot-gone")], [
        id,
        html.span([class("slot-state")], [
          text("no poll seen by this controller"),
        ]),
      ])
  }
}

/// The lease from grant to deadline: the action's timeout, then the slack.
/// The fill is the time elapsed, and the tick marks where the timeout ends.
fn lease_bar(holder: board.Holder, timeout: Int, now: Int) -> Element(Msg) {
  let whole = int.max(holder.until - holder.granted, 1)
  let elapsed = int.clamp(now - holder.granted, 0, whole)
  let percent = fn(part: Int) { int.to_string(part * 100 / whole) <> "%" }
  let left = holder.until - now
  let late = now - holder.granted > timeout
  html.div([class("lease")], [
    html.div(
      [
        class(case late {
          True -> "lease-track late"
          False -> "lease-track"
        }),
      ],
      [
        html.span(
          [class("lease-fill"), attribute.style("width", percent(elapsed))],
          [],
        ),
        html.span(
          [class("lease-tick"), attribute.style("left", percent(timeout))],
          [],
        ),
      ],
    ),
    html.span([class("lease-words")], [
      text(
        board.span(now - holder.granted)
        <> " · try "
        <> int.to_string(holder.attempt)
        <> "/3 · lapses in "
        <> board.span(left),
      ),
    ]),
  ])
}

// ---------------------------------------------------------------------------
// The run list
// ---------------------------------------------------------------------------

/// Draw the middle pane: the run rows and the legend.
fn runs(m: Model, b: Board) -> Element(Msg) {
  html.section([class("runs"), attribute.aria_label("Runs")], [
    html.h2([class("pane-title")], [
      text("Runs"),
      html.span([class("pane-count")], [
        text(int.to_string(list.length(b.runs))),
      ]),
      legend(),
    ]),
    case b.runs {
      [] -> html.p([class("quiet-note")], [text("No runs are retained.")])
      rows -> html.div([class("run-list")], list.map(rows, run_row(_, m)))
    },
  ])
}

/// Draw the key to the cell colours.
fn legend() -> Element(Msg) {
  html.span(
    [class("legend"), attribute.aria_hidden(True)],
    list.map(
      [
        board.Ready,
        board.Active,
        board.Passed,
        board.Reused,
        board.Failed,
        board.Expired,
        board.Blocked,
        board.Skipped,
      ],
      fn(cell) {
        let label = board.cell_label(cell)
        html.span([class("legend-item")], [
          html.span([class("cell c-" <> label)], []),
          text(label),
        ])
      },
    ),
  )
}

/// Draw one run row, selectable, with its health, lane, and action strip.
fn run_row(run: RunRow, m: Model) -> Element(Msg) {
  let chosen = m.chosen_run == Some(run.id)
  html.article(
    [
      class(
        "run h-"
        <> health_label(run.diagnosis.health)
        <> case chosen {
          True -> " chosen"
          False -> ""
        },
      ),
      event.on_click(model.RunChosen(run.id)),
    ],
    [
      lane_glyph(run),
      html.div([class("run-head")], [
        html.span([class("run-id")], [text(run.id)]),
        html.span([class("run-meta")], [
          text(run.repo <> " · " <> run.target <> revision(run.revision)),
        ]),
        html.span([class("phase p-" <> board.phase_label(run.phase))], [
          text(board.phase_label(run.phase)),
        ]),
      ]),
      strip(run),
      html.p([class("diag")], [text(run.diagnosis.text)]),
    ],
  )
}

fn revision(sha: String) -> String {
  case sha {
    "" -> ""
    _ -> " · " <> string.slice(sha, 0, 7)
  }
}

/// Name a health state in one word.
fn health_label(health: board.Health) -> String {
  case health {
    board.Moving -> "moving"
    board.Stalled -> "stalled"
    board.Settled -> "settled"
    board.Broken -> "broken"
  }
}

/// A short track ending in the group's landing signal. A plain build has no
/// lane, so it draws a dashed spur with no signal.
fn lane_glyph(run: RunRow) -> Element(Msg) {
  let label = board.signal_label(run.signal)

  // A run with a lane shows it in the title.
  let title = case run.lane {
    Some(lane) -> label <> " · " <> lane
    None -> "build · no lane"
  }

  html.svg(
    [
      class("lane s-" <> label),
      attribute("viewBox", "0 0 40 14"),
      attribute.role("img"),
      attribute.aria_label(title),
    ],
    [
      svg.title([], [text(title)]),
      svg.line([
        class("lane-rail"),
        attribute("x1", "1"),
        attribute("y1", "7"),
        attribute("x2", "30"),
        attribute("y2", "7"),
      ]),
      case run.signal {
        board.NoLane -> element.none()
        _ ->
          svg.circle([
            class("lane-signal"),
            attribute("cx", "34"),
            attribute("cy", "7"),
            attribute("r", "4.5"),
          ])
      },
    ],
  )
}

/// The run's graph as columns of cells, one column per layer. Each cell is a
/// button that opens that action.
fn strip(run: RunRow) -> Element(Msg) {
  html.div(
    [class("strip")],
    board.by_layer(run.actions)
      |> list.map(fn(layer) {
        html.div(
          [
            class("layer"),
            attribute.style(
              "grid-template-rows",
              "repeat("
                <> int.to_string(int.min(list.length(layer), 4))
                <> ", 10px)",
            ),
          ],
          list.map(layer, fn(action) {
            let label = board.cell_label(action.cell)
            html.button(
              [
                class("cell c-" <> label),
                attribute.title(action.name <> " · " <> label),
                attribute.aria_label(action.name <> ", " <> label),
                event.on_click(model.ActionChosen(run.id, action.name))
                  |> event.stop_propagation,
              ],
              [],
            )
          }),
        )
      }),
  )
}

// ---------------------------------------------------------------------------
// The chosen run
// ---------------------------------------------------------------------------

/// Draw the right pane for the chosen run: its facts, graph, and the chosen action.
fn detail(m: Model, b: Board) -> Element(Msg) {
  // The chosen run id is looked up in the board, and an unknown id finds nothing.
  let chosen = case m.chosen_run {
    Some(id) -> board.find(b, id)
    None -> Error(Nil)
  }

  html.section(
    [class("detail"), attribute.aria_label("Chosen run")],
    case chosen {
      Error(Nil) -> [
        html.p([class("quiet-note")], [text("Choose a run to see its graph.")]),
      ]
      Ok(run) -> [
        html.header([class("detail-head")], [
          lane_glyph(run),
          html.h2([class("detail-id")], [text(run.id)]),
          html.span([class("phase p-" <> board.phase_label(run.phase))], [
            text(board.phase_label(run.phase)),
          ]),
        ]),
        html.p([class("detail-meta")], [
          text(run.repo <> " · " <> run.target <> revision(run.revision)),
          case run.lane, run.members {
            Some(lane), members ->
              text(
                " · "
                <> board.signal_label(run.signal)
                <> " in "
                <> lane
                <> members_text(members),
              )
            None, _ -> element.none()
          },
        ]),
        html.p([class("detail-diag h-" <> health_label(run.diagnosis.health))], [
          text(run.diagnosis.text),
        ]),
        html.p(
          [class("tally")],
          list.map(board.tally(run.actions), fn(pair) {
            let label = board.cell_label(pair.0)
            html.span([class("tally-item")], [
              html.span([class("cell c-" <> label)], []),
              text(int.to_string(pair.1) <> " " <> label),
            ])
          }),
        ),
        graph(run, m.chosen_action),
        case m.chosen_action {
          Some(name) ->
            case list.find(run.actions, fn(a) { a.name == name }) {
              Ok(action) -> action_pane(run, action, m, b)
              Error(Nil) -> element.none()
            }
          None ->
            html.p([class("quiet-note")], [
              text("Choose an action to see its lease, timing, and log."),
            ])
        },
      ]
    },
  )
}

/// Write the pull numbers of a landing group as a list.
fn members_text(members: List(Int)) -> String {
  case members {
    [] -> ""
    _ ->
      " · "
      <> string.join(list.map(members, fn(p) { "#" <> int.to_string(p) }), " ")
  }
}

/// Draw a run's action graph as nodes laid out by layer with a curve for each prerequisite.
fn graph(run: RunRow, chosen: Option(String)) -> Element(Msg) {
  use <- bool.guard(run.actions == [], element.none())
  let placed = layout.place(run.actions)
  let touches = fn(edge: layout.Edge) {
    chosen == Some(edge.from) || chosen == Some(edge.to)
  }
  html.div([class("graph")], [
    html.svg(
      [
        attribute(
          "viewBox",
          "0 0 "
            <> int.to_string(placed.width)
            <> " "
            <> int.to_string(placed.height),
        ),
        attribute("width", int.to_string(placed.width)),
        attribute("height", int.to_string(placed.height)),
        attribute.role("img"),
        attribute.aria_label("Action graph of " <> run.id),
      ],
      list.append(
        list.map(placed.edges, fn(edge) {
          svg.path([
            class(case touches(edge) {
              True -> "edge lit"
              False -> "edge"
            }),
            attribute("d", edge.path),
          ])
        }),
        list.map(placed.nodes, fn(node) { graph_node(run, node, chosen) }),
      ),
    ),
  ])
}

/// Draw one graph node, marked when it is the chosen action.
fn graph_node(
  run: RunRow,
  node: layout.Node,
  chosen: Option(String),
) -> Element(Msg) {
  let label = board.cell_label(node.action.cell)
  let picked = chosen == Some(node.action.name)
  svg.g(
    [
      class(
        "node n-"
        <> label
        <> case picked {
          True -> " picked"
          False -> ""
        },
      ),
      attribute(
        "transform",
        "translate("
          <> int.to_string(node.x)
          <> " "
          <> int.to_string(node.y)
          <> ")",
      ),
      event.on_click(model.ActionChosen(run.id, node.action.name)),
    ],
    [
      svg.title([], [text(node.action.name <> " · " <> label)]),
      svg.rect([
        class("node-box"),
        attribute("width", int.to_string(layout.node_width)),
        attribute("height", int.to_string(layout.node_height)),
        attribute("rx", "3"),
      ]),
      svg.rect([
        class("node-state"),
        attribute("width", "4"),
        attribute("height", int.to_string(layout.node_height)),
        attribute("rx", "1"),
      ]),
      svg.text(
        [class("node-name"), attribute("x", "11"), attribute("y", "16")],
        shorten(node.action.name, 21),
      ),
    ],
  )
}

fn shorten(name: String, most: Int) -> String {
  case string.length(name) > most {
    True -> string.slice(name, 0, most - 1) <> "…"
    False -> name
  }
}

/// Draw the facts and log of the chosen action.
fn action_pane(
  run: RunRow,
  action: Action,
  m: Model,
  b: Board,
) -> Element(Msg) {
  let label = board.cell_label(action.cell)

  // The timing record decides how the action's time reads.
  let time = case timing.of(m.memory, run.id, action.name, b.now) {
    timing.Running(seconds) -> "running " <> board.span(seconds)
    timing.Took(seconds) -> "took about " <> board.span(seconds)
    timing.Unknown ->
      case action.cell {
        board.Reused -> "reused a stored proof; no time spent"
        board.Blocked | board.Ready -> "not started"
        board.Skipped -> "never ran"
        board.Active | board.Passed | board.Failed | board.Expired ->
          "finished before this page opened"
      }
  }

  html.div([class("action")], [
    html.header([class("action-head")], [
      html.span([class("cell c-" <> label)], []),
      html.h3([class("action-name")], [text(action.name)]),
      html.span([class("action-state")], [text(label)]),
    ]),
    html.dl([class("facts")], [
      fact("pool", text(action.pool)),
      fact("argv", html.code([], [text(string.join(action.argv, " "))])),
      fact(
        "needs",
        text(case action.needs {
          [] -> "nothing"
          needs -> string.join(needs, ", ")
        }),
      ),
      fact("time", text(time <> " · timeout " <> board.span(action.timeout))),
      case action.holder {
        Some(holder) ->
          fact(
            "lease",
            text(
              holder.worker
              <> case holder.host {
                Some(host) -> " on " <> host
                None -> ", host not labelled"
              }
              <> " · attempt "
              <> int.to_string(holder.attempt)
              <> " of 3 · lapses in "
              <> board.span(holder.until - b.now),
            ),
          )
        None ->
          case action.attempts {
            0 -> element.none()
            n -> fact("attempts", text(int.to_string(n) <> " earlier"))
          }
      },
      case action.reason {
        Some(reason) -> fact("reason", text(reason))
        None -> element.none()
      },
    ]),
    log_pane(action, m.log),
  ])
}

fn fact(label: String, value: Element(Msg)) -> Element(Msg) {
  html.div([class("fact")], [html.dt([], [text(label)]), html.dd([], [value])])
}

/// Draw the chosen action's log, or the reason it is not shown.
fn log_pane(action: Action, log: model.Log) -> Element(Msg) {
  case action.log, log {
    None, _ ->
      html.p([class("log-note")], [
        text(case action.cell {
          board.Active -> "The log arrives with the result."
          _ -> "No log for this action."
        }),
      ])
    Some(digest), model.Loaded(have, body) if have == digest ->
      html.figure([class("log")], [
        html.figcaption([], [
          text("log " <> string.slice(digest, 0, 12) <> " · last "),
          text(int.to_string(model.log_lines) <> " lines"),
        ]),
        html.pre([class("log-body")], [text(body)]),
      ])
    Some(digest), model.LogFailed(have, reason) if have == digest ->
      html.p([class("log-note bad")], [text("Cannot read the log: " <> reason)])
    Some(_), _ -> html.p([class("log-note")], [text("Reading the log…")])
  }
}
