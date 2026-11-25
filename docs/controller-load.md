# Controller load benchmark

The benchmark boots isolated controller voters from an installed `gantryd`
and drives them with real worker-protocol traffic: Git enrollment, Khepri and
Ra claims, blob staging, and result reports. It is a Gleam dev module,
`packages/server/dev/gantry/bench.gleam`, with its pure settings and
statistics in `bench/load.gleam`. It replaces the Node driver
(`scripts/bench-controller.mjs`, now deleted), which produced the
[earlier measurements](#earlier-measurements-node-driver) below.

Run it on Linux with Git and an installed controller. Each sample starts
fresh voters with a new data directory, a private Git remote per repository,
and loopback endpoints. Use a different `GANTRY_BENCH_PORT` for concurrent
invocations.

```sh
cd packages/server
GANTRY_BENCH_CONTROLLER="$(command -v gantryd)" gleam run -m gantry/bench

# One cell of the offered-rate sweep behind the results below.
GANTRY_BENCH_CONTROLLER="$(command -v gantryd)" GANTRY_BENCH_REPOS=100 \
  GANTRY_BENCH_RATE=15 GANTRY_BENCH_SLEEP_MS=50 GANTRY_BENCH_RUNS=300 \
  GANTRY_BENCH_RETAINED=300 GANTRY_BENCH_WORKERS=8 gleam run -m gantry/bench
```

A sample prints one JSON row per phase and prints nothing if a durable check
fails. Controllers must share a local filesystem for the artifact store. The
supported voter counts are one and three.

| Variable | Default | Bounds | Meaning |
| --- | ---: | --- | --- |
| `GANTRY_BENCH_CONTROLLER` | required | path | The `gantryd` launcher to boot |
| `GANTRY_BENCH_VOTERS` | 1 | 1 or 3 | Controller voters |
| `GANTRY_BENCH_SCHEDULERS` | 2 | 1 to 32 | BEAM schedulers per voter |
| `GANTRY_BENCH_RUNS` | 32 | 1 to 20000 | Actions admitted per sample |
| `GANTRY_BENCH_WORKERS` | 4 | 1 to 128 | Concurrent protocol clients, which are the drain's slots |
| `GANTRY_BENCH_POLLS` | 120 | 1 to 10000 | Empty polls after the drain |
| `GANTRY_BENCH_REPOS` | 1 | 1 to 1000 | Registered repositories, each with its own Git remote |
| `GANTRY_BENCH_RATE` | 0 | 0 to 10000 | Offered admissions per second, or 0 for closed-loop admission |
| `GANTRY_BENCH_SLEEP_MS` | 0 | 0 to 999 | Sleep added to each action, in milliseconds |
| `GANTRY_BENCH_POLL_MS` | 10 | 1 to 5000 | A slot's pause after an empty claim during the drain |
| `GANTRY_BENCH_INFLIGHT` | 256 | 1 to 4096 | Open-loop admissions allowed in flight |
| `GANTRY_BENCH_RETRIES` | 4 | 0 to 1000 | Retries after an explicit CAS contention reply |
| `GANTRY_BENCH_TIMEOUT_MS` | 30000 | 1000 to 600000 | Per-request HTTP deadline |
| `GANTRY_BENCH_RETAINED` | 200 | 1 to 1000 | Finished runs each voter keeps (`keep_runs`). The final re-read of every run needs this at least `GANTRY_BENCH_RUNS`, because retention drops older runs once a minute |
| `GANTRY_BENCH_PORT` | 18972 | 1 to 65533 | The first voter's HTTP port |

With `GANTRY_BENCH_RATE` unset the phases match the Node driver. Every
admission completes, then the slots drain the queue, then empty polls run.
A positive rate admits work open-loop at that many actions per second,
interleaved across the repositories, while the slots drain it in the same
window. Admissions are bounded by `GANTRY_BENCH_INFLIGHT`, and the driver
reports how late it sent them against the schedule (`lagP99Ms`).

| Row `id` | One operation |
| --- | --- |
| `enrollment` | Admit an uncached ad hoc action on a pinned Git commit (closed loop) |
| `admission` | The same admission at the offered rate (open loop) |
| `queue-drain` | Claim one action, read its source archive, run a short shell command, stage its output and log, and finish the lease |
| `empty-polls` | Request an assignment once every run has passed |

A protocol client executes the shell fixture on the host, so the benchmark
covers the HTTP, Khepri and Ra, Git enrollment, and blob storage paths. The
Docker worker and its journal are covered by `make e2e`.

Each row has `throughput`, nearest-rank `p50Ms`, `p95Ms`, and `p99Ms`, BEAM
CPU (`cpuMs`, `cpuPercent`, `cpuMsPerOp`, the sum of the voters' user and
system time, excluding the load driver), `peakRssKiB` sampled every 25 ms,
`contentionRetries` (explicit CAS retry-budget replies, HTTP 503), the status
counts, and `snapshotBytes` and `dataDirBytes` at the end of the sample. A
drain row adds `readyP50Ms` through `readyMaxMs`, the time from an action
becoming ready to a slot receiving its lease, plus `makespanMs` and slot
`utilization`. The benchmark checks that every lease is unique and re-reads
every run, proof, and artifact before printing. Retain each invocation's rows
when comparing builds, and alternate old and new controllers to reduce drift.

## Measurements on the Gleam benchmark

Every run below used the same four-vCPU Linux host (an AMD EPYC with a
four-CPU quota, shared with other work and the live controller, which was
idle), 100 repositories, 50 ms actions, `GANTRY_BENCH_RUNS=300` unless a table
says otherwise, and three samples per cell. The tables report the median.
"Ready p99" is the time from an action becoming ready to a slot receiving its
lease, and "Snapshot KiB" is the size the runs would encode to as the earlier
whole-snapshot document, which is what the old store replicated on every
change. The [ADR 001 target](adr/001-khepri-owns-queue-decisions.md) is a
ready p99 under one second at 100 actions per second across 100 repositories.

### The whole-snapshot store with retention (`6a561d4`)

This re-measures the sweep that predates retention, with the controller built
from `6a561d4`, which has `[retention]`. Retention runs once a minute and
keeps 200 finished runs, so a sample shorter than a minute never reaches it.
Every sample here ends with a snapshot of about 279 KiB (300 runs at 0.95 KiB
each), so these cells measure the cost of a snapshot that retention allows,
not one it trimmed. With the default of four retries after a contention
reply, every cell at 10 actions per second and above failed with HTTP 503
`queue contention exceeded retry budget`, so the table uses 1,000 retries.

| Offered/s | Voters | Slots | Admitted/s | Drained/s | Ready p99 | Drain p99 | BEAM CPU ms/op | CAS retries |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 1 | 8 | 9.6 | 9.2 | 1.3 s | 1.1 s | 197.8 | 54 |
| 10 | 1 | 32 | 2.6 | 1.9 | 94.5 s | 70.2 s | 1187.1 | 3043 |
| 10 | 3 | 8 | 8.1 | 7.3 | 8.3 s | 4.6 s | 321.2 | 177 |
| 10 | 3 | 32 | 2.8 | 2.8 | 36.0 s | 52.0 s | 1101.5 | 1610 |
| 15 | 1 | 8 | 11.8 | 10.8 | 6.3 s | 3.7 s | 197.5 | 156 |
| 15 | 1 | 32 | 2.3 | 1.8 | 102.4 s | 64.9 s | 1300.4 | 3610 |
| 15 | 3 | 8 | 7.0 | 6.9 | 12.6 s | 5.3 s | 409.9 | 409 |
| 15 | 3 | 32 | 2.4 | 2.4 | 43.6 s | 43.6 s | 1357.6 | 2394 |
| 25 | 1 | 8 | 5.4 | 4.5 | 48.3 s | 17.9 s | 487.3 | 997 |
| 25 | 1 | 32 | 2.3 | 1.7 | 114.4 s | 42.8 s | 1385.3 | 4075 |
| 25 | 3 | 8 | 5.1 | 5.1 | 26.0 s | 14.1 s | 621.0 | 871 |
| 25 | 3 | 32 | 2.2 | 2.2 | 51.2 s | 71.3 s | 1498.2 | 2902 |

The earlier table said 10 to 15 actions per second kept pace with a p99 under
110 ms. That held while the snapshot was small: one sample of 100 runs at 10
actions per second on this build (95 KiB) had a ready p99 of 15 ms. At 300
runs no cell keeps pace, and 32 slots are worse than eight because more slots
lose more compare-and-swap races. Three voters do worse than one at the same
slots, which fits each write waiting on a majority. Retention bounds the
snapshot at roughly `keep_runs` runs plus `keep_proofs` proofs, which at the
defaults is a megabyte or more, so the bound does not fix the cost of rewriting
the document.

Four of the 12 cells needed a rerun for a reason that is the benchmark's, not
the controller's. A sample that lasts more than a minute meets a retention
pass, which drops the finished runs beyond 200, and the benchmark's final
re-read of every run then fails with 404. Those cells (`15/3/32`, `25/1/8`,
`25/3/8`, and `25/3/32`) were repeated with `GANTRY_BENCH_RETAINED=300`, which
the benchmark gained for this purpose, against the same `6a561d4` controller,
and their rows above come from the reruns.

### The indexed layout (`9f273c1`)

The same cells on the indexed layout. Every cell keeps pace with no
contention reply, and the ready p99 stays under 25 ms.

| Offered/s | Voters | Slots | Admitted/s | Drained/s | Ready p99 | Drain p99 | BEAM CPU ms/op | CAS retries |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 1 | 8 | 10.0 | 10.0 | 12 ms | 89 ms | 71.3 | 0 |
| 10 | 1 | 32 | 10.0 | 10.0 | 11 ms | 111 ms | 133.5 | 0 |
| 10 | 3 | 8 | 10.0 | 10.0 | 12 ms | 95 ms | 95.9 | 0 |
| 10 | 3 | 32 | 10.0 | 10.0 | 14 ms | 125 ms | 187.6 | 0 |
| 15 | 1 | 8 | 15.0 | 15.0 | 12 ms | 82 ms | 49.5 | 0 |
| 15 | 1 | 32 | 15.0 | 15.1 | 13 ms | 111 ms | 91.4 | 0 |
| 15 | 3 | 8 | 15.0 | 15.0 | 14 ms | 93 ms | 68.6 | 0 |
| 15 | 3 | 32 | 15.0 | 15.0 | 15 ms | 119 ms | 128.1 | 0 |
| 25 | 1 | 8 | 25.1 | 25.1 | 13 ms | 90 ms | 33.3 | 0 |
| 25 | 1 | 32 | 25.1 | 25.1 | 13 ms | 125 ms | 60.7 | 0 |
| 25 | 3 | 8 | 25.0 | 25.0 | 17 ms | 102 ms | 51.5 | 0 |
| 25 | 3 | 32 | 25.0 | 25.1 | 21 ms | 146 ms | 77.5 | 0 |

"BEAM CPU ms/op" divides all CPU of the voters by the admitted actions, and
at these rates most of it is idle polling: each slot polls every 10 ms while
it has nothing to do, so more slots cost more. An empty poll takes no lock and
appends nothing to the log, and it costs a few local reads and one quorum
read.

**The exit: 100 actions per second across 100 repositories** (3,000 runs,
32 slots, `GANTRY_BENCH_RETAINED=1000`):

| Offered/s | Voters | Admitted/s | Drained/s | Ready p50 | Ready p99 | Admission p99 | CAS retries |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1 | 100.0 | 100.4 | 6 ms | 145 ms | 739 ms | 0 |
| 100 | 3 | 98.1 | 78.9 | 3.3 s | 8.0 s | 3.4 s | 192 |
| 75 | 3 | 75.0 | 75.2 | 10 ms | 467 ms | 3.0 s | 48 |
| 50 | 3 | 50.0 | 50.1 | 7 ms | 31 ms | 354 ms | 3 |
| 150 | 1 | 149.5 | 109.9 | 1.9 s | 11.2 s | 1.1 s | 0 |

One voter meets the target: a ready p99 of 145 ms against 1 s, with every
admitted action drained at the offered rate. Three voters on this host do
not. They hold 75 actions per second and saturate before 100, because three
BEAM VMs, the load driver, and Git share four vCPUs (the voters used about
240% of 400%), and every command is applied three times. One voter saturates
near 110 actions per second. With eight slots the drain at 100 actions per
second is slot-bound (89% utilization, ready p99 4 s), so the table uses 32
slots, which leave most slots idle (33% utilization).

**Drain at 10 actions per second with 1,000 retained runs** (eight slots,
`GANTRY_BENCH_RETAINED` 200 for 100 runs and 1,000 for 1,000 runs):

| Voters | Runs | Drained/s | Ready p99 | Drain p99 | Final snapshot as one document |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 100 | 10.0 | 13 ms | 97 ms | 93 KiB |
| 1 | 1,000 | 10.0 | 11 ms | 86 ms | 930 KiB |
| 3 | 100 | 10.0 | 13 ms | 95 ms | 93 KiB |
| 3 | 1,000 | 10.0 | 14 ms | 94 ms | 930 KiB |

The drain does not change with the retained runs. On the whole-snapshot store
the same sample at 300 runs could not hold 10 actions per second.

Not explained: three of about 40 samples of 100 or 150 actions per second on
one voter ended with `ResponseTimeout` (the benchmark's 60 s) on
`POST /v1/runs`. The controller logged nothing, and 26 consecutive samples at
the same settings then passed. One of the 150 per second samples also ended
with the benchmark's retention 404 described above. The cause is open, and
[the handoff](next.md) names it.

## Earlier measurements (Node driver)

The sections below came from the Node driver at the commits named in each,
with one repository and the full run history retained. They show the cost of
an idle poll and what the quiet-queue check removed. They are history. Do not
compare their absolute numbers with the table above.

### Initial measurements (commit `0316e2f`)

These medians come from ten fresh samples per configuration on
`0316e2f`, using Gleam 1.19.0, Erlang/OTP 29, Node.js 24.22.3, and a Linux
x86-64 VM with a four-core CPU quota and Intel Xeon Platinum 8573C host
processors. Each voter ran two BEAM schedulers. The VM did not expose a CPU
governor and other workspace processes were active.

| Voters | Runs | Clients | Empty polls | Phase | Operations/s | p50 ms | p95 ms | BEAM CPU ms/op | Peak BEAM RSS MiB |
| ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 3 | 32 | 3 | 360 | Enrollment | 36.00 | 74.47 | 129.09 | 25.00 | 213.80 |
| 3 | 32 | 3 | 360 | Queue drain | 62.58 | 42.00 | 83.50 | 25.63 | 242.28 |
| 3 | 32 | 3 | 360 | Empty polls | 347.81 | 8.14 | 13.43 | 6.24 | 309.60 |
| 1 | 80 | 4 | 640 | Enrollment | 43.25 | 84.06 | 122.88 | 19.56 | 85.54 |
| 1 | 80 | 4 | 640 | Queue drain | 64.16 | 55.47 | 102.96 | 28.88 | 120.61 |
| 1 | 80 | 4 | 640 | Empty polls | 388.50 | 9.32 | 15.39 | 4.78 | 172.25 |

In a separate three-voter shakedown with 48 runs and four clients, a
claim exhausted the controller's eight CAS attempts and returned HTTP 503.
The ten singleton baseline drain samples yielded nine explicit contention
responses, which the driver retried. The recorded three-voter baseline
samples completed without these responses.

The first optimization reused the encoded snapshot when a pure transition
returned the same state and still performed the same quorum CAS. In the
singleton case, empty polls increased from 388.50 to 489.40 per second and
p95 fell from 15.39 to 12.64 ms. BEAM CPU fell from 4.78 to 3.29 ms per poll
and peak RSS from 172.25 to 119.25 MiB. The median paired throughput gain
was 27.2%, against an 11.0% baseline noise estimate. In the three-voter
case, the median paired throughput change was −0.2% against a 12.7%
baseline noise estimate. The change was reverted because it did not
produce a measurable quorum throughput gain. The noise estimate is the
median absolute log ratio across consecutive baseline pairs converted back
to percentage units.

A controller with a planted defect acknowledged results without
persisting them. The benchmark rejected its duplicate lease delivery.
The one-repository workload uses three separate phases and gives an
initial controller baseline for further measurement against the broader
[queue architecture target](adr/001-khepri-owns-queue-decisions.md).

### Profiling with Pickglass (commit `b2ff8cb` for Pickglass)

Pickglass can attach to an isolated benchmark voter without putting its
viewer in the controller VM. Give it the voter's node name and the
benchmark run's distribution cookie in a file readable only by its owner.
For an isolated benchmark capture, use a copy of the driver that writes
the generated cookie with mode `0600` in its temporary directory and
launches the probes during the empty-poll phase. Use enough polls to keep
the workload active for the sampling window.

```sh
pickglass profile --node "$leader" --cookie-file "$cookie_file" \
  --top 16 --seconds 6 --format text
pickglass profile --node "$follower" --cookie-file "$cookie_file" \
  --top 8 --seconds 6 --allocation --format text \
  --module 'gantry@store,gantry_core@protocol,gleam@dynamic@decode,gleam_json_ffi,json'
```

With 5,400 empty polls across three voters and Pickglass at `b2ff8cb`,
Ra's WAL sync and write calls accounted for
254 of the leader's 397 running or runnable samples during empty polls.
On a follower, the instrumented functions allocated 14.5 million heap
words across eight selected processes in six seconds. JSON parsing,
field decoding, and encoding ranked highest. Stack shares are sample
counts, and the allocation counters measure cumulative heap allocation.
Disable probes when collecting the benchmark timings.
[Pickglass attachment guide](https://github.com/Roasbeef/pickglass/blob/b2ff8cb603a0b7ca11a27c2f2a4d8c62862bea55/docs/attach.md)

The profiled controller appended a full snapshot CAS even when the queue
decision left state unchanged. The candidate keeps the fenced local read
and exact-byte CAS for mutations. For an unchanged receipt, it checks the
same snapshot bytes through a Ra consistent query. The leader confirms its
authority with a majority before answering. A mismatch reruns the proposal
within the existing retry budget.

The comparison alternates baseline and candidate order over ten fresh pairs
per configuration. The builds share identical dependency BEAM files and
differ only in the three Gantry queue storage modules. The profilers ran in
separate samples. The second configuration doubles the number of retained
runs and uses two clients across three voters.

| Retained runs | Empty polls | Polls/s | p95 ms | BEAM CPU ms/poll | Peak BEAM RSS MiB |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 32 | 360 | 329.45 → 997.76 | 14.14 → 5.21 | 6.64 → 1.50 | 310.66 → 242.76 |
| 64 | 720 | 213.20 → 685.07 | 14.47 → 4.51 | 9.91 → 1.94 | 530.76 → 283.77 |

The table shows the median across runs. Median paired poll throughput rose
198.5% and 226.5%, against baseline variation of 8.0% and 11.5%.
Paired enrollment and queue-drain throughput changes were within baseline
variation in both configurations. Every sample passed the durable proof
and artifact checks. No samples exhausted the CAS retry budget. These
workloads measure one repository and retain the full run history.

The Ra commit index stayed at 21 through a separate run of 240 empty
polls sent to the two followers. A mixed-version run also exercised
updated followers querying a leader running the previous Gantry build.

### Quiet queues (compared with `0316e2f`)

A controller remembers one snapshot in which every work item is terminal.
Worker polls can confirm those exact bytes through Ra before decoding the
snapshot. A change to the queue makes the bytes differ and sends the poll
through the full claim path. The live test warms the hint on one voter,
admits an uncached build through another, and checks the issued and
replayed lease serials across voters.

The first comparison against `a36413f` measured 62% and 74% less CPU per
poll using the median paired change for the 32-run and 64-run workloads.
The final build was then compared directly with `0316e2f` in ten more
alternating pairs with 64 retained runs, two clients, three local voters,
and 720 empty polls. Both builds reused the same compiled dependencies.

| Empty-poll metric | Original | Quiet queue |
| --- | ---: | ---: |
| Polls/s | 243.15 | 1,589.51 |
| p50 latency, ms | 7.61 | 1.01 |
| p95 latency, ms | 12.57 | 2.49 |
| BEAM CPU, ms/poll | 8.85 | 0.53 |
| Peak combined BEAM RSS, MiB | 529.37 | 278.32 |
| RSS increase during polling, MiB | 244.96 | 0.00 |

The RSS increase is the median per-sample difference between peak RSS
and RSS at the start of polling. The three fresh controller VMs already
used about 200 MiB before enrollment. Enrollment and drain throughput
remained within baseline variation. The test measures controller VMs
serving one repository. [Performance workflow](../skills/gantry-perf/SKILL.md)
