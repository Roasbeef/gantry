import gleam/list
import qcheck
import queue_dst

pub fn seeded_fault_corpus_is_deterministic_test() {
  list.each([1, 19, 73, 2026, 48_271, 999_983], fn(seed) {
    assert queue_dst.run_seed(seed, 128) == queue_dst.run_seed(seed, 128)
  })
}

pub fn fuzz_fault_schedules_test() {
  let masks = qcheck.bounded_int(0, 127)
  let events =
    qcheck.generic_list(qcheck.bounded_int(0, 255), qcheck.bounded_int(0, 160))
  qcheck.run(
    qcheck.config(test_count: 240, max_retries: 1, seed: qcheck.seed(6131)),
    qcheck.tuple2(masks, events),
    fn(sample) {
      let #(mask, ops) = sample
      assert queue_dst.run(mask, ops) == queue_dst.run(mask, ops)
    },
  )
}
