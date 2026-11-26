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
////
//// ## History
////
//// `events` and `samples` are the recent past: each lease a controller
//// granted, each result it accepted, and the ready work it counted per pool
//// each time the snapshot was read. `since` is the oldest second the history
//// covers. Before it the page knows nothing, which is different from idle.
//// The types do not say where the history came from: today it is the
//// controller's memory, lost on restart, and a later change can fill the
//// same types from durable step times without changing the page.
////
//// `ready` is the one statement of which pending actions a poll could lease
//// now. The controller counts samples with it and the dashboard colours
//// cells with it, and it mirrors the claim rule in `queue`.

import gantry_core/protocol
import gantry_core/queue
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string

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

/// How an accepted result ended.
pub type Outcome {
  Succeeded

  Rejected
}

/// One thing a controller saw happen to a lease.
pub type Event {
  /// The controller granted lease `serial` on `action` of `run` to `worker`
  /// at `at`, to lapse at `until`.
  Granted(
    serial: Int,
    run: String,
    action: String,
    worker: String,
    pool: String,
    at: Int,
    until: Int,
  )

  /// The controller accepted the result for lease `serial` at `at`.
  Settled(serial: Int, outcome: Outcome, at: Int)
}

/// The ready actions in each pool at one moment.
pub type Sample {
  Sample(at: Int, ready: List(#(String, Int)))
}

/// The dashboard's view of one controller.
pub type Fleet {
  Fleet(
    now: Int,
    since: Int,
    slots: List(Slot),
    runs: List(queue.Run),
    proofs: Int,
    events: List(Event),
    samples: List(Sample),
  )
}

/// Encode a snapshot. Each run carries its derived phase, as status output
/// does.
///
/// ## Examples
///
/// ```gleam
/// // fleet.encode(fleet.Fleet(0, 0, [], [], 0, [], []))
/// ```
pub fn encode(value: Fleet) -> json.Json {
  json.object([
    #("now", json.int(value.now)),
    #("since", json.int(value.since)),
    #("slots", json.array(value.slots, encode_slot)),
    #("runs", json.array(value.runs, protocol.encode_run)),
    #("proofs", json.int(value.proofs)),
    #("events", json.array(value.events, encode_event)),
    #("samples", json.array(value.samples, encode_sample)),
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
  use since <- decode.field("since", natural())
  use events <- decode.field("events", decode.list(event_decoder()))
  use samples <- decode.field("samples", decode.list(sample_decoder()))
  decode.success(Fleet(now, since, slots, runs, proofs, events, samples))
}

/// The pending actions of a run that a poll in their pool could lease now:
/// the run is a build or a queued candidate that has not failed, and every
/// action each one depends on or runs after has passed or been reused. This
/// is the claim rule of `queue.claim`, stated once for readers.
///
/// ## Examples
///
/// ```gleam
/// // fleet.ready(run)
/// ```
pub fn ready(run: queue.Run) -> List(queue.Work) {
  let done =
    list.filter_map(run.work, fn(work) {
      case work.step {
        queue.Passed(_) | queue.Reused(_) -> Ok(work.task.action.name)
        queue.Pending(_)
        | queue.Active(_)
        | queue.Failed(_, _)
        | queue.Skipped -> Error(Nil)
      }
    })
    |> set.from_list

  // Only a servable run offers work, and only pending work whose
  // prerequisites all hold results.
  case servable(run) {
    False -> []
    True ->
      list.filter(run.work, fn(work) {
        let action = work.task.action

        // Pending work is ready when its prerequisites hold results.
        case work.step {
          queue.Pending(_) ->
            list.all(
              list.append(action.dependencies, action.after),
              set.contains(done, _),
            )
          queue.Active(_)
          | queue.Passed(_)
          | queue.Reused(_)
          | queue.Failed(_, _)
          | queue.Skipped -> False
        }
      })
  }
}

/// Count the ready actions of every run by pool, in pool name order.
///
/// ## Examples
///
/// ```gleam
/// fleet.ready_by_pool([]) == []
/// ```
pub fn ready_by_pool(runs: List(queue.Run)) -> List(#(String, Int)) {
  runs
  |> list.flat_map(ready)
  |> list.map(fn(work) { work.task.pool })
  |> list.sort(string.compare)
  |> list.chunk(fn(pool) { pool })
  |> list.map(fn(group) {
    case group {
      [pool, ..] -> #(pool, list.length(group))
      [] -> #("", 0)
    }
  })
}

/// Whether the queue leases this run's pending actions: a build or queued
/// candidate that has not failed.
fn servable(run: queue.Run) -> Bool {
  case run.submission, queue.phase(run) {
    queue.Build, queue.PhaseFailed | queue.Queued(_), queue.PhaseFailed -> False
    queue.Build, _ | queue.Queued(_), _ -> True
    queue.Waiting(_, _), _
    | queue.Landing(_), _
    | queue.Landed(_), _
    | queue.Blocked(_, _), _
    | queue.Unprepared(_, _, _), _
    -> False
  }
}

/// Encode one event under its kind tag.
fn encode_event(value: Event) -> json.Json {
  // Each event kind carries its own fields under one tag.
  case value {
    Granted(serial, run, action, worker, pool, at, until) ->
      json.object([
        #("kind", json.string("granted")),
        #("serial", json.int(serial)),
        #("run", json.string(run)),
        #("action", json.string(action)),
        #("worker", json.string(worker)),
        #("pool", json.string(pool)),
        #("at", json.int(at)),
        #("until", json.int(until)),
      ])
    Settled(serial, outcome, at) ->
      json.object([
        #("kind", json.string("settled")),
        #("serial", json.int(serial)),
        #(
          "outcome",
          json.string(case outcome {
            Succeeded -> "succeeded"
            Rejected -> "rejected"
          }),
        ),
        #("at", json.int(at)),
      ])
  }
}

/// Decode one event, refusing an unknown tag or a negative serial or time.
fn event_decoder() -> decode.Decoder(Event) {
  use kind <- decode.field("kind", decode.string)

  // The tag decides which fields must follow.
  case kind {
    "granted" -> {
      use serial <- decode.field("serial", natural())
      use run <- decode.field("run", decode.string)
      use action <- decode.field("action", decode.string)
      use worker <- decode.field("worker", decode.string)
      use pool <- decode.field("pool", decode.string)
      use at <- decode.field("at", natural())
      use until <- decode.field("until", natural())
      decode.success(Granted(serial, run, action, worker, pool, at, until))
    }
    "settled" -> {
      use serial <- decode.field("serial", natural())
      use outcome <- decode.field("outcome", outcome_decoder())
      use at <- decode.field("at", natural())
      decode.success(Settled(serial, outcome, at))
    }
    _ -> decode.failure(Settled(0, Rejected, 0), "known event tag")
  }
}

/// Decode a result's outcome word.
fn outcome_decoder() -> decode.Decoder(Outcome) {
  use word <- decode.then(decode.string)

  // Only the two outcomes a controller records are accepted.
  case word {
    "succeeded" -> decode.success(Succeeded)
    "rejected" -> decode.success(Rejected)
    _ -> decode.failure(Rejected, "known outcome")
  }
}

/// Encode one sample as its time and per-pool counts.
fn encode_sample(value: Sample) -> json.Json {
  json.object([
    #("at", json.int(value.at)),
    #(
      "ready",
      json.array(value.ready, fn(pair) {
        json.object([
          #("pool", json.string(pair.0)),
          #("count", json.int(pair.1)),
        ])
      }),
    ),
  ])
}

/// Decode one sample, refusing a negative time or count.
fn sample_decoder() -> decode.Decoder(Sample) {
  use at <- decode.field("at", natural())
  use ready <- decode.field(
    "ready",
    decode.list({
      use pool <- decode.field("pool", decode.string)
      use count <- decode.field("count", natural())
      decode.success(#(pool, count))
    }),
  )
  decode.success(Sample(at, ready))
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
