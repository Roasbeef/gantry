# Khepri owns queue decisions

**Status** · Accepted for the initial deployment · 2026-11-21

A ready claim, generation, capacity reservation, and dispatch intent must
commit together. A local mailbox or a broker delivery may carry a wakeup.
A replacement controller needs enough committed information to reconcile
the exact attempt after losing that wakeup or its reply.

The Beefstack council selected Khepri/Ra as the transactional authority.
Three independent Astra 6.2 seats and the judge ranked it ahead of a
queue-specific Ra state machine and RabbitMQ quorum dispatch with a
separate transactional database. Khepri reuses the quorum, conditional
write, and ownership patterns already exercised in Loom. The first
Gantry store deliberately uses one bounded snapshot CAS so a claim and
its capacity hold share a clear commit boundary.

The strongest alternative is a Ra state machine with maintainable ready
and eligibility indexes. Profiling should first test an indexed, batched
Khepri layout. Reconsider the queue-specific state machine if the Khepri
implementation develops a sustained backlog or misses a proposed one
second p99 ready-to-dispatch target when eligible capacity is free at
100 actions per second across 100 repositories. Compare both on the same
hardware. Require zero duplicate admissions, stale result acceptances,
and overlapping submission intents when injecting leader loss, lost
worker replies, and late completions. These are performance targets.

RabbitMQ quorum queues can supply replicated dispatch with acknowledgements.
That option also requires the broker, state store, and an outbox
reconciler. Keep dispatch on the worker API until measured demand
justifies the extra recovery boundary.

[Beefstack council](https://github.com/Roasbeef/beefstack/blob/71134453b93d1f946203398ee8a8ebd739849e37/skills/council/SKILL.md) ·
[Loom Khepri ownership](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/docs/architecture/directory.md)

## Addendum · 2026-11-24 · The benchmark meets the reconsideration trigger

The decision above stands. The trigger it set has been met, though. The
[controller load benchmark](../controller-load.md#measurements-on-the-gleam-benchmark)
offered 100 repositories a steady rate of 50 ms actions on a four-vCPU host,
and every cell at 25 actions per second either saturated or missed the one
second p99 ready-to-dispatch target. The target in this record is four times
that rate (100 actions per second). At 10 to 15 actions per second the drain
kept pace, with a p99 of 57 to 110 ms. These runs predate the retention fix,
so the retained-run cells overstate what a bounded snapshot costs.

The ADR says to test an indexed, batched Khepri layout before moving to a
queue-specific Ra state machine. That remains the next step. The measured
causes point at it: every mutation rewrites and recompares the whole
snapshot, CPU per operation grows with snapshot size, and CAS refusals grow
with the number of polling slots. Compare the new layout against the current
one on the same host and the same fixture, and keep the zero-duplicate,
zero-stale-acceptance, and zero-overlap conditions above.

## Addendum · 2026-11-24 · The indexed layout

In this addendum, we record the layout that replaces the single snapshot, and
the rules it must keep. The decision above still stands: Khepri and Ra own the
queue, and the pure core decides. What changes is the unit that a decision
reads and replaces. It was the whole queue, and it becomes the few keys the
decision touched.

### The layout

Every run lives under its own key, and a small index per question the
controller asks lives beside it. An index entry is derived from a run alone,
by one core function, so it can only disagree with the run if a write skipped
that function. A key component is the lowercase hex of the name it stands for,
or a zero-padded counter, so a name can never carry a path separator and a
sorted listing is in enrollment order.

| Key | Holds | Answers |
| --- | --- | --- |
| `counter/serial`, `counter/seq`, `counter/proofs` | A counter each | The next lease serial, enrollment number, and proof number |
| `run/<id>` | The run and its enrollment number | Lookup by identity |
| `ready/<pool>/<seq>` | The run's ID | The oldest run with an action a slot in `pool` can take now |
| `active/<seq>` | The earliest lease deadline and the workers holding leases | Which leases lapsed, and whether a worker already holds one |
| `waiting/<repo>/<branch>/<seq>` | The run's ID | The head of each lane that is waiting to be prepared |
| `holds/<repo>/<branch>/<seq>` | The run's ID | Which run holds a lane, and which runs can land |
| `done/<seq>` | The run's ID | The oldest finished runs, for retention |
| `proof/<repo>/<recipe>` | The proofs for a recipe, each with its proof number | Reuse by key |
| `proofs/<n>` | The proof's group | The oldest proofs, for retention |

A decision runs against the keys it read, not against a snapshot. The core
reads through a function the caller supplies, selects only the runs the
operation can affect (the expired ones, the worker's own lease, the oldest
ready ones, one lane), hands exactly those runs to the existing transitions in
`queue`, and returns a plan. A plan holds the keys it relied on with the bytes
it saw, the keys to write, and the receipt. The transitions themselves do not
change, which is why the model and the simulations still describe them.

A plan commits in one Khepri transaction that compares every expected key and,
if all match, writes all of them. A claim therefore still commits its lease,
its serial, and the run's indexes together, and a lost race loses before any
effect escapes. A plan that writes nothing, such as an empty poll, is confirmed
by a quorum read of the same expectations and appends nothing to the log. This
replaces the digest of the whole snapshot that the quiet-queue hint compared.

Three counters are the only keys that unrelated operations contend on. Each
controller serializes the operations that write one counter, so its own
traffic does not lose races to itself, and the expectation still catches
another controller. The gate is a mutual-exclusion primitive in the Erlang
bridge. It decides nothing about the queue.

### What the plans owe

The commit changes how state is stored, so the equivalence of the two paths is
the property to check, not assume. For any sequence of operations, running
each through the indexed layout must leave the same runs, proofs, serial, and
indexes as running the same operation on the whole state, and must return the
same receipt. The simulations run both paths in lockstep and count a mismatch
as a safety violation. A mutation that makes an index entry skip a run, or
drops an expectation, must fail them.

One ordering rule is weaker than before and is written down here. A claim
reads the ready index and then the runs, so a run that becomes ready between
those reads can be passed over by one claim. That is a claim linearized a
moment earlier. Safety does not depend on it, because every lease is still
issued once under its serial. The oldest-first order holds exactly when
operations do not overlap.

### Upgrading

The layout is a new key space. A voter that finds the old snapshot and no
`format` key imports it in one transaction and deletes it. Voters of both
layouts cannot share a cluster, so upgrade all voters together, and take a
backup first ([operations](../operations.md#back-up-and-restore-the-voter-data)).
This drops the mixed-version query that the snapshot hint kept for rollouts.

### The exit, and what would reopen the state machine

The exit is the one in the next slice: at 100 actions per second across 100
repositories, a ready-to-dispatch p99 under one second on the four-vCPU host,
with the drain at 10 actions per second unchanged when 1,000 runs are
retained. The numbers are in [controller load](../controller-load.md). The
custom Ra state machine stays out unless this layout misses that exit. Two
costs remain linear and are named so a later reader can find them: a claim
lists its pool's ready index, and retention lists the finished index. Both
entries are tens of bytes, and a per-pool head cursor replaces the listing if
a backlog ever makes it show.
