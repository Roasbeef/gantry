import gleam/dict
import gleam/list
import queue_churn_dst

/// Every safety counter stays at zero, the queue drains after the heal, and
/// every fault class fires.
pub fn churn_corpus_is_safe_live_and_exercised_test() {
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

  // Expiry reassigns every lease, so the heal strands nothing and every run
  // is terminal or waits on an unfinished run ahead of it in its lane.
  list.each(queue_churn_dst.liveness, fn(name) {
    assert count(name) == 0 as name
  })
  list.each(
    [
      "crash_after_landings_before_push", "crash_after_push_before_record",
      "crash_after_record_before_reply", "concurrent_reconciles",
      "vanished_with_lease", "replayed_claims", "late_accepted", "cache_hits",
      "rejected_runs", "landed_runs", "blocked_runs", "expiries",
      "reassignments", "expired_results_rejected", "returned_after_expiry",
      "poisoned_runs", "skipped_actions", "prepared_groups",
      "preparation_refusals", "policy_denials", "retained_dropped",
      "oversized_reasons", "staging_refusals",
    ],
    fn(name) {
      assert count(name) > 0 as name
    },
  )
}

/// A long stream of builds with oversized rejections keeps a bounded state.
pub fn retention_bounds_state_growth_test() {
  let #(small, held, reused) = queue_churn_dst.growth(200)
  let #(large, _, _) = queue_churn_dst.growth(1000)
  assert held == 8
  assert reused > 0
  assert small < 65_536
  assert large == small
}
