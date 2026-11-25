//// Generated admission requests check the one owner of the request rules
//// against independent reference predicates and its own encoding.

import gantry_core/graph
import gantry_core/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import qcheck

const cases = 200

pub fn generated_build_round_trips_test() {
  qcheck.run(config(4127), build_input(), fn(input) {
    let #(id, revision, target, action) = input
    let assert Ok(pinned) =
      request.build(id, "owner/project", revision, target, action)
    let body = json.to_string(request.encode_build(pinned))
    assert request.parse_build(body) == Ok(pinned)
    assert request.build_id(pinned) == id
    assert request.action(pinned) == action
  })
}

pub fn generated_unknown_keys_are_rejected_test() {
  qcheck.run(config(7741), tuple_with_key(build_input()), fn(input) {
    let #(#(id, revision, target, action), key) = input
    let base = [
      #("id", json.string(id)),
      #("repo", json.string("owner/project")),
      #("revision", json.string(revision)),
      #("target", json.string(target)),
    ]

    // A key outside the request is reported at the top level.
    let top = json.object([#(key, json.null()), ..base])
    assert request.parse_build(json.to_string(top))
      == Error(request.UnknownField(key))

    // A key outside the action is reported with its nested path.
    let nested =
      json.object([
        #(
          "action",
          json.object([
            #(key, json.int(1)),
            #("name", json.string("adhoc")),
            #("argv", json.array(["true"], json.string)),
          ]),
        ),
        ..base
      ])
    assert request.parse_build(json.to_string(nested))
      == Error(request.UnknownField("action." <> key))

    let group =
      json.object([
        #(key, json.int(1)),
        #("id", json.string(id)),
        #("repo", json.string("owner/project")),
        #("pulls", json.array([1], json.int)),
      ])
    assert request.parse_submit(json.to_string(group))
      == Error(request.UnknownField(key))
    let _ = action
    Nil
  })
}

pub fn generated_pulls_match_group_bounds_test() {
  let pulls =
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(from: -2, to: 24),
      length_from: qcheck.bounded_int(from: 0, to: 20),
    )
  qcheck.run(config(2203), pulls, fn(pulls) {
    let expected =
      list.length(pulls) >= 1
      && list.length(pulls) <= 16
      && set.size(set.from_list(pulls)) == list.length(pulls)
      && list.all(pulls, fn(pull) { pull > 0 })
    let body =
      json.object([
        #("id", json.string("group")),
        #("repo", json.string("owner/project")),
        #("pulls", json.array(pulls, json.int)),
      ])
      |> json.to_string
    let parsed = request.parse_submit(body)
    case expected {
      True -> {
        let assert Ok(group) = parsed
        assert request.pulls(group) == pulls
        assert request.parse_submit(
            json.to_string(request.encode_submit(group)),
          )
          == Ok(group)
      }
      False -> {
        assert parsed == Error(request.InvalidPulls)
      }
    }
  })
}

pub fn generated_ad_hoc_edges_are_rejected_test() {
  let edges =
    qcheck.tuple2(
      qcheck.bounded_int(from: 0, to: 3),
      qcheck.bounded_int(from: 0, to: 3),
    )
  qcheck.run(config(5519), edges, fn(counts) {
    let #(deps, after) = counts
    let names = fn(count) { numbered("edge-", count) }
    let action =
      graph.Action("adhoc", ["true"], [], [], names(deps), names(after), 60)
    let result = request.check_action(action)
    case deps + after {
      0 -> {
        assert result == Ok(Nil)
      }
      _ -> {
        assert result == Error(request.AdHocDependencies)
      }
    }
  })
}

