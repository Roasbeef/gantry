# Controller load benchmark

Run the benchmark on Linux with Node.js 22 or later, Git, and an installed
Gantry controller. It starts the launcher with a fresh data directory, a
private Git remote, and loopback endpoints for each sample. Use a different
starting port for concurrent invocations.

```sh
node scripts/bench-controller.mjs "$(command -v gantryd)"
GANTRY_BENCH_VOTERS=3 GANTRY_BENCH_WORKERS=3 GANTRY_BENCH_POLLS=360 \
  node scripts/bench-controller.mjs "$(command -v gantryd)"
```

The defaults are one voter, two BEAM schedulers per voter, 32 runs, four
concurrent clients, 120 empty polls, and starting port 18972. Configure these
with `GANTRY_BENCH_VOTERS`, `GANTRY_BENCH_SCHEDULERS`, `GANTRY_BENCH_RUNS`,
`GANTRY_BENCH_WORKERS`, `GANTRY_BENCH_POLLS`, and `GANTRY_BENCH_PORT`.
Controllers must share a local filesystem for the benchmark's artifact store.
The two supported voter counts are one and three.

Each successful sample prints three JSON rows.

| Phase | One operation |
| --- | --- |
| Enrollment | Admit an uncached ad hoc action on a pinned Git commit. |
| Queue drain | Claim one enrolled action, read its source archive, run a short shell command, stage its output and log, and finish the lease. |
| Empty polls | Request an assignment once all runs have passed and their records are retained. |

A protocol client executes the shell fixture on the host. The benchmark
covers the actual HTTP, Khepri/Ra, Git enrollment, and blob storage paths.
The Docker worker launcher and its SQLite journal are covered by
`make e2e`. Individual phase latencies exclude waiting for the preceding phase.

Throughput is completed operations divided by elapsed phase time. The
p50 and p95 use nearest-rank quantiles of individual operation latencies.
CPU is the sum of all voter BEAM processes' Linux user and system time. CPU
percentage is relative to one logical core, and excludes the load driver and
subprocesses. RSS is the maximum sampled sum of voter BEAM resident memory
at 25 ms intervals, in KiB. This includes any shared pages counted once per
process. The reported contention counter covers explicit CAS retry-budget
failures. The timer includes the client's bounded backoff and retry after
those responses. Other errors stop the sample.

The benchmark checks unique assignments and re-reads every stored run,
proof and artifact after the timed phases. It prints results only after
these checks pass. Retain each invocation's JSON rows when comparing builds.
Repeat from fresh state and alternate old and new controllers to reduce drift.

## Initial measurements

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
