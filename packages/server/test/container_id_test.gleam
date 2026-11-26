import gantry/worker/docker
import gleam/string

const id = "3db715fa5a5533e5997c992c36e629ab01781069c323510a9bebe306502ace9b"

pub fn a_bare_id_is_read_test() {
  assert docker.container_id(id <> "\n") == Ok(id)
}

pub fn a_platform_warning_before_the_id_is_skipped_test() {
  let output =
    "WARNING: The requested image's platform (linux/amd64) does not match "
    <> "the detected host platform (linux/arm64/v8) and no specific platform "
    <> "was requested\n"
    <> id
    <> "\n"
  assert docker.container_id(output) == Ok(id)
}

pub fn a_swap_accounting_warning_before_the_id_is_skipped_test() {
  let output =
    "WARNING: Your kernel does not support swap limit capabilities or the "
    <> "cgroup is not mounted. Memory limited without swap.\n"
    <> id
  assert docker.container_id(output) == Ok(id)
}

pub fn a_warning_alone_is_refused_test() {
  assert docker.container_id("WARNING: something\n") == Error(Nil)
}

pub fn empty_output_is_refused_test() {
  assert docker.container_id("") == Error(Nil)
}

pub fn a_short_or_uppercase_id_is_refused_test() {
  assert docker.container_id(string.slice(id, 0, 12)) == Error(Nil)
  assert docker.container_id(string.uppercase(id)) == Error(Nil)
}
