import envoy
import gantry/internal/ffi_host
import gleam/bit_array
import gleam/string

pub fn captures_output_and_status_test() {
  let assert Ok(ffi_host.Command(exit, bytes, capture)) =
    ffi_host.capture(
      "sh",
      ["-c", "printf out; printf err >&2; exit 3"],
      ffi_host.Inherit([]),
      ffi_host.Combined,
      1024,
      5000,
    )
  assert exit == ffi_host.Exited(3)
  assert capture == ffi_host.Complete
  assert bit_array.to_string(bytes) == Ok("outerr")
}

pub fn stdout_stream_drops_stderr_test() {
  let assert Ok(ffi_host.Command(_, bytes, _)) =
    ffi_host.capture(
      "sh",
      ["-c", "printf out; printf err >&2"],
      ffi_host.Inherit([]),
      ffi_host.Stdout,
      1024,
      5000,
    )
  assert bytes == <<"out":utf8>>
}

pub fn clips_to_the_byte_limit_test() {
  let assert Ok(ffi_host.Command(_, bytes, capture)) =
    ffi_host.capture(
      "sh",
      ["-c", "printf 0123456789"],
      ffi_host.Inherit([]),
      ffi_host.Combined,
      4,
      5000,
    )
  assert capture == ffi_host.Clipped
  assert bytes == <<"0123":utf8>>
}

pub fn clear_environment_hides_the_vm_environment_test() {
  envoy.set("GANTRY_RUNNER_PROBE", "leaked")
  let assert Ok(ffi_host.Command(_, bytes, _)) =
    ffi_host.capture(
      "sh",
      [
        "-c",
        "printf '%s|%s' \"${GANTRY_RUNNER_PROBE-unset}\" \"${KEPT-unset}\"",
      ],
      ffi_host.Clear(["KEPT=yes"]),
      ffi_host.Combined,
      1024,
      5000,
    )
  assert bit_array.to_string(bytes) == Ok("unset|yes")
}

pub fn inherit_environment_applies_overrides_test() {
  let assert Ok(#(0, text)) =
    ffi_host.run(
      "sh",
      ["-c", "printf %s \"$GANTRY_RUNNER_OVERRIDE\""],
      [#("GANTRY_RUNNER_OVERRIDE", "set")],
      5000,
    )
  assert text == "set"
}

pub fn deadline_kills_the_child_and_keeps_partial_output_test() {
  // The child would run for a minute. The runner must return near the deadline.
  let assert Ok(ffi_host.Command(exit, bytes, _)) =
    ffi_host.capture(
      "sh",
      ["-c", "printf started; exec sleep 60"],
      ffi_host.Inherit([]),
      ffi_host.Combined,
      1024,
      500,
    )
  assert exit == ffi_host.TimedOut
  let assert Ok(text) = bit_array.to_string(bytes)
  assert string.starts_with(text, "started")
}

pub fn missing_program_is_an_error_test() {
  assert ffi_host.capture(
      "gantry-no-such-tool",
      [],
      ffi_host.Inherit([]),
      ffi_host.Combined,
      1,
      100,
    )
    == Error("gantry-no-such-tool executable not found")
}
