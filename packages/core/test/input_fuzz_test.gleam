//// Mutate valid graph and worker JSON with replayable, shrinkable edits.

import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import qcheck

const cases = 100

pub fn graph_manifest_and_action_json_mutations_test() {
  list.each([1057, 9081], fn(seed) {
    qcheck.run(config(seed), input(), fn(input) {
      let #(number, argument, edit) = input
      let name = "action-" <> int.to_string(number)
      let timeout = number % 3600 + 1
      let action =
        graph.action(name, [argument], ["src"], ["out/file"], [], [], timeout)
      let required = [
        #("name", json.string(name)),
        #("argv", strings([argument])),
      ]
      let optional = [
        #("inputs", strings(["src"])),
        #("outputs", strings(["out/file"])),
        #("deps", strings([])),
        #("after", strings([])),
        #("timeout", json.int(timeout)),
      ]
      let fields = list.append(required, optional)
      assert_json(fields, graph.action_decoder(), action, argument, edit)
      let defaults = graph.action(name, [argument], ["."], [], [], [], 300)
      let assert True =
        json.parse(object(required), graph.action_decoder()) == Ok(defaults)

      let manifest = [
        #("actions", json.preprocessed_array([json.object(fields)])),
        #("targets", json.object([#("check", strings([name]))])),
      ]
      let body = object(manifest)
      let assert True = graph.compile(body, "check") == Ok([action])
      let assert True =
        graph.compile(" \n" <> body <> "\t ", "check") == Ok([action])
      list.each(damage(body, edit), fn(body) {
        let assert Error("invalid build manifest") =
          graph.compile(body, "check")
        Nil
      })
      list.each(manifest, fn(field) {
        let removed = drop_field(manifest, field.0)
        list.each(
          [removed, [#(field.0, json.bool(False)), ..removed]],
          fn(fields) {
            let assert Error("invalid build manifest") =
              graph.compile(object(fields), "check")
            Nil
          },
        )
      })

      list.each(required, fn(field) {
        assert_rejected(drop_field(fields, field.0), graph.action_decoder())
      })
      assert_wrong_types(fields, graph.action_decoder())
      list.each(["argv", "inputs", "outputs", "deps", "after"], fn(field) {
        assert_rejected(
          [
            #(field, json.preprocessed_array([json.int(number)])),
            ..drop_field(fields, field)
          ],
          graph.action_decoder(),
        )
      })
    })
  })
}

pub fn completion_json_mutations_test() {
  list.each([2371, 5149], fn(seed) {
    qcheck.run(config(seed), input(), fn(input) {
      let #(number, log, edit) = input
      let artifact = queue.Artifact("out/" <> int.to_string(number), log)
      let file_fields = [
        #("path", json.string(artifact.path)),
        #("digest", json.string(artifact.digest)),
      ]
      let succeeded = [
        #("kind", json.string("succeeded")),
        #("files", json.preprocessed_array([json.object(file_fields)])),
        #("log", json.string(log)),
      ]
      let rejected = [
        #("kind", json.string("rejected")),
        #("reason", json.string("failed-" <> int.to_string(number))),
        #("log", json.string(log)),
      ]
      let decoder = protocol.completion_decoder()
      assert_json(
        succeeded,
        decoder,
        queue.Succeeded([artifact], log),
        log,
        edit,
      )
      assert_json(
        rejected,
        decoder,
        queue.Rejected("failed-" <> int.to_string(number), log),
        log,
        edit,
      )
      list.each([succeeded, rejected], fn(fields) {
        assert_wrong_types(fields, decoder)
        list.each(fields, fn(field) {
          assert_rejected(drop_field(fields, field.0), decoder)
        })
        assert_rejected(
          [
            #("kind", json.string("unknown-" <> log)),
            ..drop_field(fields, "kind")
          ],
          decoder,
        )
      })
      list.each(file_fields, fn(field) {
        let removed = drop_field(file_fields, field.0)
        list.each(
          [removed, [#(field.0, json.int(number)), ..removed]],
          fn(fields) {
            let files = json.preprocessed_array([json.object(fields)])
            assert_rejected(
              [#("files", files), ..drop_field(succeeded, "files")],
              decoder,
            )
          },
        )
      })
    })
  })
}

fn config(seed: Int) -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(cases)
  |> qcheck.with_seed(qcheck.seed(seed))
}

fn input() -> qcheck.Generator(#(Int, String, Int)) {
  let text =
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(from: 0, to: 7),
      length_from: qcheck.bounded_int(from: 0, to: 12),
    )
    |> qcheck.map(fn(indices) {
      let alphabet = ["a", "/", "λ", "🇨🇦", "\"", "\\", "\n", "\t"]
      list.filter_map(indices, fn(index) {
        list.first(list.drop(alphabet, index))
      })
      |> string.concat
    })
  qcheck.tuple3(
    qcheck.bounded_int(from: 0, to: 20_000),
    text,
    qcheck.bounded_int(from: 0, to: 2048),
  )
}

fn assert_json(
  fields: List(#(String, json.Json)),
  decoder: decode.Decoder(a),
  value: a,
  extra: String,
  edit: Int,
) -> Nil {
  let original = object(fields)
  let assert True = json.parse(original, decoder) == Ok(value)
  let assert True = json.parse(" \n" <> original <> "\t ", decoder) == Ok(value)
  let assert True =
    json.parse(object([#("unknown", json.string(extra)), ..fields]), decoder)
    == Ok(value)
  list.each(damage(original, edit), fn(body) {
    let assert Error(_) = json.parse(body, decoder)
    Nil
  })
}

fn damage(body: String, edit: Int) -> List(String) {
  // Removing the closing brace always truncates the object. A raw NUL
  // is invalid both inside and outside of a JSON string.
  let at = edit % string.length(body)
  let prefix = string.slice(body, 0, at)
  let suffix = string.drop_start(body, at)
  [prefix, prefix <> "\u{0000}" <> suffix]
}

fn assert_wrong_types(
  fields: List(#(String, json.Json)),
  decoder: decode.Decoder(a),
) -> Nil {
  list.each(fields, fn(field) {
    assert_rejected(
      [#(field.0, json.bool(True)), ..drop_field(fields, field.0)],
      decoder,
    )
  })
}

fn assert_rejected(
  fields: List(#(String, json.Json)),
  decoder: decode.Decoder(a),
) -> Nil {
  let assert Error(json.UnableToDecode(_)) = json.parse(object(fields), decoder)
  Nil
}

fn drop_field(
  fields: List(#(String, json.Json)),
  name: String,
) -> List(#(String, json.Json)) {
  list.filter(fields, fn(field) { field.0 != name })
}

fn object(fields: List(#(String, json.Json))) -> String {
  json.object(fields) |> json.to_string
}

fn strings(values: List(String)) -> json.Json {
  json.array(values, json.string)
}
