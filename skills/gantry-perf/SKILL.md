---
name: gantry-perf
description: Profile Gantry controllers or workers, compare CPU, memory, latency and throughput under load, and verify a performance patch before merging it.
---

# Gantry performance

1. Name the role, workload and unit of work. The controller benchmark
   measures admission, short-action drain and empty polls through real
   HTTP, Git and Ra. For worker investigations, use the installed worker
   with Docker and measure the worker VM, container cgroups and Docker
   helpers separately. Record action inputs, image digests, slot counts,
   scheduler counts, CPU quota and memory limits.
2. Save the baseline revision and freeze the benchmark and fixture.
   Confirm that it checks durable proofs and output bytes. Run at least
   ten alternating baseline and candidate pairs with fresh state. Hold
   back a second workload with a different queue size or concurrency.
   Use the same toolchain, compiled dependencies and host for both
   releases. Keep unrelated load off the measurement host.
3. Take a separate Pickglass capture under the phase being investigated.
   Attach to an isolated named BEAM node using an owner-only cookie
   file. Use stack samples for hot paths and allocation counters for
   suspected churn. Collect scorecard timings with profiling disabled.
4. Change one mechanism at a time. Compare throughput, p95 latency,
   CPU per operation and peak RSS for every phase. Keep a gain only
   when it exceeds baseline variation and the held-out workload
   preserves outcomes and stays within baseline variation on the
   guarded metrics. Investigate a failed or drifting sample before
   interpreting its numbers.
5. Run `make check`, `make model-check TLA2TOOLS=/path/to/tla2tools.jar`
   and `make e2e`. For quorum or lease changes, exercise replay,
   minority refusal, recovery and mixed-version controllers. Record
   revisions, the workload, raw results and the limits of the claim in
   the benchmark report. Review the diff and verify the installed
   release in CI before merging.

Use the [controller benchmark and profiling guide](../../docs/controller-load.md)
for commands, [the deployment runbook](../../docs/running.md) for topology
and [queue verification](../../docs/queue-verification.md) for the fault tests.
