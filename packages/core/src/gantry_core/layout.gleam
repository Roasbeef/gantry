//// The indexed layout of the durable queue. Every run lives under its own
//// key, and a few small index entries derived from that run answer the
//// questions a controller asks: which run can a slot take, which leases
//// lapsed, which waiting run heads a lane, which runs can land, and which
//// finished runs retention may drop. An operation reads only the keys it
//// needs through a `Reader`, selects the runs it can affect, hands exactly
//// those runs to the transitions in `queue`, and returns a `Plan`. A plan
//// holds the keys the decision relied on, the keys to write, and the
//// receipt. The caller commits a plan atomically if every expectation still
//// holds, so a claim and its lease reservation commit together and a lost
//// race loses before any effect escapes.
////
//// ## Flow
////
//// An operation such as `admit`, `claim`, `finish`, `landings`, or `retain`
//// lists or fetches the keys it needs and decodes the runs it selected. It
//// builds a `queue.State` holding only those runs and applies the unchanged
//// transition. `run_writes` then compares each run before and after: a
//// changed run is written with the index entries `entries` derives from it,
//// and a dropped run is deleted with its entries. The index is therefore a
//// pure function of the runs, and `entries` is the only place that function
//// lives. `materialize` and `import_state` convert to and from a whole state.
////
//// ## Keys
////
//// | Key | Value | Purpose |
//// | --- | --- | --- |
//// | `format` | `indexed-v1` | Marks the layout and that the old snapshot was imported |
//// | `counter/serial`, `counter/seq`, `counter/proofs` | A counter | Next lease serial, enrollment number, proof number |
//// | `run/<id>` | `{seq, run}` | Lookup by identity |
//// | `ready/<pool>/<seq>` | The run's ID | Runs a slot in the pool can take now |
//// | `active/<seq>` | Earliest deadline and holders | Lapsed leases, and replays for a worker |
//// | `waiting/<repo>/<branch>/<seq>` | The run's ID | Heads of lanes awaiting preparation |
//// | `holds/<repo>/<branch>/<seq>` | The run's ID | The run that holds each lane |
//// | `landing/<seq>` | The run's ID | Runs `landings` can act on |
//// | `done/<seq>` | The run's ID | Finished runs, oldest first, for retention |
//// | `proof/<repo>/<recipe>` | Proofs with their numbers | Reuse by key |
//// | `proofs/<n>` | The proof's group | Oldest proofs, for retention |
////
//// A name inside a key is `x` followed by its hex, so no name can hold a
//// path separator, and a counter is zero padded, so keys sort in order.
////
//// ## Invariants
////
//// Index entries exist exactly when `entries` derives them from the stored
//// run. A plan's writes apply together or not at all. An expectation names
//// the bytes a decision read, so a plan committed after any of those keys
//// changed is refused. Listing a prefix is only used to find candidates. A
//// candidate is trusted only once its own key is expected.

import gantry_core/protocol
import gantry_core/queue.{type Run, type State}
import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string

/// A path in the store. Every component is a hex name or a padded counter.
pub type Key =
  List(String)

