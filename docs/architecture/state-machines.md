# Pure decisions and durable effects

**Status** · Target design, partly built · written 2026-11-21, checked against the code 2026-11-24

This page describes where the queue is meant to end up. It is not a
description of the shipped code, which uses fewer states and has no resource
reservations, quotas, priority, cancellation, or executor admission. Read
[the runtime architecture](runtime.md) first for what is built, and the
transition tables at the top of
[`queue.gleam`](../../packages/core/src/gantry_core/queue.gleam) for the
exact transitions. The [next section](#design-terms-and-the-code) maps the
names used below to the types in the code.

Gantry applies Loom's pure core and effect boundary to builds and Git
submission. A Gleam state carries the evidence available at that phase.
The controller supplies events and interprets effect intents. A quorum
transaction decides which proposal won when controllers race.

Loom's `broker/execution` gives the local pattern. A pure `step` handles
events including helper output, cancellation, and expiry. Its result
contains a next state and effects. The relay owns the process, translates
mailbox messages, and performs those effects. Loom's durability plane
commits intent before external work and records the result before
advancing. Gantry adopts both boundaries.
[Loom's pure execution relay](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/packages/broker/src/broker/execution.gleam) ·
[Loom durability design](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/docs/loom-design.md#33-the-effect-sandwich)

## Design terms and the code

| Design term | Code today | Difference |
| --- | --- | --- |
| Action `Waiting` | `queue.Pending(previous_attempts)` | Not a separate state. `next_work` derives whether the prerequisites passed. |
| Action `Ready` | none | Derived during `claim`, never stored. No execution class or resource requirements. |
| Action `Leased`, `Running` | `queue.Active(lease)` | One state. No executor admission receipt or incarnation. |
| Action `Cancelling` | none | Not built. There is no cancel route. |
| Action `Succeeded` | `queue.Passed(proof)` and `queue.Reused(proof)` | Reuse is a separate step kind. A proof carries the key, output digests, and log. |
| Action `Unsuccessful` | `queue.Failed(Reported or LeaseExpired, log)` and `queue.Skipped` | Typed reasons exist. `Skipped` marks actions stranded by a failure. A retry is a new run, except lease expiry, which retries up to three attempts. |
| Attempt generation | `Lease.serial` and `Lease.attempt` | The serial is global and unique. The attempt counts per action. |
| Lease renewal | none | A lease has a fixed deadline and is never renewed. `queue.expire` returns an action to `Pending` after it. |
| Executor ledger | Worker journal (`worker/custody`) | One slot, one attempt, a start marker, and a recorded receipt. |
| Submission `Queued` | `queue.Waiting` (pinned, not built) | The group holds no graph until its lane is free. |
| Submission `Testing`, `Proven` | `queue.Queued(candidate)` | One state. `queue.landings` derives "every action passed" and moves it to `Landing`. |
| Submission `Landing`, `Landed` | `queue.Landing`, `queue.Landed` | As designed. The intent is the `Landing` state itself. |
| Submission `Stopped` | `queue.Blocked(candidate, reason)` and `queue.Unprepared(branch, members, reason)` | Blocked is a landing refused (`TargetAdvanced`, `PolicyDenied`). Unprepared is a group that could not become a candidate (`MemberMoved`, `Unmergeable`, `Refused`). A failed action leaves `Queued` and ends in phase `failed`. |
| Effect interpreter `Push(IntentReceipt)` | `submit.reconcile` with an `Intent` | As designed. |

## The transition contract

```text
decide(state, command_or_observation) -> Result(proposal, refusal)
commit(expected_revisions, transition, intent_records) -> durable_receipt
interpret(durable_intent) -> external_observation
```

The pure core owns graph compilation, action identity, admission rules,
and the action and submit transitions. Values such as timestamps,
generated IDs, storage receipts, and Git observations enter as typed
inputs. The core stays portable across Erlang and JavaScript. It imports
no process, OTP, or filesystem package and defines no FFI. Portable
decoders validate stored records and wire values before constructing
opaque domain types.

A proposal contains the expected state revisions, the transition, and
typed intents. The storage adapter checks expected revisions and related
records and commits the transition and intents together. Only a committed
receipt can dispatch a durable effect. The interpreter presents the result
as a new observation and advances it through the same path. A timeout
after a commit is reconciled by its operation ID. A retry reads the same
intent and uses the same effect identity. On restart the controller
replays this path from durable records. Ra's own effect notifications
can be lost or repeated across failures. Use them as wakeups and derive
pending work from the intent records.
[Ra effect application and failure handling](https://github.com/rabbitmq/ra/blob/main/docs/internals/INTERNALS.md#effect-application-and-failure-handling)

Use Weft state machines for process lifecycle boundaries such as worker
connection, dispatch, and drain. Weft owns state-scoped timers and
monitors. A timer or process exit becomes an observation for the pure
core. Ra/Khepri owns replicated order. A live OTP process, a working
connection, or a timer firing is insufficient evidence to acquire work
or release resources.

## Action states

This is a type sketch of the target protocol, not the shipped states. The
constructor modules would own opaque `ResolvedAction`, `AttemptLease`, and
proof types. In the code, `Lease`, `Proof`, `Candidate`, `Intent`, and
`Preparation` are opaque already.

| State | Data it carries | Accepted transition |
| --- | --- | --- |
| `Waiting` | Outstanding input or ordering edges | Resolve the last required edge to construct `Ready`. An upstream failure can produce a blocked outcome. |
| `Ready` | Resolved inputs, action key, execution class, and resource requirements | Accept a verified cache result or reserve an executor and construct `Leased`. |
| `Leased` | Run and action IDs, attempt generation, executor incarnation, and reserved resources | Record admission, accept an immediately replayed terminal receipt, or begin cancellation. A dispatch without a reply can have run and retains its reservation until reconciled. |
| `Running` | Lease and executor admission receipt | Accept a matching verified terminal receipt, enter cancellation, or record an unknown outcome following a proven loss. |
| `Cancelling` | Lease and durable cancel intent | Settle with a matching retirement witness, record a terminal receipt that raced cancellation, or report loss while retaining the resource hold until custody is resolved. |
| `Succeeded` | Verified action evidence, output manifest, and execution or cache provenance | Serve results and unlock dependents. Duplicate completion is an idempotent read. |
| `Unsuccessful` | A typed blocked, build failure, cancelled, or lost result | Return the cause and allowed retry behavior. A retry establishes a new attempt and keeps the old outcome in history. |

The queue settles a cancellation and a successful result in one order.
If cancellation committed first, a terminal receipt can release custody
and preserve diagnostics. It cannot unlock dependents or create a pass.

An accepted completion must match the active lease, executor incarnation,
input identity, and output evidence. A result from a superseded
generation cannot unlock dependents, release the current reservation,
publish to the cache, or qualify a submit. Reservations for uncertain
worker custody remain separate from build outcomes. Retrying on another
executor does not credit the previous executor with spare capacity.

Use typed failure reasons to preserve the distinction between a command
that exited unsuccessfully and an outcome the controller cannot know.
Automatic retries apply to replayable, isolated actions. A retry policy
for actions allowed to affect external systems requires a separate
decision and observable effect identity. Agent ad hoc runs start in the
restricted build-only class.

## Submission states

| State | Data it carries | Accepted transition |
| --- | --- | --- |
| `Queued` | Lane, request identities, and immutable PR heads | Select an ordered group and preserve or create its pinned base. |
| `Testing` | Candidate commit, reachable member heads, policy, and build run | Verify required action evidence for this candidate or report a typed build failure or stale input. |
| `Proven` | Candidate and a proof tied to the required policy | Atomically acquire the lane's unresolved intent slot and construct `Landing`. |
| `Landing` | Durable intent with expected base and exact candidate | Push or reconcile only this intent. A branch advance elsewhere settles it as stale. Ambiguous visibility retains the intent. |
| `Landed` | Verified Git observation and integration provenance | Report the landed SHA. Start or resume separate PR status reconciliation. |
| `Stopped` | Conflict, failed checks, moved head, stale base, or policy refusal | Explain the stop. A rebuilt candidate enters a new testing attempt. |

The effect interpreter accepts `Push(IntentReceipt)`. It cannot push
from a queued job, a loose commit SHA, or a successful action alone.
The Git server compares the old ref with the intent's expected base.
The queue holds that intent until it knows the outcome. A controller
election cannot grant permission to substitute a new candidate. PR
status publication consumes a landing receipt and tracks its own
retries. A failed comment or check update leaves the Git observation
valid.

## What belongs in each boundary

| Mechanism | Invariant |
| --- | --- |
| Opaque Gleam types and exhaustive matches | A successful action carries verified outputs. A landing request carries a committed intent and exact candidate evidence. Ambiguous effects have a named phase. |
| Total decoders and constrained constructors | Malformed wire and persisted records cannot create a state with incompatible fields. Older schema versions receive explicit decoding or a typed refusal. |
| Replicated conditional writes | One successful claim can reserve the last slot. A lane has one unresolved submission intent. Competing controllers cannot accept old generations. |
| Executor ledger and Git ref conditions | An executor deduplicates dispatch by attempt identity. Git guards the expected old target. Both can verify effects after a reply is lost. |
| Model checking and fault tests | Duplicate, delayed, reordered, and lost observations preserve the invariants through restarts and partitions. |

Keep the command, state, and effect declarations before the reducer.
Document transitions with the Loom linter's checked table. Use named
variants for domain decisions and total matches across states. Keep
FFI in private host and store adapters. Freeze contracts only after the
first interop proof. Changes to a frozen contract get a numbered
protocol-change note.
[Loom Gleam style](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/docs/gleam-style.md) ·
[Loom Weft guide](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/docs/weft.md)
