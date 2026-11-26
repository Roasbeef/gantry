//// The commit rule of the Erlang bridge against a real Khepri store: all
//// writes apply together or none do, an expectation compares what a decision
//// read, and a plan with no writes is confirmed by a quorum read. The
//// reference image in `gantry_core/image` keeps the same rule.

import gantry/internal/ffi_khepri.{Accepted, Stale}
import gantry/support
import gantry_core/layout.{Delete, Is, Keys, Put}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result

fn lane(prefix: String) -> layout.Key {
  [support.run_id(prefix)]
}

pub fn a_commit_applies_every_write_together_test() {
  support.boot_store()
  let root = lane("together")
  let a = [root, ["a"]] |> flatten
  let b = [root, ["b"]] |> flatten

  assert ffi_khepri.commit([Is(a, None)], [Put(a, "1"), Put(b, "2")])
    == Ok(Accepted)
  assert ffi_khepri.get(a) == Ok(Some("1"))
  assert ffi_khepri.get(b) == Ok(Some("2"))
  assert ffi_khepri.many([a, b, [root, ["c"]] |> flatten])
    == Ok([Some("1"), Some("2"), None])
}

pub fn a_stale_expectation_applies_nothing_test() {
  support.boot_store()
  let root = lane("stale")
  let a = [root, ["a"]] |> flatten
  let b = [root, ["b"]] |> flatten
  let assert Ok(Accepted) = ffi_khepri.commit([], [Put(a, "1")])

  // The plan read `a` as absent, so neither of its writes may land.
  assert ffi_khepri.commit([Is(a, None)], [Put(b, "2"), Put(a, "3")])
    == Ok(Stale)
  assert ffi_khepri.get(a) == Ok(Some("1"))
  assert ffi_khepri.get(b) == Ok(None)
}

pub fn a_listing_expectation_compares_the_keys_below_a_prefix_test() {
  support.boot_store()
  let root = lane("listing")
  let first = [root, ["x"]] |> flatten
  let second = [root, ["y"]] |> flatten
  let assert Ok(Accepted) =
    ffi_khepri.commit([], [Put(first, "1"), Put(second, "2")])

  assert ffi_khepri.commit([Keys(root, [first])], [Delete(first)]) == Ok(Stale)
  assert ffi_khepri.commit([Keys(root, [first, second])], [Delete(first)])
    == Ok(Accepted)
  let assert Ok(left) = ffi_khepri.list(root)
  assert left == [#(second, "2")]
}

pub fn a_plan_without_writes_is_confirmed_by_a_quorum_read_test() {
  support.boot_store()
  let root = lane("confirm")
  let a = [root, ["a"]] |> flatten
  let assert Ok(Accepted) = ffi_khepri.commit([], [Put(a, "1")])

  assert ffi_khepri.commit([Is(a, Some("1"))], []) == Ok(Accepted)
  assert ffi_khepri.commit([Is(a, Some("0"))], []) == Ok(Stale)
  assert ffi_khepri.commit([Is(a, None)], []) == Ok(Stale)
  assert ffi_khepri.commit([Keys(root, [a])], []) == Ok(Accepted)
  assert ffi_khepri.commit([Keys(root, [])], []) == Ok(Stale)
}

pub fn the_lock_makes_a_read_modify_write_commit_each_time_test() {
  support.boot_store()
  let key = [support.run_id("counter"), "n"]

  // Eight processes each read the counter, pause, and commit the next value
  // against what they read. The lock orders them, so none loses the race.
  let results = process.new_subject()
  list.each(numbers(8), fn(_) {
    process.spawn(fn() {
      let outcome =
        ffi_khepri.gated("claiming", fn() {
          let assert Ok(seen) = ffi_khepri.get(key)
          process.sleep(5)
          let next = case seen {
            Some(text) -> int.to_string(result.unwrap(int.parse(text), 0) + 1)
            None -> "1"
          }
          ffi_khepri.commit([Is(key, seen)], [Put(key, next)])
        })
      process.send(results, outcome)
    })
  })
  let outcomes =
    list.map(numbers(8), fn(_) {
      let assert Ok(outcome) = process.receive(results, 10_000)
      outcome
    })
  assert list.all(outcomes, fn(outcome) { outcome == Ok(Accepted) })
  assert ffi_khepri.get(key) == Ok(Some("8"))
}

fn numbers(count: Int) -> List(Int) {
  list.index_map(list.repeat(0, count), fn(_, index) { index })
}

fn flatten(parts: List(layout.Key)) -> layout.Key {
  case parts {
    [] -> []
    [first, ..rest] -> append(first, flatten(rest))
  }
}

fn append(first: layout.Key, rest: layout.Key) -> layout.Key {
  case first {
    [] -> rest
    [head, ..tail] -> [head, ..append(tail, rest)]
  }
}
