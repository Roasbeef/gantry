# Current handoff

**2026-11-21**

The initial runnable slice implements immutable Git inputs, a native action
graph, restricted ad hoc actions, durable claims and results, and guarded
grouped submission. Controllers share Khepri/Ra. The Gleam worker runs
Docker actions, uses Gun for controller requests, and can replay results
from its SQLite journal after losing a response. The Linux OTP release
bundles the BEAM runtime and SQLite NIF and installs `gantryd`,
`gantry-worker`, and `gantry`. The CLI exposes command and request schemas
through `gantry describe`.
[Runtime architecture](architecture/runtime.md) ·
[Deployment runbook](running.md) · [CLI reference](cli.md) ·
[Repository integration](integrating.md)

The local Loom pilot used a snapshot of Loom at
`9aa1383e620aff97aad4acfa3f1d91ce53642b50`. The baseline ran the lint
format check and passed 318 tests. A docs-only commit reused both actions.
The ordered group of two PRs passed both actions, including 319 tests,
and advanced the local bare remote to the exact tested candidate
`676951e45037e0c2daed473708b2dac8d9200eb1`. Both pinned PR heads were
verified as ancestors of that commit. The installed Gleam worker then
opened the original worker's SQLite journal and ran both actions fresh,
passing 319 tests.

The [queue decision](adr/001-khepri-owns-queue-decisions.md) records the
council result and the throughput condition that would change it. Run
`make check`, `make model-check`, and `make e2e` from a clean checkout.
The end-to-end gate exercises real three-voter recovery, a Docker build,
content-based cutoff, and guarded landing against a bare Git provider.
CI is configured to run the live gate through the installed controller
and worker launchers.
The [model and deterministic simulation](../protocol/models/queue/README.md)
cover claim, generation, custody, and exact-ref safety.

Live GitHub provider validation remains open. Use the integration guide
to verify branch rules, exact landing, PR reconciliation, and workflow
comments on a GitHub pilot repository. Loom executor interop and indexed
queue metadata with retention also remain open.
The [controller load benchmark](controller-load.md) measures short-action
admission and drain under concurrent clients, alongside idle polling with
retained runs. The [verification proposal](design-notes/depth-signoff.md)
defines additional load and fault traces for evaluating a change in storage
or dispatch architecture.

The verification suite now includes generated graph and receipt properties,
mutational JSON tests, and a replayable queue simulation with nightly swarm
and coverage-guided campaigns. The controller benchmark records an initial
CPU, RSS, throughput and latency baseline. The first optimization was
reverted after the three-voter workload failed to show a measurable win.
[Queue verification](queue-verification.md) ·
[Controller benchmark](controller-load.md)
