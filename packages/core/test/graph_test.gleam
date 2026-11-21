import gantry_core/graph

pub fn distinct_sort_neighbors_cannot_hide_an_output_prefix_test() {
  let manifest =
    "{
    \"actions\": [
      {\"name\": \"one\", \"argv\": [\"true\"], \"outputs\": [\"lib\"]},
      {\"name\": \"two\", \"argv\": [\"true\"], \"outputs\": [\"lib-alt\"]},
      {\"name\": \"three\", \"argv\": [\"true\"], \"outputs\": [\"lib/file\"]}
    ],
    \"targets\": {\"check\": [\"one\", \"two\", \"three\"]}
  }"
  let assert Error(_) = graph.compile(manifest, "check")
    as "file ownership overlaps"
}
