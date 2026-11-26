import gantry/worker/docker
import gantry_core/sandbox
import gleam/list

fn with(
  settings: List(#(String, String)),
) -> fn(String) -> Result(String, Nil) {
  fn(key) { list.key_find(settings, key) }
}

fn flags(settings: List(#(String, String))) -> List(String) {
  let assert Ok(limits) = docker.limits_from(with(settings))
  let assert Ok(flags) = docker.action_flags(limits, sandbox.Strict)
  flags
}

pub fn defaults_let_a_beam_build_start_on_a_many_core_host_test() {
  let flags = flags([])
  assert list.contains(flags, "--pids-limit=4096")
  assert list.contains(flags, "--ulimit=nofile=65536:65536")
  assert list.contains(flags, "/tmp:rw,nosuid,nodev,size=1024m,mode=1777")
  assert list.contains(flags, "/var/tmp:rw,nosuid,nodev,size=1024m,mode=1777")
  assert list.contains(flags, "--memory=768m")
  assert list.contains(flags, "--cpus=2")
}

pub fn settings_override_the_defaults_test() {
  let flags =
    flags([
      #("GANTRY_WORKER_PIDS", "512"),
      #("GANTRY_WORKER_NOFILE", "2048"),
      #("GANTRY_WORKER_TMP_MIB", "64"),
    ])
  assert list.contains(flags, "--pids-limit=512")
  assert list.contains(flags, "--ulimit=nofile=2048:2048")
  assert list.contains(flags, "/tmp:rw,nosuid,nodev,size=64m,mode=1777")
  assert list.contains(flags, "/var/tmp:rw,nosuid,nodev,size=64m,mode=1777")
}

pub fn the_sandbox_keeps_its_fixed_restrictions_test() {
  let flags = flags([])
  assert list.contains(flags, "--network=none")
  assert list.contains(flags, "--cap-drop=ALL")
  assert list.contains(flags, "--read-only")
  assert list.contains(flags, "--security-opt=no-new-privileges")
}

pub fn pids_must_stay_inside_their_bounds_test() {
  assert docker.limits_from(with([#("GANTRY_WORKER_PIDS", "63")]))
    == Error("GANTRY_WORKER_PIDS must be between 64 and 1048576")
  assert docker.limits_from(with([#("GANTRY_WORKER_PIDS", "1048577")]))
    == Error("GANTRY_WORKER_PIDS must be between 64 and 1048576")
}

pub fn nofile_must_stay_inside_its_bounds_test() {
  assert docker.limits_from(with([#("GANTRY_WORKER_NOFILE", "255")]))
    == Error("GANTRY_WORKER_NOFILE must be between 256 and 1048576")
}

pub fn tmp_size_must_stay_inside_its_bounds_test() {
  assert docker.limits_from(with([#("GANTRY_WORKER_TMP_MIB", "15")]))
    == Error("GANTRY_WORKER_TMP_MIB must be between 16 and 65536")
  assert docker.limits_from(with([#("GANTRY_WORKER_TMP_MIB", "65537")]))
    == Error("GANTRY_WORKER_TMP_MIB must be between 16 and 65536")
}

pub fn non_numeric_settings_are_rejected_test() {
  assert docker.limits_from(with([#("GANTRY_WORKER_PIDS", "lots")]))
    == Error("GANTRY_WORKER_PIDS must be between 64 and 1048576")
  assert docker.limits_from(with([#("GANTRY_WORKER_NOFILE", "1e5")]))
    == Error("GANTRY_WORKER_NOFILE must be between 256 and 1048576")
}

pub fn the_original_settings_keep_their_bounds_test() {
  assert docker.limits_from(with([#("GANTRY_WORKER_CPUS", "0")]))
    == Error("GANTRY_WORKER_CPUS must be between 1 and 1024")
}
