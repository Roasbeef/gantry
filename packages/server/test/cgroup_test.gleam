//// The per-attempt cgroup for the userns profile: its setting is checked,
//// its flags place the container inside it, and it carries the slot's
//// limits while handing the action only what it needs to divide them.
//// The decisions are pure and tested here. The effects need a delegated
//// cgroup v2 subtree, which the worker's startup trial and the live gate
//// exercise.

import gantry/worker/cgroup
import gantry/worker/docker
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn with(
  settings: List(#(String, String)),
) -> fn(String) -> Result(String, Nil) {
  fn(key) { list.key_find(settings, key) }
}

const seccomp = #("GANTRY_WORKER_USERNS_SECCOMP", "/etc/gantry/userns.json")

const base =
  "/sys/fs/cgroup/user.slice/user-1002.slice/user@1002.service/gantry-01"

pub fn an_unset_base_means_no_attempt_cgroup_test() {
  assert cgroup.from_lookup(with([])) == Ok(None)
  assert cgroup.from_lookup(with([#("GANTRY_WORKER_USERNS_CGROUP", "")]))
    == Ok(None)
}

pub fn a_base_must_be_a_plain_path_below_the_cgroup_mount_test() {
  let assert Ok(Some(found)) =
    cgroup.from_lookup(with([#("GANTRY_WORKER_USERNS_CGROUP", base)]))
  assert cgroup.path(found) == base

  // A comma or an `=` would end the Docker --mount option the path goes in.
  list.each(
    [
      "gantry-01", "/tmp/gantry", "/sys/fs/cgroup", "/sys/fs/cgroup/",
      "/sys/fs/cgroup/a/../b", "/sys/fs/cgroup/a,readonly=false",
      "/sys/fs/cgroup/a b", "/sys/fs/cgroup/a=b", "/sys/fs/cgroup/a/",
    ],
    fn(path) {
      let assert Error(_) =
        cgroup.from_lookup(with([#("GANTRY_WORKER_USERNS_CGROUP", path)]))
    },
  )
}

pub fn a_base_needs_the_userns_seccomp_profile_test() {
  assert docker.limits_from(with([#("GANTRY_WORKER_USERNS_CGROUP", base)]))
    == Error("GANTRY_WORKER_USERNS_CGROUP needs GANTRY_WORKER_USERNS_SECCOMP")
  let assert Ok(_) =
    docker.limits_from(with([seccomp, #("GANTRY_WORKER_USERNS_CGROUP", base)]))
}

pub fn the_flags_place_the_container_inside_its_attempt_cgroup_test() {
  let attempt = base <> "/gantry-ab12"
  assert cgroup.flags(attempt)
    == [
      "--cgroup-parent=/user.slice/user-1002.slice/user@1002.service/gantry-01/gantry-ab12",
      "--cgroupns=host",
      "--mount",
      "type=bind,src=" <> attempt <> ",dst=" <> attempt,
      "--env",
      "GANTRY_CGROUP_BASE=" <> attempt,
      "--env",
      "LOOM_CGROUP_BASE=" <> attempt,
    ]
}

pub fn a_base_must_pass_on_memory_and_pids_and_hold_no_processes_test() {
  assert cgroup.check(["cpu", "io", "memory", "pids"], [])
    == Ok(["cpu", "memory", "pids"])
  assert cgroup.check(["memory", "pids"], []) == Ok(["memory", "pids"])
  let assert Error(missing) = cgroup.check(["cpu", "memory"], [])
  assert string.contains(missing, "pids")
  let assert Error(busy) = cgroup.check(["memory", "pids"], ["1234"])
  assert string.contains(busy, "holds processes")
}

pub fn an_attempt_carries_the_slots_limits_test() {
  let limits = cgroup.Limits(memory_mib: 768, pids: 4096, cpus: 12)
  assert cgroup.limit_files(limits, ["cpu", "memory", "pids"])
    == [
      #("memory.max", "805306368"),
      #("memory.swap.max", "805306368"),
      #("pids.max", "4096"),
      #("cpu.max", "1200000 100000"),
    ]

  // Without a delegated cpu controller there is no CPU quota to write.
  assert cgroup.limit_files(limits, ["memory", "pids"])
    == [
      #("memory.max", "805306368"),
      #("memory.swap.max", "805306368"),
      #("pids.max", "4096"),
    ]
}

pub fn the_remove_of_a_missing_attempt_is_a_no_op_test() {
  let assert Ok(Some(found)) =
    cgroup.from_lookup(with([#("GANTRY_WORKER_USERNS_CGROUP", base)]))
  assert cgroup.remove(found, "gantry-never-made") == Ok(Nil)
}
