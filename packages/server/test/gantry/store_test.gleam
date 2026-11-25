import gantry/store.{Absent, Bootstrap, Join, Names, Reopen}
import gleam/string

pub fn a_marker_naming_this_node_reopens_the_store_test() {
  assert store.opening(Names("a@host"), "a@host", "") == Ok(Reopen)

  // The seed is only consulted on a fresh disk.
  assert store.opening(Names("a@host"), "a@host", "b@host") == Ok(Reopen)
}

pub fn a_marker_naming_another_node_refuses_to_start_test() {
  let assert Error(_) = store.opening(Names("a@host"), "b@host", "")
}

pub fn a_fresh_disk_with_no_seed_bootstraps_test() {
  assert store.opening(Absent, "a@host", "") == Ok(Bootstrap)
}

pub fn a_seed_naming_this_node_bootstraps_test() {
  assert store.opening(Absent, "a@host", "a@host") == Ok(Bootstrap)
}

pub fn a_fresh_disk_with_a_remote_seed_joins_it_test() {
  assert store.opening(Absent, "b@host", "a@host") == Ok(Join("a@host"))
}

pub fn an_oversized_seed_is_refused_test() {
  let seed = string.repeat("a", 256) <> "@host"
  let assert Error(_) = store.opening(Absent, "b@host", seed)
  let longest = string.repeat("a", 255)
  assert store.opening(Absent, "b@host", longest) == Ok(Join(longest))
}