/// How the layout reads the store. A reader may be stale, because a commit
/// compares what the plan expected.
pub type Reader {
  Reader(
    /// One key's value, or `None` when it is absent.
    get: fn(Key) -> Result(Option(String), String),
    /// The values of several keys, in the order asked.
    many: fn(List(Key)) -> Result(List(Option(String)), String),
    /// Every key below a prefix with its value, in no particular order.
    list: fn(Key) -> Result(List(#(Key, String)), String),
  )
}

/// What a decision relied on.
pub type Expect {
  /// The key holds exactly this value, or is absent for `None`.
  Is(key: Key, value: Option(String))

  /// The keys below the prefix are exactly these.
  Keys(prefix: Key, keys: List(Key))
}

/// A change to one key.
pub type Write {
  Put(key: Key, value: String)
  Delete(key: Key)
}

/// A decision, the keys it relied on, and the writes that realize it.
pub opaque type Plan(a) {
  Plan(expects: List(Expect), writes: List(Write), receipt: a)
}

/// Why no plan was produced.
pub type Failure {
  /// The queue refused the transition. The text comes from the core.
  Refused(detail: String)

  /// The store could not be read.
  Unreadable(detail: String)

  /// The store held a record that does not decode or an index that points at
  /// nothing. This release did not write it.
  Corrupt(detail: String)
}

/// The expectations of a plan, which a commit must still find true.
pub fn expects(plan: Plan(a)) -> List(Expect) {
  plan.expects
}

/// The writes of a plan, applied in order.
pub fn writes(plan: Plan(a)) -> List(Write) {
  plan.writes
}

/// What the caller receives once the plan commits.
pub fn receipt(plan: Plan(a)) -> a {
  plan.receipt
}

/// The key of the layout marker.
pub fn format_key() -> Key {
  ["format"]
}

/// The marker's value.
pub const format_value = "indexed-v1"

/// How many ready runs one claim loads before it asks for more.
const window = 8

// ---------------------------------------------------------------------------
// Keys and entries
// ---------------------------------------------------------------------------

/// A name as one path component.
fn name(text: String) -> String {
  "x" <> bit_array.base16_encode(bit_array.from_string(text))
}

/// A counter as one path component that sorts in numeric order.
fn pad(number: Int) -> String {
  string.pad_start(int.to_string(number), 12, "0")
}

fn run_key(id: String) -> Key {
  ["run", name(id)]
}

fn counter_key(counter: String) -> Key {
  ["counter", counter]
}

fn lane_prefix(kind: String, repo: String, branch: String) -> Key {
  [kind, name(repo), name(branch)]
}

fn proof_group(repo: String, recipe: String) -> Key {
  ["proof", name(repo), name(recipe)]
}

/// The index entries one stored run owns, with their values. Every index
/// key is a pure function of the run and its enrollment number, so a write
/// that skips this function is the only way an index can disagree with a run.
///
/// ## Examples
///
/// ```gleam
/// // layout.entries(1, run)
/// ```
pub fn entries(seq: Int, run: Run) -> List(#(Key, String)) {
  list.flatten([
    ready_entries(seq, run),
    active_entries(seq, run),
    lane_entries(seq, run),
    queue_entries(seq, run),
  ])
}

/// One entry for each pool in which a slot could take an action of this run
/// now, so a claim lists only the runs that can give it work.
fn ready_entries(seq: Int, run: Run) -> List(#(Key, String)) {
  list.map(queue.ready_pools(run), fn(pool) {
    #(["ready", name(pool), pad(seq)], run.id)
  })
}

/// An entry while the run holds a lease, carrying its earliest deadline and
/// its workers, so a claim finds lapsed leases and replays without scanning.
fn active_entries(seq: Int, run: Run) -> List(#(Key, String)) {
  let leases = queue.leases(run)
  use <- bool.guard(leases == [], [])
  [#(["active", pad(seq)], active_value(run.id, leases))]
}

/// The waiting and holding entries of the run's lane. A waiting run is listed
/// under its branch until a lane frees. A queued run with live work or a
/// landing run holds the lane.
fn lane_entries(seq: Int, run: Run) -> List(#(Key, String)) {
  // Only a waiting run heads a lane that is awaiting its candidate.
  let waiting = case run.submission {
    queue.Waiting(branch, _) -> [
      #(
        list.append(lane_prefix("waiting", run.repo, branch), [pad(seq)]),
        run.id,
      ),
    ]
    queue.Build
    | queue.Queued(_)
    | queue.Landing(_)
    | queue.Landed(_)
    | queue.Blocked(_, _)
    | queue.Unprepared(_, _, _) -> []
  }

  // The queue decides which branch a run holds, if any.
  let holds = case queue.held_branch(run) {
    Ok(branch) -> [
      #(list.append(lane_prefix("holds", run.repo, branch), [pad(seq)]), run.id),
    ]
    Error(Nil) -> []
  }

  list.append(waiting, holds)
}

/// The landing and retention entries: runs `landings` can act on, and runs
/// that are finished, in enrollment order.
fn queue_entries(seq: Int, run: Run) -> List(#(Key, String)) {
  let landing =
    bool.guard(!queue.landable(run), [], fn() {
      [#(["landing", pad(seq)], run.id)]
    })
  let done =
    bool.guard(!queue.terminal(run), [], fn() {
      [#(["done", pad(seq)], run.id)]
    })
  list.append(landing, done)
}

/// The earliest deadline among a run's leases and the workers that hold them.
fn active_value(id: String, leases: List(queue.Lease)) -> String {
  let until =
    list.map(leases, queue.lease_until)
    |> list.reduce(int.min)
    |> result.unwrap(0)
  json.object([
    #("id", json.string(id)),
    #("until", json.int(until)),
    #(
      "workers",
      json.array(leases, fn(l) { json.string(queue.lease_worker(l)) }),
    ),
  ])
  |> json.to_string
}

type Active {
  Active(id: String, until: Int, workers: List(String))
}

fn active_decoder() -> decode.Decoder(Active) {
  use id <- decode.field("id", decode.string)
  use until <- decode.field("until", decode.int)
  use workers <- decode.field("workers", decode.list(decode.string))
  decode.success(Active(id, until, workers))
}

// ---------------------------------------------------------------------------
// Stored runs
// ---------------------------------------------------------------------------

/// A run read from its key, with the bytes a commit must find unchanged.
type Stored {
  Stored(seq: Int, run: Run, bytes: String)
}

fn stored_decoder() -> decode.Decoder(#(Int, Run)) {
  use seq <- decode.field("seq", decode.int)
  use run <- decode.field("run", protocol.run_decoder())
  decode.success(#(seq, run))
}

/// A run and its enrollment number as the bytes stored under its key.
fn encode_stored(seq: Int, run: Run) -> String {
  json.object([
    #("seq", json.int(seq)),
    #("run", protocol.encode_stored_run(run)),
  ])
  |> json.to_string
}

fn decode_stored(bytes: String) -> Result(Stored, Failure) {
  json.parse(bytes, stored_decoder())
  |> result.map(fn(pair) { Stored(pair.0, pair.1, bytes) })
  |> result.replace_error(Corrupt("invalid run record"))
}

/// Read the named runs. A run that is gone is skipped, and its absence is
/// expected, so a commit after it reappears is refused.
fn load(
  reader: Reader,
  ids: List(String),
) -> Result(#(List(Stored), List(Expect)), Failure) {
  let keys = list.map(list.unique(ids), run_key)
  use values <- result.try(fetch_many(reader, keys))
  use stored <- result.try(
    list.try_map(list.zip(keys, values), fn(pair) {
      option_result(pair.1, decode_stored)
    }),
  )
  let expects =
    list.zip(keys, values)
    |> list.map(fn(pair) { Is(pair.0, pair.1) })
  Ok(#(by_seq(list.filter_map(stored, option.to_result(_, Nil))), expects))
}

/// Apply a fallible step to a present value, keeping an absent one absent.
fn option_result(
  value: Option(a),
  step: fn(a) -> Result(b, Failure),
) -> Result(Option(b), Failure) {
  option.map(value, step)
  |> option.map(result.map(_, Some))
  |> option.unwrap(Ok(None))
}

fn by_seq(runs: List(Stored)) -> List(Stored) {
  list.sort(runs, fn(a, b) { int.compare(a.seq, b.seq) })
}

/// The state a transition runs on: only the runs an operation selected, with
/// the serial and the proofs it can look up.
fn state_of(
  runs: List(Stored),
  serial: Int,
  cache: List(queue.Remembered),
) -> State {
  queue.State(serial, list.map(runs, fn(stored) { stored.run }), cache)
}

// ---------------------------------------------------------------------------
// Reading helpers
// ---------------------------------------------------------------------------

fn fetch(reader: Reader, key: Key) -> Result(Option(String), Failure) {
  reader.get(key) |> result.map_error(Unreadable)
}

/// Read several keys in one call, skipping the call when there is nothing to
/// read.
fn fetch_many(
  reader: Reader,
  keys: List(Key),
) -> Result(List(Option(String)), Failure) {
  case keys {
    [] -> Ok([])
    _ -> reader.many(keys) |> result.map_error(Unreadable)
  }
}

/// Every key below a prefix with its value, in key order, which is
/// enrollment order because counters are padded.
fn children(
  reader: Reader,
  prefix: Key,
) -> Result(List(#(Key, String)), Failure) {
  use found <- result.map(reader.list(prefix) |> result.map_error(Unreadable))
  list.sort(found, fn(a, b) {
    string.compare(string.join(a.0, "/"), string.join(b.0, "/"))
  })
}

/// A counter's value and the text a commit must find, which is absent for
/// a counter nobody wrote.
fn counter(
  reader: Reader,
  key: Key,
) -> Result(#(Int, Option(String)), Failure) {
  use value <- result.try(fetch(reader, key))
  use number <- result.map(
    option_result(value, fn(text) {
      int.parse(text) |> result.replace_error(Corrupt("invalid counter"))
    }),
  )
  #(option.unwrap(number, 0), value)
}

/// The IDs that index entries name, in the order of their keys.
fn ids(found: List(#(Key, String))) -> List(String) {
  list.map(found, fn(pair) { pair.1 })
}

fn keys_of(found: List(#(Key, String))) -> List(Key) {
  list.map(found, fn(pair) { pair.0 })
}

// ---------------------------------------------------------------------------
// Proofs
// ---------------------------------------------------------------------------

/// A remembered proof and its number, newest highest.
type Numbered {
  Numbered(number: Int, remembered: queue.Remembered)
}

fn numbered_decoder() -> decode.Decoder(Numbered) {
  use number <- decode.field("n", decode.int)
  use remembered <- decode.field("proof", protocol.remembered_decoder())
  decode.success(Numbered(number, remembered))
}

/// The bytes of a proof group: its proofs with their numbers, newest first.
fn encode_group(group: List(Numbered)) -> String {
  json.array(group, fn(one) {
    json.object([
      #("n", json.int(one.number)),
      #("proof", protocol.encode_remembered(one.remembered)),
    ])
  })
  |> json.to_string
}

fn decode_group(bytes: String) -> Result(List(Numbered), Failure) {
  json.parse(bytes, decode.list(numbered_decoder()))
  |> result.replace_error(Corrupt("invalid proof record"))
}

/// A proof group read from the store, the value it had, and its key.
type Group {
  Group(key: Key, bytes: Option(String), proofs: List(Numbered))
}

/// Read the groups for a list of repository and recipe pairs.
fn load_groups(
  reader: Reader,
  wanted: List(#(String, String)),
) -> Result(#(List(Group), List(Expect)), Failure) {
  let wanted = list.unique(wanted)
  let keys = list.map(wanted, fn(pair) { proof_group(pair.0, pair.1) })
  use values <- result.try(fetch_many(reader, keys))
  use groups <- result.map(
    list.try_map(list.zip(keys, values), fn(pair) {
      case pair.1 {
        None -> Ok(Group(pair.0, None, []))
        Some(bytes) ->
          decode_group(bytes) |> result.map(Group(pair.0, Some(bytes), _))
      }
    }),
  )
  #(groups, list.map(groups, fn(group) { Is(group.key, group.bytes) }))
}

fn cache_of(groups: List(Group)) -> List(queue.Remembered) {
  list.flat_map(groups, fn(group) {
    list.map(group.proofs, fn(one) { one.remembered })
  })
}

/// The writes that turn the loaded proof groups into the ones a finished
/// transition left, numbering each new proof after `next`. Returns the
/// writes and the largest number used.
fn group_writes(
  groups: List(Group),
  cache: List(queue.Remembered),
  next: Int,
) -> #(List(Write), Int) {
  // Collect the new proofs of each group, newest first as the state has them.
  let wanted_by_key =
    list.fold(cache, dict.new(), fn(table, entry) {
      let key = proof_group(entry.repo, queue.proof_key(entry.proof).recipe)
      dict.insert(
        table,
        key,
        list.append(result.unwrap(dict.get(table, key), []), [entry]),
      )
    })
  let touched =
    list.map(groups, fn(group) { group.key })
    |> list.append(dict.keys(wanted_by_key))
    |> list.unique

  list.fold(touched, #([], next), fn(acc, key) {
    let old =
      list.find(groups, fn(group) { group.key == key })
      |> result.map(fn(group) { group.proofs })
      |> result.unwrap([])
    let wanted = result.unwrap(dict.get(wanted_by_key, key), [])
    let #(writes, used) = renumber(key, old, wanted, acc.1)
    #(list.append(acc.0, writes), used)
  })
}

/// The writes for one proof group: keep the number of a proof that survives,
/// number a new proof after `next`, and drop the order entries of proofs that
/// left the group. Returns the writes and the largest number used.
fn renumber(
  key: Key,
  old: List(Numbered),
  wanted: List(queue.Remembered),
  next: Int,
) -> #(List(Write), Int) {
  let #(numbered, used) =
    list.fold(wanted, #([], next), fn(inner, entry) {
      // A proof that was already stored keeps its number.
      case list.find(old, fn(one) { one.remembered == entry }) {
        Ok(one) -> #([one, ..inner.0], inner.1)
        Error(Nil) -> #([Numbered(inner.1 + 1, entry), ..inner.0], inner.1 + 1)
      }
    })
  let kept = list.reverse(numbered)
  let dropped = absent_from(old, kept)
  let fresh = absent_from(kept, old)

  let order_deletes =
    list.map(dropped, fn(one) { Delete(["proofs", pad(one.number)]) })
  let order_puts =
    list.map(fresh, fn(one) {
      Put(["proofs", pad(one.number)], group_pointer(one.remembered))
    })
  #(list.flatten([order_deletes, [store_group(key, kept)], order_puts]), used)
}

/// The write that stores a proof group, or removes it when no proof is left.
fn store_group(key: Key, proofs: List(Numbered)) -> Write {
  // A group with no proofs left is removed.
  case proofs {
    [] -> Delete(key)
    [_, ..] -> Put(key, encode_group(proofs))
  }
}

/// The proofs of `these` whose numbers `those` does not hold.
fn absent_from(these: List(Numbered), those: List(Numbered)) -> List(Numbered) {
  list.filter(these, fn(one) {
    !list.any(those, fn(other) { other.number == one.number })
  })
}

/// The group an order entry points at, as the repository and recipe names.
fn group_pointer(entry: queue.Remembered) -> String {
  json.array([entry.repo, queue.proof_key(entry.proof).recipe], json.string)
  |> json.to_string
}

/// Decode the repository and recipe names an order entry points at.
fn pointer_decoder() -> decode.Decoder(#(String, String)) {
  decode.list(decode.string)
  |> decode.then(fn(parts) {
    case parts {
      [repo, recipe] -> decode.success(#(repo, recipe))
      _ -> decode.failure(#("", ""), "a repository and a recipe")
    }
  })
}

// ---------------------------------------------------------------------------
// Turning a transition into writes
// ---------------------------------------------------------------------------

/// The writes that take the loaded runs to the runs a transition left,
/// plus the writes for runs that are new, numbered after `first`.
fn run_writes(
  loaded: List(Stored),
  after: List(Run),
  first: Int,
) -> List(Write) {
  let remaining = dict.from_list(list.map(after, fn(run) { #(run.id, run) }))
  let known = set.from_list(list.map(loaded, fn(stored) { stored.run.id }))
  let changed =
    list.flat_map(loaded, fn(stored) {
      case dict.get(remaining, stored.run.id) {
        Error(Nil) -> drop_writes(stored)
        Ok(run) if run == stored.run -> []
        Ok(run) -> replace_writes(stored, run)
      }
    })
  let fresh =
    list.filter(after, fn(run) { !set.contains(known, run.id) })
    |> list.index_map(fn(run, offset) { #(first + offset, run) })
    |> list.flat_map(fn(pair) { create_writes(pair.0, pair.1) })
  list.append(changed, fresh)
}

fn create_writes(seq: Int, run: Run) -> List(Write) {
  [
    Put(run_key(run.id), encode_stored(seq, run)),
    ..list.map(entries(seq, run), fn(pair) { Put(pair.0, pair.1) })
  ]
}

fn drop_writes(stored: Stored) -> List(Write) {
  [
    Delete(run_key(stored.run.id)),
    ..list.map(entries(stored.seq, stored.run), fn(pair) { Delete(pair.0) })
  ]
}

/// The writes for a run that changed: its new record, the index entries it
/// no longer owns deleted, and the ones it gained or changed written.
fn replace_writes(stored: Stored, run: Run) -> List(Write) {
  let old = dict.from_list(entries(stored.seq, stored.run))
  let new = dict.from_list(entries(stored.seq, run))
  let deletes =
    dict.keys(old)
    |> list.filter(fn(key) { !dict.has_key(new, key) })
    |> list.map(Delete)
  let puts =
    dict.to_list(new)
    |> list.filter(fn(pair) { dict.get(old, pair.0) != Ok(pair.1) })
    |> list.sort(fn(a, b) {
      string.compare(string.join(a.0, "/"), string.join(b.0, "/"))
    })
    |> list.map(fn(pair) { Put(pair.0, pair.1) })
  [
    Put(run_key(run.id), encode_stored(stored.seq, run)),
    ..list.append(deletes, puts)
  ]
}

fn counter_writes(key: Key, before: Int, after: Int) -> List(Write) {
  case after == before {
    True -> []
    False -> [Put(key, int.to_string(after))]
  }
}

/// A plan with the given expectations, writes, and receipt.
fn plan(
  expects: List(Expect),
  writes: List(Write),
  receipt: a,
) -> Result(Plan(a), Failure) {
  Ok(Plan(expects, writes, receipt))
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

/// Read one run. The plan writes nothing, so a commit only confirms the
/// run was current.
///
/// ## Examples
///
/// ```gleam
/// // layout.find(reader, "run-1")
/// ```
pub fn find(reader: Reader, id: String) -> Result(Plan(Option(Run)), Failure) {
  use #(found, expects) <- result.try(load(reader, [id]))
  plan(
    expects,
    [],
    option.from_result(list.first(found))
      |> option.map(fn(stored) { stored.run }),
  )
}

/// Admit a run exactly as `queue.admit` does, loading the run itself when it
/// exists and the lane when a prepared candidate must find it free.
///
/// ## Examples
///
/// ```gleam
/// // layout.admit(reader, "run-1", "owner/project", sha, "check", queue.Build, tasks)
/// ```
pub fn admit(
  reader: Reader,
  id: String,
  repo: String,
  revision: String,
  target: String,
  submission: queue.Submission,
  tasks: List(queue.Task),
) -> Result(Plan(Run), Failure) {
  use #(prior, expects) <- result.try(load(reader, [id]))

  // A retry finds its run, and a first request enrolls a new one.
  case prior {
    [stored, ..] ->
      queue.admit(
        state_of([stored], 0, []),
        id,
        repo,
        revision,
        target,
        submission,
        tasks,
      )
      |> result.map_error(Refused)
      |> result.try(fn(admitted) { plan(expects, [], admitted.1) })
    [] -> admit_new(reader, id, repo, revision, target, submission, tasks)
  }
}

/// Enroll a run that does not exist yet under the next enrollment number. A
/// prepared candidate also reads its lane, because it must find the lane free.
fn admit_new(
  reader: Reader,
  id: String,
  repo: String,
  revision: String,
  target: String,
  submission: queue.Submission,
  tasks: List(queue.Task),
) -> Result(Plan(Run), Failure) {
  use #(seq, seq_text) <- result.try(counter(reader, counter_key("seq")))
  use #(lane, lane_expects) <- result.try(admission_lane(
    reader,
    repo,
    submission,
  ))
  use #(next, run) <- result.try(
    queue.admit(
      state_of(lane, 0, []),
      id,
      repo,
      revision,
      target,
      submission,
      tasks,
    )
    |> result.map_error(Refused),
  )
  let writes =
    list.append(
      counter_writes(counter_key("seq"), seq, seq + 1),
      run_writes(lane, next.runs, seq + 1),
    )
  plan(
    [Is(counter_key("seq"), seq_text), Is(run_key(id), None), ..lane_expects],
    writes,
    run,
  )
}

/// The runs an admission must read: the lane of a prepared candidate, and
/// nothing for a build or a waiting group.
fn admission_lane(
  reader: Reader,
  repo: String,
  submission: queue.Submission,
) -> Result(#(List(Stored), List(Expect)), Failure) {
  // Only a candidate that is already prepared needs its lane.
  case submission {
    queue.Queued(candidate) ->
      lane_runs(reader, repo, queue.candidate_branch(candidate))
    queue.Build
    | queue.Waiting(_, _)
    | queue.Landing(_)
    | queue.Landed(_)
    | queue.Blocked(_, _)
    | queue.Unprepared(_, _, _) -> Ok(#([], []))
  }
}

/// The runs that hold or wait for one lane, with what a commit must find.
fn lane_runs(
  reader: Reader,
  repo: String,
  branch: String,
) -> Result(#(List(Stored), List(Expect)), Failure) {
  let held = lane_prefix("holds", repo, branch)
  let waiting = lane_prefix("waiting", repo, branch)
  use held_entries <- result.try(children(reader, held))
  use waiting_entries <- result.try(children(reader, waiting))
  use #(runs, run_expects) <- result.map(load(
    reader,
    list.append(ids(held_entries), ids(waiting_entries)),
  ))
  #(runs, [
    Keys(held, keys_of(held_entries)),
    Keys(waiting, keys_of(waiting_entries)),
    ..run_expects
  ])
}

/// Lease or reuse one action for a worker, expiring lapsed leases first. The
/// plan carries the lease serial it issued, so no other claim can have issued
/// the same one.
///
/// ## Examples
///
/// ```gleam
/// // layout.claim(reader, "worker-1", "linux", 1000)
/// ```
pub fn claim(
  reader: Reader,
  worker: String,
  pool: String,
  now: Int,
) -> Result(Plan(Option(queue.Assignment)), Failure) {
  use #(serial, serial_text) <- result.try(counter(
    reader,
    counter_key("serial"),
  ))
  use active <- result.try(children(reader, ["active"]))
  use leased <- result.try(
    list.try_map(active, fn(pair) {
      json.parse(pair.1, active_decoder())
      |> result.replace_error(Corrupt("invalid active entry"))
    }),
  )
  let involved =
    list.filter(leased, fn(entry) {
      now > entry.until || list.contains(entry.workers, worker)
    })
    |> list.map(fn(entry) { entry.id })
  let ready_prefix = ["ready", name(pool)]
  use ready <- result.try(children(reader, ready_prefix))
  let #(first, rest) = list.split(ids(ready), window)
  use #(loaded, run_expects) <- result.try(load(
    reader,
    list.append(involved, first),
  ))
  let scan =
    Scan(
      ask: Ask(worker, pool, now),
      serial: #(serial, serial_text),
      empty: ready == [],
      read: loaded,
      current: loaded,
      groups: [],
      rest: rest,
      expects: run_expects,
    )
  claim_from(reader, scan)
}

/// A poll's identity and time.
type Ask {
  Ask(worker: String, pool: String, now: Int)
}

/// A claim that reads further windows of the ready index while earlier
/// reuses leave it without a lease to give.
type Scan {
  Scan(
    ask: Ask,
    serial: #(Int, Option(String)),
    empty: Bool,
    read: List(Stored),
    current: List(Stored),
    groups: List(Group),
    rest: List(String),
    expects: List(Expect),
  )
}

/// Run the claim on the runs read so far. When it leases nothing while ready
/// runs remain unread, earlier reuses may have made them reachable, so read
/// the next window and run it again.
fn claim_from(
  reader: Reader,
  scan: Scan,
) -> Result(Plan(Option(queue.Assignment)), Failure) {
  // A reuse can unlock a successor, so look up every pending recipe.
  let wanted =
    list.flat_map(scan.current, fn(stored) {
      list.map(queue.unsettled_recipes(stored.run, scan.ask.pool), fn(recipe) {
        #(stored.run.repo, recipe)
      })
    })
    |> list.filter(fn(pair) {
      !list.any(scan.groups, fn(group) {
        group.key == proof_group(pair.0, pair.1)
      })
    })
  use #(fresh, group_expects) <- result.try(load_groups(reader, wanted))
  let groups = list.append(scan.groups, fresh)
  let expects = list.append(scan.expects, group_expects)
  let state = state_of(scan.current, { scan.serial.0 }, cache_of(groups))
  let #(next, assignment) =
    queue.claim(state, scan.ask.worker, scan.ask.pool, scan.ask.now)

  // Read the next window only when nothing leased and ready runs remain.
  case assignment, scan.rest {
    None, [_, ..] -> {
      let #(first, rest) = list.split(scan.rest, window)
      use #(more, more_expects) <- result.try(load(reader, first))
      claim_from(
        reader,
        Scan(
          ..scan,
          serial: #(next.serial, scan.serial.1),
          read: by_seq(list.append(scan.read, more)),
          current: by_seq(list.append(apply_runs(scan.current, next.runs), more)),
          groups: groups,
          rest: rest,
          expects: list.append(expects, more_expects),
        ),
      )
    }
    _, _ -> Ok(finish_claim(scan, next, assignment, expects))
  }
}

/// Turn the last state of a claim into its plan.
fn finish_claim(
  scan: Scan,
  next: State,
  assignment: Option(queue.Assignment),
  expects: List(Expect),
) -> Plan(Option(queue.Assignment)) {
  let before = serial_of(scan.serial.1)
  let expects =
    list.flatten([
      expects,
      case scan.empty, assignment {
        True, None -> [Keys(["ready", name(scan.ask.pool)], [])]
        _, _ -> []
      },
      case next.serial == before {
        True -> []
        False -> [Is(counter_key("serial"), scan.serial.1)]
      },
    ])
  let writes =
    list.append(
      counter_writes(counter_key("serial"), before, next.serial),
      run_writes(scan.read, next.runs, 0),
    )
  Plan(expects, writes, assignment)
}

fn serial_of(text: Option(String)) -> Int {
  case text {
    Some(value) -> result.unwrap(int.parse(value), 0)
    None -> 0
  }
}

/// Replace the runs of a loaded set with what a transition left, keeping the
/// bytes the commit expects from the original read.
fn apply_runs(loaded: List(Stored), after: List(Run)) -> List(Stored) {
  list.filter_map(loaded, fn(stored) {
    case list.find(after, fn(run) { run.id == stored.run.id }) {
      Ok(run) -> Ok(Stored(..stored, run: run))
      Error(Nil) -> Error(Nil)
    }
  })
}

/// Accept a worker's result exactly as `queue.finish` does, and remember its
/// proof under the next proof number.
///
/// ## Examples
///
/// ```gleam
/// // layout.finish(reader, "run", "build", "worker", 3, completion)
/// ```
pub fn finish(
  reader: Reader,
  id: String,
  action: String,
  worker: String,
  serial: Int,
  completion: queue.Completion,
) -> Result(Plan(Nil), Failure) {
  use #(loaded, run_expects) <- result.try(load(reader, [id]))
  let wanted =
    list.flat_map(loaded, fn(stored) { leased_group(stored.run, action) })
  use #(groups, group_expects) <- result.try(load_groups(reader, wanted))
  use #(proofs, proofs_text) <- result.try(counter(
    reader,
    counter_key("proofs"),
  ))
  use next <- result.try(
    queue.finish(
      state_of(loaded, 0, cache_of(groups)),
      id,
      action,
      worker,
      serial,
      completion,
    )
    |> result.map_error(Refused),
  )
  let #(proof_writes, used) = group_writes(groups, next.cache, proofs)

  // A new proof takes a number, so the counter must still be what was read.
  let counter_expects =
    bool.guard(used == proofs, [], fn() {
      [Is(counter_key("proofs"), proofs_text)]
    })
  plan(
    list.flatten([run_expects, group_expects, counter_expects]),
    list.flatten([
      run_writes(loaded, next.runs, 0),
      counter_writes(counter_key("proofs"), proofs, used),
      proof_writes,
    ]),
    Nil,
  )
}

/// The proof group a finishing action will publish into.
fn leased_group(run: Run, action: String) -> List(#(String, String)) {
  case list.find(run.work, fn(work) { work.task.action.name == action }) {
    Ok(queue.Work(_, queue.Active(lease))) -> [
      #(run.repo, queue.lease_key(lease).recipe),
    ]
    Ok(_) | Error(Nil) -> []
  }
}

/// The waiting run at the head of each free lane, in queue order.
///
/// ## Examples
///
/// ```gleam
/// // layout.preparations(reader)
/// ```
pub fn preparations(
  reader: Reader,
) -> Result(Plan(List(queue.Preparation)), Failure) {
  use waiting <- result.try(children(reader, ["waiting"]))
  use scoped <- result.try(
    list.try_map(lane_names(waiting), fn(lane) {
      lane_runs(reader, lane.0, lane.1)
    }),
  )
  let loaded = by_seq(list.flat_map(scoped, fn(one) { one.0 }))
  plan(
    [
      Keys(["waiting"], keys_of(waiting)),
      ..list.flat_map(scoped, fn(one) { one.1 })
    ],
    [],
    queue.preparations(state_of(loaded, 0, [])),
  )
}

/// The repositories and branches of waiting entries, decoded from their keys.
fn lane_names(waiting: List(#(Key, String))) -> List(#(String, String)) {
  list.filter_map(waiting, fn(pair) {
    case pair.0 {
      [_, repo, branch, _] -> Ok(#(repo, branch))
      _ -> Error(Nil)
    }
  })
  |> list.unique
  |> list.filter_map(fn(lane) {
    use repo <- result.try(unname(lane.0))
    use branch <- result.map(unname(lane.1))
    #(repo, branch)
  })
}

/// The name a path component stands for, undoing `name`.
fn unname(component: String) -> Result(String, Nil) {
  use hex <- result.try(
    string.remove_prefix(component, "x") |> option_of_changed(component),
  )
  use bytes <- result.try(bit_array.base16_decode(hex))
  bit_array.to_string(bytes)
}

/// The text after a prefix was removed, or an error if nothing was removed.
fn option_of_changed(removed: String, original: String) -> Result(String, Nil) {
  bool.guard(removed == original, Error(Nil), fn() { Ok(removed) })
}

/// Record a preparation exactly as `queue.record_preparation` does, against
/// the runs that hold or wait for its lane.
///
/// ## Examples
///
/// ```gleam
/// // layout.record_preparation(reader, preparation, outcome)
/// ```
pub fn record_preparation(
  reader: Reader,
  preparation: queue.Preparation,
  outcome: Result(#(queue.Candidate, List(queue.Task)), queue.PrepareFailure),
) -> Result(Plan(Nil), Failure) {
  use #(loaded, expects) <- result.try(lane_runs(
    reader,
    queue.preparation_repo(preparation),
    queue.preparation_branch(preparation),
  ))
  let state = state_of(loaded, 0, [])
  use next <- result.try(
    queue.record_preparation(state, preparation, outcome)
    |> result.map_error(Refused),
  )
  plan(expects, run_writes(loaded, next.runs, 0), Nil)
}

/// Hand each lane's landing intent to the reconciler, as `queue.landings`
/// does for the runs that can land.
///
/// ## Examples
///
/// ```gleam
/// // layout.landings(reader)
/// ```
pub fn landings(reader: Reader) -> Result(Plan(List(queue.Intent)), Failure) {
  use landing <- result.try(children(reader, ["landing"]))
  use #(loaded, run_expects) <- result.try(load(reader, ids(landing)))
  let #(next, intents) = queue.landings(state_of(loaded, 0, []))
  plan(
    [Keys(["landing"], keys_of(landing)), ..run_expects],
    run_writes(loaded, next.runs, 0),
    intents,
  )
}

/// Record a landing outcome exactly as `queue.record_landing` does.
///
/// ## Examples
///
/// ```gleam
/// // layout.record_landing(reader, intent, Ok(Nil))
/// ```
pub fn record_landing(
  reader: Reader,
  intent: queue.Intent,
  outcome: Result(Nil, queue.Block),
) -> Result(Plan(Nil), Failure) {
  use #(loaded, expects) <- result.try(load(reader, [queue.intent_run(intent)]))
  let state = state_of(loaded, 0, [])
  use next <- result.try(
    queue.record_landing(state, intent, outcome) |> result.map_error(Refused),
  )
  plan(expects, run_writes(loaded, next.runs, 0), Nil)
}

/// Drop up to `batch` of the oldest finished runs beyond `keep_runs` and up
/// to `batch` of the oldest proofs beyond `keep_proofs`, as `queue.retain`
/// does. The receipt says whether more remain, so a caller keeps each commit
/// small by repeating the pass until it is `False`.
///
/// ## Examples
///
/// ```gleam
/// // layout.retain(reader, queue.Retention(200, 1000), 250)
/// ```
pub fn retain(
  reader: Reader,
  retention: queue.Retention,
  batch: Int,
) -> Result(Plan(Bool), Failure) {
  use done <- result.try(children(reader, ["done"]))
  let keep = int.max(0, retention.keep_runs)
  let excess = int.max(0, list.length(done) - keep)
  let oldest = list.take(done, int.min(excess, batch))
  use #(loaded, run_expects) <- result.try(load(reader, ids(oldest)))
  let trimmed = queue.retain(state_of(loaded, 0, []), queue.Retention(0, 0))
  use #(proof_writes, proof_expects, proofs_left) <- result.try(retain_proofs(
    reader,
    retention.keep_proofs,
    batch,
  ))
  plan(
    list.append(run_expects, proof_expects),
    list.append(run_writes(loaded, trimmed.runs, 0), proof_writes),
    excess > batch || proofs_left,
  )
}

