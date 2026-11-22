//// Generated manifests exercise closure, stable ordering, and graph validation.

import gantry_core/graph
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/set
import qcheck

const cases = 160

pub fn generated_dag_matches_reachability_and_order_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(cases)
    |> qcheck.with_seed(qcheck.seed(3184))
  qcheck.run(config, dag(), fn(input) {
    let #(actions, roots) = input
    let assert Ok(actual) = graph.compile(manifest(actions, roots), "check")
    let by_name =
      dict.from_list(list.map(actions, fn(action) { #(action.name, action) }))
    let selected = reachable(by_name, roots, set.new())
    // Stable sorting by longest prerequisite chain retains declaration
    // order among actions that become ready in the same pass.
    let expected =
      list.filter(actions, fn(action) { set.contains(selected, action.name) })
      |> list.sort(fn(a, b) {
        int.compare(depth(by_name, a), depth(by_name, b))
      })
    let assert True = actual == expected
    Nil
  })
}

pub fn generated_invalid_graphs_are_rejected_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(cases)
    |> qcheck.with_seed(qcheck.seed(9653))
  qcheck.run(config, dag(), fn(input) {
    let #(actions, roots) = input
    // Appended fixtures keep the original target and graph valid while
    // testing validation of declarations beyond the selected closure.
    let assert [first, ..] = actions
    let spare = graph.Action("spare", ["true"], ["."], [], [], [], 60)
    let cycle = graph.Action(..spare, after: [first.name])
    let circles =
      list.map(actions, fn(action) {
        case action.name == first.name {
          True ->
            graph.Action(..action, dependencies: [
              spare.name,
              ..action.dependencies
            ])
          False -> action
        }
      })
    let assert Error("cycle in action graph") =
      graph.compile(manifest(list.append(circles, [cycle]), roots), "check")
    let assert [output] = first.outputs
    let invalid = [
      #(list.append(actions, [graph.Action(..first, outputs: [])]), roots),
      #(
        list.append(actions, [graph.Action(..spare, after: ["missing"])]),
        roots,
      ),
      #(
        list.append(actions, [
          graph.Action(..spare, outputs: [output <> "/nested"]),
        ]),
        roots,
      ),
      #(actions, ["missing"]),
      #(actions, []),
    ]
    list.each(invalid, fn(input) {
      let #(actions, roots) = input
      let assert Error(
        "empty target, unknown action, duplicate action or overlapping output",
      ) = graph.compile(manifest(actions, roots), "check")
      Nil
    })
  })
}

fn dag() -> qcheck.Generator(#(List(graph.Action), List(String))) {
  use size <- qcheck.bind(qcheck.bounded_int(from: 1, to: 9))
  let names =
    list.repeat(Nil, size)
    |> list.index_map(fn(_, index) { action_name(index) })
  let row =
    qcheck.tuple3(
      qcheck.fixed_length_list_from(qcheck.bounded_int(from: 0, to: 5), size),
      qcheck.bounded_int(from: 0, to: 50),
      qcheck.bool(),
    )
  use rows <- qcheck.map(qcheck.fixed_length_list_from(row, size))
  let declarations =
    list.index_map(rows, fn(row, index) {
      let #(edges, rank, root) = row
      let incoming = list.zip(list.take(names, index), list.take(edges, index))
      let deps =
        list.filter_map(incoming, fn(edge) {
          case edge {
            #(name, 1) -> Ok(name)
            _ -> Error(Nil)
          }
        })
      let after =
        list.filter_map(incoming, fn(edge) {
          case edge {
            #(name, 2) -> Ok(name)
            _ -> Error(Nil)
          }
        })
      let name = action_name(index)
      #(
        graph.Action(name, ["true"], ["."], ["out/" <> name], deps, after, 60),
        rank,
        root || index == size - 1,
      )
    })
    |> list.sort(fn(a, b) { int.compare(a.1, b.1) })
  let roots =
    list.filter_map(declarations, fn(row) {
      case row {
        #(action, _, True) -> Ok(action.name)
        _ -> Error(Nil)
      }
    })
  #(list.map(declarations, fn(row) { row.0 }), roots)
}

fn action_name(index: Int) -> String {
  "action-" <> int.to_string(index)
}

fn manifest(actions: List(graph.Action), roots: List(String)) -> String {
  json.object([
    #("actions", json.array(actions, graph.encode_action)),
    #("targets", json.object([#("check", json.array(roots, json.string))])),
  ])
  |> json.to_string
}

fn reachable(
  by_name: dict.Dict(String, graph.Action),
  pending: List(String),
  visited: set.Set(String),
) -> set.Set(String) {
  case pending {
    [] -> visited
    [name, ..rest] -> {
      case set.contains(visited, name) {
        True -> reachable(by_name, rest, visited)
        False -> {
          let assert Ok(action) = dict.get(by_name, name)
          reachable(
            by_name,
            list.flatten([action.dependencies, action.after, rest]),
            set.insert(visited, name),
          )
        }
      }
    }
  }
}

fn depth(
  by_name: dict.Dict(String, graph.Action),
  action: graph.Action,
) -> Int {
  list.append(action.dependencies, action.after)
  |> list.fold(0, fn(longest, name) {
    let assert Ok(prerequisite) = dict.get(by_name, name)
    int.max(longest, 1 + depth(by_name, prerequisite))
  })
}