pub fn generated_ids_match_reference_rule_test() {
  let alphabet = ["a", "Z", "0", ".", "-", "_", "/", "g", "i", "t", " ", "é"]
  let text =
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(from: 0, to: 11),
      length_from: qcheck.bounded_int(from: 0, to: 6),
    )
    |> qcheck.map(fn(indices) {
      list.filter_map(indices, fn(index) {
        list.first(list.drop(alphabet, index))
      })
      |> string.concat
    })
  qcheck.run(config(8861), text, fn(id) {
    let safe =
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    let expected =
      id != ""
      && !list.contains([".", "..", ".git"], id)
      && list.all(string.to_graphemes(id), fn(c) { string.contains(safe, c) })
    assert request.valid_id(id) == expected
  })
}

pub fn non_object_body_is_invalid_json_test() {
  list.each(["", "[]", "null", "1", "\"x\"", "{"], fn(body) {
    assert request.parse_build(body) == Error(request.InvalidJson)
    assert request.parse_submit(body) == Error(request.InvalidJson)
  })
}

pub fn mistyped_field_is_named_test() {
  let body =
    "{\"id\":\"x\",\"repo\":\"o/p\",\"revision\":1,\"target\":\"check\"}"
  assert request.parse_build(body) == Error(request.MalformedField("revision"))
  let body = "{\"id\":\"x\",\"repo\":\"o/p\"}"
  assert request.parse_submit(body) == Error(request.MalformedField("pulls"))
  let body =
    "{\"id\":\"x\",\"repo\":\"o/p\",\"revision\":\""
    <> revision(1)
    <> "\",\"target\":\"t\",\"action\":[]}"
  assert request.parse_build(body) == Error(request.MalformedField("action"))
}

pub fn target_control_character_is_rejected_test() {
  list.each(["", "a\nb", "a\u{7f}"], fn(target) {
    assert request.build("x", "o/p", revision(2), target, None)
      == Error(request.InvalidTarget)
  })
  let assert Ok(_) = request.build("x", "o/p", revision(2), "-check λ", None)
}

pub fn largest_pull_is_the_inclusive_bound_test() {
  let assert Ok(_) = request.submit("g", "o/p", [request.largest_pull])
  assert request.submit("g", "o/p", [request.largest_pull + 1])
    == Error(request.InvalidPulls)
}

pub fn invalid_repository_is_rejected_test() {
  list.each(["owner", "../x", "o/p/q", "o/.."], fn(repo) {
    assert request.submit("g", repo, [1]) == Error(request.InvalidRepository)
  })
}

fn build_input() -> qcheck.Generator(
  #(String, String, String, option.Option(graph.Action)),
) {
  qcheck.tuple3(
    qcheck.bounded_int(from: 0, to: 100_000),
    qcheck.bounded_int(from: 0, to: 3),
    qcheck.bool(),
  )
  |> qcheck.map(fn(input) {
    let #(number, outputs, adhoc) = input
    let id = "run-" <> int.to_string(number)
    let action = case adhoc {
      True ->
        Some(graph.Action(
          "adhoc",
          ["sh", "-ec", "echo " <> int.to_string(number)],
          ["."],
          numbered("out/", outputs),
          [],
          [],
          number % 3600 + 1,
        ))
      False -> None
    }
    #(id, revision(number), "check-" <> int.to_string(number % 7), action)
  })
}

fn tuple_with_key(
  generator: qcheck.Generator(a),
) -> qcheck.Generator(#(a, String)) {
  qcheck.tuple2(generator, qcheck.bounded_int(from: 0, to: 999))
  |> qcheck.map(fn(pair) { #(pair.0, "extra_" <> int.to_string(pair.1)) })
}

fn numbered(prefix: String, count: Int) -> List(String) {
  list.index_map(list.repeat(Nil, count), fn(_, n) {
    prefix <> int.to_string(n + 1)
  })
}

fn revision(seed: Int) -> String {
  let digits = string.pad_start(int.to_base16(seed), 40, "0")
  string.lowercase(digits)
}

fn config(seed: Int) -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(cases)
  |> qcheck.with_seed(qcheck.seed(seed))
}