/// The writes that drop up to `batch` of the oldest proofs beyond the bound,
/// the expectations they rest on, and whether more proofs remain to drop.
fn retain_proofs(
  reader: Reader,
  keep_proofs: Int,
  batch: Int,
) -> Result(#(List(Write), List(Expect), Bool), Failure) {
  use order <- result.try(children(reader, ["proofs"]))
  let excess = int.max(0, list.length(order) - int.max(0, keep_proofs))
  let oldest = list.take(order, int.min(excess, batch))
  use pointers <- result.try(
    list.try_map(oldest, fn(pair) {
      json.parse(pair.1, pointer_decoder())
      |> result.replace_error(Corrupt("invalid proof pointer"))
    }),
  )
  use #(groups, expects) <- result.map(load_groups(reader, pointers))
  let dropped =
    list.map(oldest, fn(pair) { pair.0 })
    |> list.filter_map(fn(key) { list.last(key) |> result.try(int.parse) })
  let writes =
    list.flat_map(groups, fn(group) {
      let kept =
        list.filter(group.proofs, fn(one) {
          !list.contains(dropped, one.number)
        })
      [store_group(group.key, kept)]
    })
    |> list.append(list.map(oldest, fn(pair) { Delete(pair.0) }))
  #(writes, expects, excess > batch)
}

