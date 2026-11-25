import gleam/dict
import gleam/list
import queue_churn_dst

/// Every safety counter stays at zero, and every new fault class fires.
pub fn churn_corpus_is_safe_and_exercised_test() {
  let sweep = queue_churn_dst.sweep_counts(1, 64, 128)
  let count = fn(name) {
    case dict.get(sweep.totals, name) {
      Ok(n) -> n
      Error(Nil) -> 0
    }
  }
  list.each(queue_churn_dst.safety, fn(name) {
    assert count(name) == 0 as name
  })

  // The heal can strand only a lease held by a worker that vanished for good.
  assert count("stuck_active_other_seeds") == 0
  assert count("stuck_landing_seeds") == 0
  assert count("stuck_active_seeds") == count("stuck_active_vanished_seeds")
  list.each(
    [
      "crash_after_landings_before_push", "crash_after_push_before_record",
      "crash_after_record_before_reply", "concurrent_reconciles",
      "vanished_with_lease", "replayed_claims", "late_accepted", "cache_hits",
      "rejected_runs", "landed_runs", "blocked_runs",
    ],
    fn(name) {
      assert count(name) > 0 as name
    },
  )
}
