//// The fleet snapshot is what the dashboard reads: every retained run, every
//// registered worker slot with what this controller last heard from it, and
//// the controller's clock. The controller encodes it and the dashboard
//// decodes it with the same module, so the two cannot disagree on a field.
////
//// A slot's pool and last poll are not durable. A controller learns them from
//// the claims it serves and forgets them on restart, so `Unseen` means "this
//// controller has not served a poll from the slot", never "the slot is idle".
//// The decoder refuses a negative clock, a negative proof count, a repeated
//// slot, and a repeated run, as the queue image's decoder does.

import gantry_core/protocol
import gantry_core/queue
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set

/// What one controller last heard from a slot.
pub type Presence {
  /// No poll from the slot has reached this controller since it started.
  Unseen

  /// The slot's latest poll named `pool` at Unix second `at`.
  Polled(pool: String, at: Int)
}

/// One registered worker slot. `host` is the operator's label from
/// `controller.toml`, when the entry has one.
pub type Slot {
  Slot(worker: String, host: Option(String), presence: Presence)
}

/// The dashboard's view of one controller.
pub type Fleet {
  Fleet(now: Int, slots: List(Slot), runs: List(queue.Run), proofs: Int)
}

/// Encode a snapshot. Each run carries its derived phase, as status output
/// does.
///
/// ## Examples
///
/// ```gleam
/// // fleet.encode(fleet.Fleet(0, [], [], 0))
/// ```
pub fn encode(value: Fleet) -> json.Json {
  json.object([
    #("now", json.int(value.now)),
    #("slots", json.array(value.slots, encode_slot)),
    #("runs", json.array(value.runs, protocol.encode_run)),
    #("proofs", json.int(value.proofs)),
  ])
}

/// Decode a snapshot totally. A run's `phase` is derived and ignored, so the
/// caller recomputes it with `queue.phase`.
///
/// ## Examples
///
/// ```gleam
/// // json.parse(body, fleet.decoder())
/// ```
pub fn decoder() -> decode.Decoder(Fleet) {
  use now <- decode.field("now", natural())
  use slots <- decode.field(
    "slots",
    unique(decode.list(slot_decoder()), fn(slot: Slot) { slot.worker }),
  )
  use runs <- decode.field(
    "runs",
    unique(decode.list(protocol.run_decoder()), fn(run: queue.Run) { run.id }),
  )
  use proofs <- decode.field("proofs", natural())
  decode.success(Fleet(now, slots, runs, proofs))
}

/// The Unix second a lease was granted. The core sets a lease's deadline once,
/// at grant, to the claim time plus the action's timeout plus the fixed
/// slack, and never renews it, so the grant time follows from the deadline.
///
/// ## Examples
///
/// ```gleam
/// // fleet.granted(lease, 900)
/// ```
pub fn granted(lease: queue.Lease, timeout: Int) -> Int {
  queue.lease_until(lease) - timeout - queue.lease_slack
}

/// Encode a slot as the object `slot_decoder` reads back, with an absent
/// host as `null` and the presence as a tagged object.
fn encode_slot(value: Slot) -> json.Json {
  // The host is `null` when the registry entry has no label.
  let host = case value.host {
    Some(host) -> json.string(host)
    None -> json.null()
  }

  // Only a polled slot carries a pool and a time.
  let presence = case value.presence {
    Unseen -> json.object([#("kind", json.string("unseen"))])
    Polled(pool, at) ->
      json.object([
        #("kind", json.string("polled")),
        #("pool", json.string(pool)),
        #("at", json.int(at)),
      ])
  }

  json.object([
    #("worker", json.string(value.worker)),
    #("host", host),
    #("presence", presence),
  ])
}

fn slot_decoder() -> decode.Decoder(Slot) {
  use worker <- decode.field("worker", decode.string)
  use host <- decode.field("host", decode.optional(decode.string))
  use presence <- decode.field("presence", presence_decoder())
  decode.success(Slot(worker, host, presence))
}

/// Decode the tagged presence object `encode_slot` writes, failing on an
/// unknown tag or a polled slot without its pool and time.
fn presence_decoder() -> decode.Decoder(Presence) {
  use kind <- decode.field("kind", decode.string)

  // Only a polled slot carries the pool and time of its latest poll.
  case kind {
    "unseen" -> decode.success(Unseen)
    "polled" -> {
      use pool <- decode.field("pool", decode.string)
      use at <- decode.field("at", natural())
      decode.success(Polled(pool, at))
    }
    _ -> decode.failure(Unseen, "known presence tag")
  }
}

/// Decode an integer that is not negative.
fn natural() -> decode.Decoder(Int) {
  use number <- decode.then(decode.int)

  // A clock or a count below zero was never produced by a controller.
  case number >= 0 {
    True -> decode.success(number)
    False -> decode.failure(0, "a non-negative integer")
  }
}

/// Decode a list and refuse a repeated key.
fn unique(
  decoder: decode.Decoder(List(a)),
  key: fn(a) -> String,
) -> decode.Decoder(List(a)) {
  use items <- decode.then(decoder)
  let keys = list.map(items, key)

  // A repeated key would make a slot or run ambiguous on the board.
  case set.size(set.from_list(keys)) == list.length(keys) {
    True -> decode.success(items)
    False -> decode.failure([], "a list without repeated names")
  }
}
