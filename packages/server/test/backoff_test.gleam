import gantry/worker
import gleam/list

pub fn first_idle_polls_are_short_test() {
  assert worker.poll_delay(0, 0) == 250
  assert worker.poll_delay(0, 999) == 499
}

pub fn the_ceiling_doubles_then_caps_at_two_seconds_test() {
  assert worker.poll_delay(1, 999) == 999
  assert worker.poll_delay(2, 999) == 1999
  assert worker.poll_delay(50, 999) == 1999
}

pub fn jitter_spreads_waits_across_the_upper_half_test() {
  assert worker.poll_delay(2, 0) == 1000
  assert worker.poll_delay(2, 500) == 1500
}

pub fn every_delay_stays_inside_its_bounds_test() {
  list.each([0, 1, 2, 3, 10, 1000], fn(streak) {
    list.each([0, 1, 250, 999], fn(entropy) {
      let delay = worker.poll_delay(streak, entropy)
      assert delay >= 250
      assert delay <= 2000
    })
  })
}

pub fn out_of_range_entropy_is_clamped_test() {
  assert worker.poll_delay(2, -5) == 1000
  assert worker.poll_delay(2, 100_000) == 1999
}

pub fn delays_never_shrink_as_the_streak_grows_test() {
  list.each([0, 250, 999], fn(entropy) {
    assert worker.poll_delay(0, entropy) <= worker.poll_delay(1, entropy)
    assert worker.poll_delay(1, entropy) <= worker.poll_delay(2, entropy)
  })
}
