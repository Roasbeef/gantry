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
| TLA+ | Bounded interleavings of claims, completions, and guarded landing. |
| Generated properties | Graph closure and ordering, invalid graphs, lease ownership, output paths, and serialization of reachable queue states. |
| JSON fuzzing | Generated and mutated manifests, action defaults and input types, and completion tags and artifacts. QCheck shrinks a failure and prints the counterexample. |
| Deterministic simulation | Production queue transitions and state codec against a virtual controller, worker receipts, and a Git ref. |
| Live E2E | Real Khepri voters, worker journal, Docker, blob transport, and a bare Git remote. |
| Load benchmark | Real controller HTTP, Ra/Khepri, Git and artifact paths, with latency, throughput, CPU and resident memory. |

## Run and replay

```sh
make check
scripts/queue-dst.sh swarm 1 10000 128
scripts/queue-dst.sh replay 1 128
scripts/queue-dst.sh ops 127 0 3 13
GANTRY_DST_CORPUS=/tmp/gantry-queue-corpus.term scripts/queue-dst.sh guided 9 1000
```

The fixed corpus and generated properties run on BEAM and JavaScript in
`make check`. The BEAM campaign CLI prints the exact seed or operation
bytes to replay. A replay prints the mask and each zero-indexed event
before applying it. The nightly workflow runs three shards of 10,000
seeded schedules and 1,000 coverage-guided inputs each. It time-boxes
each pass and retains a versioned, bounded corpus per shard. Pull
requests also run a short instrumented campaign.

## What the simulation runs

The fixture admits two ordered submissions for one branch and an
independent build. Each has a two-action DAG. A producer on one worker
pool publishes a file that a consumer on the other pool needs.

The production calls are `queue.claim`, `queue.finish`,
`queue.landings`, `queue.record_landing`, and the state codec.
The harness models stale reads and conditional writes, deferred delivery
of an assignment, replayable results, and the expected-old-ref update.
It dispatches the exact intent returned by the committed transition. A
simulated controller restart reloads persisted JSON and discards any
undispatched intent. The next queue read can recover the intent by its
durable identity.

A Park–Miller seed supplies a seven-bit mask and operation bytes. The
low nibble selects the operation, bit four chooses the worker pool, and
bit five chooses which receipt field to corrupt. A disabled fault uses
the corresponding ordinary operation. The swarm skips the random draws
used by one schedule before starting the next.

| Operation | Effect |
| --- | --- |
| 0, 1, 14, 15 | Refresh the controller snapshot. |
| 2, 3 | Claim a lease. Mask bit 0 lets operation 3 lose its reply after commit. |
| 4, 5, 6 | Deliver a receipt. Mask bit 1 lets operation 6 select the oldest instead of the newest. |
| 7 | Mask bit 2 submits a receipt with a wrong worker or generation. |
| 8 | Mask bit 3 drops the reply after the result's write and checks replay. |
| 9, 10, 11 | Commit or dispatch a landing intent. Mask bit 4 lets operation 11 lose the Git reply. |
| 12 | Mask bit 5 lets an external write advance the base or create a descendant of the landed candidate. |
| 13 | Mask bit 6 reloads durable state and drops controller-local pending work. |

Every event checks ownership, monotonic generations, dependency artifact
identity, and the tested Git ref. During heal the same claim, completion,
and reconcile calls deliver work reliably and advance virtual time.
The build must pass. The first submission must land unless an external
writer beat it, and the second must be blocked. The heal uses the exact
claim returned to each slot and checks every transition. Each schedule
runs twice and compares its final world and event observations.

Coverage-guided fuzzing mutates mask and operation bytes. It retains
inputs that reach new instrumented lines in the production queue or
protocol modules. This tests the controller's decision boundary.
Khepri's actual CAS retries, filesystem behavior, worker custody, and
Git commands are exercised in the live harness. The virtual Git
fixture represents a single shared base and one descendant after landing.

## Audit measurements

OTP `cover` instruments the compiled production queue. OTP `tprof`
profiles queue calls with the original and extended simulation suites
run separately. Compare coverage under identical instrumentation.
Throughput reflects different workloads because the extended fixture
checks a DAG, serializes restarts, and requires terminal progress.

The unchanged baseline ran six fixed 1,000-event schedules. It covered
110 of 154 compiled queue lines. The original schedule had no heal
assertion, used a single action per run, and drove the convenience
`landing` function. The expanded harness exercises the production
reconciler's `landings` entry point and the actual state codec.

The extended fixture covered 133 of 154 compiled queue lines. The
remaining zero-hit functions were the single-intent convenience call
`landing` and duplicate admission identity handling. The queue properties
exercise duplicate admission separately from this measurement. The three
10,000-schedule campaigns completed at 873–974 double-checked schedules
per second with 128 faulted events per schedule. A 3,000-input guided
campaign hit 203 lines across the queue and protocol modules and retained
five inputs. A second campaign restored the saved corpus.

Two isolated queue mutations failed on the first swarm case, seed 1.
One dropped the lease-generation comparison. The other returned the wrong
repository in only the first committed landing intent. The graph property's
mutation that omitted order-only edges and the decoder mutation accepting
an unknown completion tag both failed and shrank on BEAM and JavaScript.
These are targeted sensitivity checks. The live provider and physical
worker run on their own E2E and deployment gates.
