//// The fleet snapshot names every registered slot, with the latest poll this
//// controller served for it, and decodes with the shared codec.

import gantry/api
import gantry/blobs
import gantry/config
import gantry/internal/ffi_history
import gantry/internal/ffi_presence
import gantry/store
import gantry/support
import gantry_core/fleet
import gantry_core/graph
import gantry_core/queue
import gantry_core/sandbox
import gleam/json
import gleam/list
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

pub fn history_records_one_grant_per_lease_and_its_result_test() {
  support.boot_store()
  ffi_history.start(0)
  let worker = support.run_id("slot")
  let pool = support.run_id("pool")
  let id = support.run_id("hist")
  let remote = support.remote()
  let #(cfg, _) =
    support.config_for(
      remote,
      support.run_id("repo"),
      queue.Retention(200, 1000),
    )
  let action = graph.Action("only", ["true"], [], [], [], [], 30)
  let task =
    queue.Task(action, "source", id <> "-recipe", pool, "image", sandbox.Strict)
  let assert Ok(_) =
    store.admit(id, "repo", "rev", "check", queue.Build, [task])
  let poll =
    json.object([#("worker", json.string(worker)), #("pool", json.string(pool))])
    |> json.to_string
  let assert Ok(Some(_)) = api.claim(worker, poll)
  // A replayed poll returns the same lease and records nothing new.
  let assert Ok(Some(_)) = api.claim(worker, poll)

  let assert Ok(log) = blobs.put(cfg.blobs, <<"failed":utf8>>)
  let assert Ok(Some(run)) = store.find(id)
  let assert [queue.Work(_, queue.Active(lease))] = run.work
  let serial = queue.lease_serial(lease)
  let report =
    json.object([
      #("run", json.string(id)),
      #("action", json.string("only")),
      #("worker", json.string(worker)),
      #("serial", json.int(serial)),
      #(
        "completion",
        json.object([
          #("kind", json.string("rejected")),
          #("reason", json.string("exit 1")),
          #("log", json.string(log)),
        ]),
      ),
    ])
    |> json.to_string
  let assert Ok(_) = api.finish(cfg, worker, report)

  let assert Ok(snapshot) = api.fleet(cfg)
  let assert Ok(decoded) = json.parse(json.to_string(snapshot), fleet.decoder())
  let mine =
    list.filter(decoded.events, fn(event) {
      case event {
        fleet.Granted(serial: s, ..) | fleet.Settled(serial: s, ..) ->
          s == serial
      }
    })
  let assert [
    fleet.Granted(_, run_id, "only", w, p, at, until),
    fleet.Settled(_, fleet.Rejected, done),
  ] = mine
  assert run_id == id
  assert w == worker
  assert p == pool
  assert until == queue.lease_until(lease)
  assert at <= done
  assert decoded.since <= decoded.now
  assert decoded.samples != []
}
