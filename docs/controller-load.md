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

# The offered-rate sweep behind the results below.
GANTRY_BENCH_CONTROLLER="$(command -v gantryd)" GANTRY_BENCH_REPOS=100 \
  GANTRY_BENCH_RATE=15 GANTRY_BENCH_SLEEP_MS=50 GANTRY_BENCH_RUNS=600 \
  GANTRY_BENCH_WORKERS=8 gleam run -m gantry/bench
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

These runs used a four-vCPU Linux host, 100 repositories,
50 ms actions, and three samples per cell, and report the median. They
predate the retention fix (`[retention]` in `controller.toml`), so a sample's
snapshot grew with every retained run. The measured target is the one in
[ADR 001](adr/001-khepri-owns-queue-decisions.md): a ready-to-dispatch p99
under one second at 100 actions per second across 100 repositories.

| Offered rate | Cell | Result |
| ---: | --- | --- |
| 10 to 15 actions/s | One and three voters | Drain keeps pace. Ready-to-dispatch p99 is 57 to 110 ms |
| 25 actions/s | One voter, 8 slots | Saturates at 21.5 actions/s, p99 825 ms |
| 25 actions/s | One voter, 32 slots | Saturates at 5.2 actions/s, with 1015 CAS refusals (HTTP 503) |
| 25 actions/s | Three voters, 8 slots | Saturates at 13.3 actions/s, p99 4.8 s |
| 10 actions/s, 600 retained runs | One voter | Drain falls to 1.3 to 1.7 actions/s, p99 in minutes |

At 25 actions per second every cell saturates or exceeds a one second p99,
which is a quarter of the rate the ADR asks for. BEAM CPU per operation grew
from 12 ms at a 31 KiB snapshot to 52 to 75 ms at 94 to 141 KiB, which is
what the whole-snapshot compare-and-swap predicts: every mutation reads,
decodes, re-encodes, and replaces the full document. More slots make it worse
(the 32-slot cell), because competing mutations lose the swap and retry.
Three voters did worse than one at the same slot count, which fits each write
waiting on a majority.

Two caveats. Retention now bounds the snapshot, so the 600-run cell should be
rerun against a current build before anyone reads it as the steady state.
Three samples per cell is enough to see the cliff and not enough to rank
cells that are close.

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