// ---------------------------------------------------------------------------
// Whole-queue views
// ---------------------------------------------------------------------------

/// Read every run with its enrollment number, oldest first. Tests and
/// tools use this; the hot paths never do.
///
/// ## Examples
///
/// ```gleam
/// // layout.numbered(reader)
/// ```
pub fn numbered(reader: Reader) -> Result(List(#(Int, Run)), Failure) {
  use found <- result.map(
    children(reader, ["run"])
    |> result.try(list.try_map(_, fn(pair) { decode_stored(pair.1) })),
  )
  by_seq(found) |> list.map(fn(stored) { #(stored.seq, stored.run) })
}

/// Read every run and proof into the whole-state form.
///
/// ## Examples
///
/// ```gleam
/// // layout.materialize(reader)
/// ```
pub fn materialize(reader: Reader) -> Result(State, Failure) {
  use #(serial, _) <- result.try(counter(reader, counter_key("serial")))
  use runs <- result.try(numbered(reader))
  use groups <- result.try(children(reader, ["proof"]))
  use proofs <- result.map(
    list.try_map(groups, fn(pair) { decode_group(pair.1) }),
  )
  let cache =
    list.flatten(proofs)
    |> list.sort(fn(a, b) { int.compare(b.number, a.number) })
    |> list.map(fn(one) { one.remembered })
  queue.State(serial, list.map(runs, fn(pair) { pair.1 }), cache)
}

/// The plan that creates the layout from a whole state, once. It expects the
/// layout marker to be absent, so only the first voter to boot commits it.
///
/// ## Examples
///
/// ```gleam
/// layout.bootstrap(queue.empty()) |> layout.writes != []
/// ```
pub fn bootstrap(state: State) -> Plan(Nil) {
  Plan([Is(format_key(), None)], import_state(state), Nil)
}

/// The writes that build the layout from a whole state, numbering runs and
/// proofs in their order. Booting an old store uses it once.
///
/// ## Examples
///
/// ```gleam
/// layout.import_state(queue.empty()) != []
/// ```
pub fn import_state(state: State) -> List(Write) {
  let numbered =
    list.index_map(state.runs, fn(run, index) { #(index + 1, run) })
  let run_puts =
    list.flat_map(numbered, fn(pair) { create_writes(pair.0, pair.1) })
  let proofs = list.reverse(state.cache)
  let numbered_proofs =
    list.index_map(proofs, fn(entry, index) { Numbered(index + 1, entry) })
  let groups =
    list.group(numbered_proofs, fn(one) {
      proof_group(
        one.remembered.repo,
        queue.proof_key(one.remembered.proof).recipe,
      )
    })
  let group_puts =
    dict.to_list(groups)
    |> list.map(fn(pair) { Put(pair.0, encode_group(list.reverse(pair.1))) })
  let order_puts =
    list.map(numbered_proofs, fn(one) {
      Put(["proofs", pad(one.number)], group_pointer(one.remembered))
    })
  list.flatten([
    [
      Put(format_key(), format_value),
      Put(counter_key("serial"), int.to_string(state.serial)),
      Put(counter_key("seq"), int.to_string(list.length(state.runs))),
      Put(counter_key("proofs"), int.to_string(list.length(proofs))),
    ],
    run_puts,
    group_puts,
    order_puts,
  ])
}
