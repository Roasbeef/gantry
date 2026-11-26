//// The fleet snapshot names every registered slot, with the latest poll this
//// controller served for it, and decodes with the shared codec.

import gantry/api
import gantry/config
import gantry/internal/ffi_presence
import gantry/support
import gantry_core/fleet
import gantry_core/queue
import gleam/json
import gleam/option.{None, Some}

pub fn a_poll_marks_its_slot_and_others_stay_unseen_test() {
  support.boot_store()
  ffi_presence.start()
  let polled = support.run_id("slot")
  let quiet = support.run_id("slot")
  let pool = support.run_id("pool")
  let remote = support.remote()
  let #(cfg, _) =
    support.config_for(
      remote,
      support.run_id("repo"),
      queue.Retention(200, 1000),
    )
  let cfg =
    config.Config(..cfg, workers: [
      config.Worker(polled, "", Some("box")),
      config.Worker(quiet, "", None),
    ])
  let body =
    json.object([#("worker", json.string(polled)), #("pool", json.string(pool))])
    |> json.to_string
  let assert Ok(None) = api.claim(polled, body)

  let assert Ok(snapshot) = api.fleet(cfg)
  let assert Ok(decoded) = json.parse(json.to_string(snapshot), fleet.decoder())
  let assert [first, second] = decoded.slots
  let assert fleet.Slot(worker, Some("box"), fleet.Polled(seen, at)) = first
  assert worker == polled
  assert seen == pool
  assert at <= decoded.now
  assert second == fleet.Slot(quiet, None, fleet.Unseen)
}
