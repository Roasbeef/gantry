//// The reference store for the indexed layout: a dictionary of keys to
//// values with the commit rule a real store must keep. A commit applies a
//// plan only if every expectation holds, and then applies all of its writes
//// in order. The simulations run the layout against this store, and a real
//// store is checked against it.
////
//// ## Invariants
////
//// A refused commit leaves the image unchanged. An accepted commit applies
//// every write. Reading never changes the image.

import gantry_core/layout.{type Key, type Plan, type Reader}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/result
import gleam/string

/// A store image.
pub opaque type Image {
  Image(entries: Dict(Key, String))
}

/// An image with no keys.
///
/// ## Examples
///
/// ```gleam
/// image.keys(image.empty()) == []
/// ```
pub fn empty() -> Image {
  Image(dict.new())
}

/// Every key in the image, in path order.
///
/// ## Examples
///
/// ```gleam
/// image.keys(image.empty()) == []
/// ```
pub fn keys(image: Image) -> List(Key) {
  dict.keys(image.entries) |> list.sort(compare_keys)
}

/// The value of one key, or `Error(Nil)` when it is absent.
///
/// ## Examples
///
/// ```gleam
/// image.get(image.empty(), ["run"]) == Error(Nil)
/// ```
pub fn get(image: Image, key: Key) -> Result(String, Nil) {
  dict.get(image.entries, key)
}

/// A reader over the image.
///
/// ## Examples
///
/// ```gleam
/// // image.reader(image.empty())
/// ```
pub fn reader(image: Image) -> Reader {
  layout.Reader(
    get: fn(key) { Ok(option_of(get(image, key))) },
    many: fn(wanted) {
      Ok(list.map(wanted, fn(key) { option_of(get(image, key)) }))
    },
    list: fn(prefix) { Ok(below(image, prefix)) },
  )
}

/// Apply a plan if every expectation still holds, or return `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// // image.commit(image.empty(), plan)
/// ```
pub fn commit(image: Image, plan: Plan(a)) -> Result(Image, Nil) {
  use Nil <- result.map(check(image, layout.expects(plan)))
  apply(image, layout.writes(plan))
}

/// Apply writes without checking anything, as an import does.
///
/// ## Examples
///
/// ```gleam
/// image.apply(image.empty(), []) == image.empty()
/// ```
pub fn apply(image: Image, writes: List(layout.Write)) -> Image {
  list.fold(writes, image, fn(current, write) {
    case write {
      layout.Put(key, value) -> Image(dict.insert(current.entries, key, value))
      layout.Delete(key) -> Image(dict.delete(current.entries, key))
    }
  })
}

/// Whether every expectation holds in the image.
fn check(image: Image, expects: List(layout.Expect)) -> Result(Nil, Nil) {
  list.try_each(expects, fn(expect) {
    use <- bool.guard(!holds(image, expect), Error(Nil))
    Ok(Nil)
  })
}

/// Whether one expectation holds: a key has the value it was read with, or a
/// prefix holds exactly the keys it was listed with.
fn holds(image: Image, expect: layout.Expect) -> Bool {
  // An exact value is compared directly. A listing compares sorted keys.
  case expect {
    layout.Is(key, value) -> option_of(get(image, key)) == value
    layout.Keys(prefix, wanted) ->
      list.sort(
        list.map(below(image, prefix), fn(pair) { pair.0 }),
        compare_keys,
      )
      == list.sort(wanted, compare_keys)
  }
}

/// Every key strictly below a prefix with its value.
fn below(image: Image, prefix: Key) -> List(#(Key, String)) {
  dict.to_list(image.entries)
  |> list.filter(fn(pair) { starts_with(pair.0, prefix) && pair.0 != prefix })
}

/// Whether a key begins with every component of a prefix.
fn starts_with(key: Key, prefix: Key) -> Bool {
  // Walk both together, so no length is computed.
  case key, prefix {
    _, [] -> True
    [], [_, ..] -> False
    [head, ..rest], [wanted, ..others] ->
      head == wanted && starts_with(rest, others)
  }
}

fn option_of(value: Result(String, Nil)) -> Option(String) {
  option.from_result(value)
}

fn compare_keys(a: Key, b: Key) -> order.Order {
  string.compare(string.join(a, "/"), string.join(b, "/"))
}
