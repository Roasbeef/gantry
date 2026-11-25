import gantry/reconcile
import gleam/dict

pub fn an_unseen_intent_is_due_test() {
  assert reconcile.due(dict.new(), "run@abc", 0)
}

pub fn a_failed_intent_waits_one_second_first_test() {
  let retries = reconcile.failed(dict.new(), "run@abc", 5000)
  assert !reconcile.due(retries, "run@abc", 5999)
  assert reconcile.due(retries, "run@abc", 6000)
}

pub fn repeated_failures_double_the_delay_up_to_a_minute_test() {
  // Failing at each moment the intent becomes due again.
  let first = reconcile.failed(dict.new(), "run@abc", 0)
  let second = reconcile.failed(first, "run@abc", 1000)
  assert !reconcile.due(second, "run@abc", 2999)
  assert reconcile.due(second, "run@abc", 3000)

  let third = reconcile.failed(second, "run@abc", 3000)
  assert !reconcile.due(third, "run@abc", 6999)
  assert reconcile.due(third, "run@abc", 7000)

  // The delay stops growing at sixty seconds.
  let capped = repeat_failures(dict.new(), 20)
  let assert Ok(reconcile.Retry(delay: 60_000, ..)) =
    dict.get(capped, "run@abc")
}

pub fn one_intents_backoff_does_not_delay_another_test() {
  let retries = reconcile.failed(dict.new(), "run@abc", 0)
  assert reconcile.due(retries, "run@def", 0)
}

pub fn a_resolved_intent_starts_fresh_test() {
  let retries = reconcile.failed(dict.new(), "run@abc", 0)
  let retries = reconcile.resolved(retries, "run@abc")
  assert reconcile.due(retries, "run@abc", 0)
  assert retries == dict.new()
}

fn repeat_failures(
  retries: dict.Dict(String, reconcile.Retry),
  remaining: Int,
) -> dict.Dict(String, reconcile.Retry) {
  case remaining {
    0 -> retries
    _ -> repeat_failures(reconcile.failed(retries, "run@abc", 0), remaining - 1)
  }
}
