# Queue verification

An agent sends a Git revision and target to a controller. The pure Gleam
core builds an action graph and decides which work can run. Khepri and Ra
commit run state, leases, and landing intents across controllers. Workers
pull assignments, run actions in Docker, and keep result receipts in a
local SQLite journal until the controller acknowledges them. Inputs,
logs, and outputs are addressed by hash. Submission adds a Git effect
that can advance a branch to the tested candidate when its base matches.
[Runtime architecture](architecture/runtime.md)

| Layer | What it exercises |
| --- | --- |
| TLA+ | Bounded interleavings of waiting groups, preparation order, claims, lease expiry and reassignment, late receipts, failure skipping, and guarded landing. |
| Generated properties | Graph closure and ordering, invalid graphs, lease ownership, output paths, and serialization of reachable queue states. |
| JSON fuzzing | Generated and mutated manifests, action defaults and input types, and completion tags and artifacts. QCheck shrinks a failure and prints the counterexample. |
| Deterministic simulation | Production queue transitions and state codec against a virtual controller, worker receipts, and a Git ref. A single-lane harness asserts each event. A two-controller churn harness counts violations. |
| Live E2E | Real Khepri voters, worker journal, Docker, blob transport, and a bare Git remote. |
| Load benchmark | Real controller HTTP, Ra/Khepri, Git and artifact paths, with latency, throughput, CPU and resident memory. |

## Run and replay

```sh
make check
scripts/queue-dst.sh swarm 1 10000 128
scripts/queue-dst.sh sweep 1 1000 128
scripts/queue-dst.sh churn 73 128
scripts/queue-dst.sh growth 2000
scripts/queue-dst.sh replay 1 128
scripts/queue-dst.sh ops 127 0 3 13
GANTRY_DST_CORPUS=/tmp/gantry-queue-corpus.term scripts/queue-dst.sh guided 9 1000
```

The fixed corpus and generated properties run on BEAM and JavaScript in
`make check`. The BEAM campaign CLI prints the exact seed or operation
bytes to replay. A replay prints the mask and each zero-indexed event
before applying it. `sweep` prints the counter table of the churn harness
and exits nonzero on any safety violation, and `churn` prints one seed. The
nightly workflow runs three shards of 10,000 seeded schedules and 1,000
coverage-guided inputs each. It time-boxes each pass and retains a
versioned, bounded corpus per shard. Pull requests also run a short
instrumented campaign.

## What the simulation runs

The single-lane harness admits three submissions for one branch as
`Waiting` and an independent build. Each has a two-action DAG. A producer
on one worker pool publishes a file that a consumer on the other pool
needs. The harness plays the controller. It asks `preparations` for the
head of the lane, builds a candidate whose base is the ref it observes
now, and calls `record_preparation`. A second group is therefore prepared
only after the first one lands, is blocked, or is refused.

The production calls are `claim`, `expire`, `finish`, `preparations`,
`record_preparation`, `landings`, `record_landing`, `retain`, and the
state codec. The harness models stale reads and conditional writes,
deferred delivery of an assignment, replayable results, and the
expected-old-ref update. It dispatches the exact intent returned by the
committed transition. A simulated controller restart reloads persisted
JSON and discards any undispatched intent. The next queue read can
recover the intent by its durable identity.

A Park–Miller seed supplies a nine-bit mask and operation bytes. The low
nibble selects the operation, bit four chooses the worker pool, and bit
five chooses which receipt field to corrupt. A disabled fault uses the
corresponding ordinary operation. The swarm skips the random draws used by
one schedule before starting the next.

