//// A repository without a sandbox profile keeps today's container flags
//// exactly, and the wider profile only appends what the host experiment
//// showed a nested `bwrap` needs.

import gantry/worker/controllers
import gantry/worker/docker
import gantry_core/queue
import gantry_core/sandbox
import gleam/list
import gleam/string
import simplifile
import worker_fixture

fn with(
  settings: List(#(String, String)),
) -> fn(String) -> Result(String, Nil) {
  fn(key) { list.key_find(settings, key) }
}

fn limits(settings: List(#(String, String))) -> docker.Limits {
  let assert Ok(limits) = docker.limits_from(with(settings))
  limits
}

const seccomp = [#("GANTRY_WORKER_USERNS_SECCOMP", "/etc/gantry/userns.json")]

/// The strict flags every action receives, whatever the worker's profiles.
const strict = [
  "--pull=never", "--network=none", "--cap-drop=ALL", "--read-only",
  "--user=65534:65534", "--security-opt=no-new-privileges", "--log-driver=none",
  "--pids-limit=4096", "--ulimit=nofile=65536:65536", "--memory=768m",
  "--cpus=2", "--tmpfs", "/tmp:rw,nosuid,nodev,size=1024m,mode=1777", "--tmpfs",
  "/var/tmp:rw,nosuid,nodev,size=1024m,mode=1777",
]

pub fn a_strict_action_keeps_todays_flags_exactly_test() {
  // A userns-capable worker still runs a strict task with the strict flags.
  list.each([[], seccomp], fn(settings) {
    assert docker.action_flags(limits(settings), sandbox.Strict) == Ok(strict)
  })
}

pub fn userns_only_appends_to_the_strict_flags_test() {
  let assert Ok(flags) = docker.action_flags(limits(seccomp), sandbox.Userns)
  assert flags
    == list.append(strict, [
      "--security-opt=seccomp=/etc/gantry/userns.json",
      "--security-opt=systempaths=unconfined",
      "--security-opt=apparmor=unconfined",
    ])
  // Everything else about the container stays as narrow as before.
  assert !list.any(flags, fn(flag) { string.starts_with(flag, "--cap-add") })
  assert !list.contains(flags, "--privileged")
}

pub fn a_worker_without_the_profile_file_rejects_userns_test() {
  let assert Error(docker.Rejected(reason)) =
    docker.action_flags(limits([]), sandbox.Userns)
  assert string.contains(reason, "GANTRY_WORKER_USERNS_SECCOMP")
}

pub fn the_seccomp_path_must_be_absolute_test() {
  assert docker.limits_from(
      with([#("GANTRY_WORKER_USERNS_SECCOMP", "userns.json")]),
    )
    == Error("GANTRY_WORKER_USERNS_SECCOMP must be an absolute path")
}

pub fn preflight_requires_the_named_profile_file_test() {
  assert docker.check_sandboxes(limits([])) == Ok(Nil)
  let assert Error(_) =
    docker.check_sandboxes(
      limits([#("GANTRY_WORKER_USERNS_SECCOMP", "/nonexistent/userns.json")]),
    )

  // A file that exists but is not a seccomp profile is refused as well.
  let directory = worker_fixture.temp_directory()
  let bogus = directory <> "/bogus.json"
  let assert Ok(Nil) = simplifile.write(bogus, "{\"truncated\":")
  let assert Error(_) =
    docker.check_sandboxes(limits([#("GANTRY_WORKER_USERNS_SECCOMP", bogus)]))
  worker_fixture.remove(directory)
}

pub fn a_worker_without_the_profile_skips_the_host_trial_test() {
  // No Docker is needed: an unconfigured worker never runs the trial.
  assert docker.try_sandboxes(limits([])) == Ok(Nil)
}

pub fn the_shipped_profile_is_a_valid_seccomp_document_test() {
  let path = "priv/sandbox/userns-seccomp.json"
  assert docker.check_sandboxes(
      limits([#("GANTRY_WORKER_USERNS_SECCOMP", absolute(path))]),
    )
    == Ok(Nil)
}

pub fn execute_refuses_before_creating_anything_test() {
  let directory = worker_fixture.temp_directory()
  let assert Ok(network) = controllers.new("http://127.0.0.1:9", "token")
  let job = worker_fixture.assignment(1)
  let job =
    queue.Assignment(
      ..job,
      task: queue.Task(..job.task, sandbox: sandbox.Userns),
    )
  let assert Error(docker.Rejected(_)) =
    docker.execute(
      directory,
      "gantry-refused",
      job,
      limits([]),
      network,
      fn() { panic as "an unsupported profile must not start" },
      fn(_) { panic as "an unsupported profile must not spool" },
    )
  assert simplifile.is_directory(directory <> "/gantry-refused.staging")
    == Ok(False)
  worker_fixture.remove(directory)
}

fn absolute(path: String) -> String {
  let assert Ok(cwd) = simplifile.current_directory()
  cwd <> "/" <> path
}
