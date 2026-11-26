//// Place a run's graph for drawing: one column per layer, actions stacked in
//// their queue order, and one curve per dependency from the prerequisite's
//// right edge to the dependent's left edge. The numbers are SVG user units.

import dashboard/board.{type Action}
import gleam/dict
import gleam/int
import gleam/list
import gleam/result

/// Width of one action's box.
pub const node_width = 168

/// Height of one action's box.
pub const node_height = 24

const column_gap = 44

const row_gap = 6

const margin = 4

/// One placed action.
pub type Node {
  Node(action: Action, x: Int, y: Int)
}

/// One dependency, from `from` to `to`, as an SVG path.
pub type Edge {
  Edge(from: String, to: String, path: String)
}

/// A placed graph and the size of its canvas.
pub type Layout {
  Layout(nodes: List(Node), edges: List(Edge), width: Int, height: Int)
}

/// Place every action and draw every dependency between placed actions.
///
/// ## Examples
///
/// ```gleam
/// // layout.place(row.actions).width
/// ```
pub fn place(actions: List(Action)) -> Layout {
  let nodes =
    board.by_layer(actions)
    |> list.index_map(fn(layer, column) {
      list.index_map(layer, fn(action, row) {
        Node(
          action:,
          x: margin + column * { node_width + column_gap },
          y: margin + row * { node_height + row_gap },
        )
      })
    })
    |> list.flatten
  let at =
    list.map(nodes, fn(node) { #(node.action.name, node) }) |> dict.from_list
  let edges =
    list.flat_map(nodes, fn(node) {
      list.filter_map(node.action.needs, fn(need) {
        use from <- result.map(dict.get(at, need))
        Edge(need, node.action.name, curve(from, node))
      })
    })
  let width =
    list.fold(nodes, 0, fn(w, node) { int.max(w, node.x + node_width) })
  let height =
    list.fold(nodes, 0, fn(h, node) { int.max(h, node.y + node_height) })
  Layout(nodes:, edges:, width: width + margin, height: height + margin)
}

/// Draw the cubic path from the right edge of one node to the left edge of another, bending at the midpoint between them.
fn curve(from: Node, to: Node) -> String {
  let x1 = from.x + node_width
  let y1 = from.y + node_height / 2
  let x2 = to.x
  let y2 = to.y + node_height / 2
  let bend = { x2 - x1 } / 2
  "M"
  <> int.to_string(x1)
  <> " "
  <> int.to_string(y1)
  <> " C"
  <> int.to_string(x1 + bend)
  <> " "
  <> int.to_string(y1)
  <> " "
  <> int.to_string(x2 - bend)
  <> " "
  <> int.to_string(y2)
  <> " "
  <> int.to_string(x2)
  <> " "
  <> int.to_string(y2)
}