| Operation | Effect |
| --- | --- |
| 0, 1 | Refresh the controller snapshot. |
| 2, 3 | Claim a lease. Mask bit 0 lets operation 3 lose its reply after commit. |
| 4, 5, 6 | Deliver a receipt, possibly from an expired generation. Mask bit 1 lets operation 6 select the oldest instead of the newest. |
| 7 | Mask bit 2 submits a receipt with a wrong worker or generation. |
| 8 | Mask bit 3 drops the reply after the result's write and checks replay. |
| 9, 10, 11 | Commit or dispatch a landing intent. Mask bit 4 lets operation 11 lose the Git reply. Mask bit 8 lets operation 10 record a provider policy denial. |
| 12 | Mask bit 5 lets an external write advance the base. |
| 13 | Mask bit 6 reloads durable state and drops controller-local pending work. |
| 14 | Advance the clock past every lease deadline and run `expire`. |
| 15 | Prepare the head of the lane, or with mask bit 7 refuse it with a typed failure. Other bits run `retain` with one finished run kept. |

Every event checks lease ownership and uniqueness, monotonic generations,
lane exclusivity, preparation order, that a waiting or refused group has no
actions, that a failed run holds no pending action, dependency artifact
identity, and the tested Git ref. A result is accepted only for the live
serial and worker, so a result from an expired or reassigned generation must
be refused, and the harness counts each refusal path. Retention is checked
against an independent definition of a finished run. It must drop only
finished runs and must keep the newest proofs. During heal the same claim,
completion, preparation, and reconcile calls deliver work reliably and
advance virtual time. Every run must end finished with no live lease and no
pending action. Each schedule runs twice and compares its final world and
event observations.

The churn harness runs two controllers against one store and a remote with
two branches. A controller can crash at each point of the landing sequence
and restart from the persisted bytes, and both can reconcile one intent at
once. Workers can vanish while holding a lease, restart under the same ID,
and deliver late results. Mask bit 9 adds poison actions whose worker dies
before it reports, so they expire until the last attempt fails the run.
Reasons are oversized so the cap is exercised. Violations are counted so
a sweep reports numbers. The heal restores reliable delivery to live workers
and controllers only. A lease held by a vanished worker must expire and be
reassigned for the heal to finish. After the heal the harness counts stuck
leases, stuck landings, and runs that are neither finished nor waiting on an
unfinished run ahead of them in their lane. All must be zero.

`scripts/queue-dst.sh growth N` drives N builds through the core with
retention after each transition. Every fifth run is rejected with a 256 KiB
reason. The largest encoded state stays at 5,188 bytes for 200 and for 2,000
runs, so the 4 MiB store limit cannot be reached by history. The core caps a
reason at 1,024 bytes where it records it.

Coverage-guided fuzzing mutates mask and operation bytes. It retains
inputs that reach new instrumented lines in the production queue or
protocol modules. This tests the controller's decision boundary.
Khepri's actual CAS retries, filesystem behavior, worker custody, and
Git commands are exercised in the live harness. The virtual Git
fixture represents one branch as a linear history in the single-lane
harness.

## Sweep results

`scripts/queue-dst.sh sweep 1 1000 128` ran 1,000 seeds twice each and
reported no safety violation and no liveness failure. The coverage counters
show that each path ran. Across the 1,000 seeds, leases expired 4,070
times and were reassigned 3,987 times, 2,172 late results from an earlier
generation were refused, 224 workers returned after their lease expired,
861 poisoned runs failed with `LeaseExpired`, 698 actions were skipped,
4,579 groups were prepared and 421 preparations were refused, 461 landings
were denied by policy, 900 finished runs were dropped by retention, 153
oversized reasons were capped, and 2,220 runs landed.

## Mutation checks

A planted mutation of `queue.gleam` must fail a harness. Each of these was
applied alone and reverted afterward. Accepting a result for a serial other
than the live one gave 37 stale acceptances in the churn sweep and failed the
single-lane harness. Offering a waiting group while its lane was held
produced lane overlaps in 297 of 300 seeds. Letting retention drop any
oldest run produced 23 dropped live runs. Removing the skip of pending
actions on failure produced runs with pending actions in a failed run.
Removing the attempt bound left leases stuck after the heal. Dropping the
proof index in `retain` lost proofs in 221 seeds. The TLA+ model fails on
the corresponding mutations listed in its README.

Earlier measurements from OTP `cover` and `tprof` are not repeated here,
because the instrumented code and fixture changed. Rerun the guided
campaign to compare coverage on the current queue module.
