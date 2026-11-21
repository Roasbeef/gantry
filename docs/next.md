# Current handoff

**2026-11-21**

The initial runnable slice implements immutable Git inputs, a native action
graph, restricted ad hoc actions, durable claims and results, and guarded
grouped submission. Controllers share Khepri/Ra. A standalone Docker
worker journals each slot and can replay a result after losing a response.
The [runbook](running.md) covers configuration and the API.

The [queue decision](adr/001-khepri-owns-queue-decisions.md) records the
council result and the throughput condition that would change it. Run
`make check`, `make model-check`, and `make e2e` from a clean checkout.
The end-to-end gate exercises real three-voter recovery, a Docker build,
content-based cutoff, and guarded landing against a bare Git provider.
The [model and deterministic simulation](../protocol/models/queue/README.md)
cover claim, generation, custody, and exact-ref safety.

The next implementation slices are scoped GitHub deployment validation,
the Loom executor interop test, and indexed queue metadata with retention.
Obtain a measured short-action workload before selecting a different
storage or dispatch architecture. The [verification proposal](design-notes/depth-signoff.md)
defines the load and fault traces.
