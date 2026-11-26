import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import qcheck
import queue_dst

pub fn seeded_fault_corpus_is_deterministic_test() {
  list.each([1, 19, 73, 2026, 48_271, 999_983], fn(seed) {
    assert queue_dst.run_seed(seed, 128) == queue_dst.run_seed(seed, 128)
  })
}

/// Every new fault class is reachable inside a fixed corpus of schedules.
pub fn new_faults_are_reachable_test() {
  let totals =
    int.range(1, 121, dict.new(), fn(totals, seed) {
      dict.fold(
        queue_dst.counts(queue_dst.run_seed(seed, 128)),
        totals,
        fn(totals, name, n) {
          dict.upsert(totals, name, fn(prior) {
            case prior {
              Some(m) -> m + n
              None -> n
            }
          })
        },
      )
    })
  list.each(
    [
      "expiries", "reassigned", "result_after_expiry_rejected",
      "result_after_reassign_rejected", "prepared", "preparation_refused",
      "policy_denied", "landed", "target_advanced", "retained_dropped",
      "userns_assignments",
    ],
    fn(name) {
      assert result.unwrap(dict.get(totals, name), 0) > 0 as name
    },
  )
}

pub fn fuzz_fault_schedules_test() {
  let masks = qcheck.bounded_int(0, 511)
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
