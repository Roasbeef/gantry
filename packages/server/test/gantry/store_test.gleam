import gantry/store.{Absent, Bootstrap, Join, Names, Reopen}
import gantry_core/layout
import gantry_core/protocol
import gleam/json
import gleam/option.{None, Some}
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

pub fn a_store_without_the_layout_imports_test() {
  assert store.upgrade(None, None) == Ok(store.Import)
  assert store.upgrade(None, Some("{\"serial\":3,\"runs\":[]}"))
    == Ok(store.Import)
}

pub fn a_store_with_the_layout_is_current_test() {
  assert store.upgrade(Some(layout.format_value), None) == Ok(store.Current)
  assert store.upgrade(Some(layout.format_value), Some(store.sealed_snapshot))
    == Ok(store.Current)
}

pub fn an_imported_snapshot_left_unsealed_is_sealed_test() {
  assert store.upgrade(Some(layout.format_value), Some("{\"serial\":3}"))
    == Ok(store.Seal)
}

pub fn an_unknown_format_refuses_to_start_by_name_test() {
  assert store.upgrade(Some("indexed-v2"), None)
    == Error("unknown queue format indexed-v2")
}

pub fn a_sealed_snapshot_without_its_layout_refuses_to_start_test() {
  let assert Error(_) = store.upgrade(None, Some(store.sealed_snapshot))
}

pub fn the_sealed_snapshot_is_not_a_queue_an_earlier_release_reads_test() {
  let assert Error(_) =
    json.parse(store.sealed_snapshot, protocol.state_decoder())
}
