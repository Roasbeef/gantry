# Current handoff

**2026-11-24**

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

A live GitHub pilot has verified exact landing, PR reconciliation, and
idempotent workflow comments on a disposable target branch. A deployment
using protected branches still needs a pilot with its own rules and
controller identity. Loom executor interop and indexed queue metadata
with retention also remain open.
The [controller load benchmark](controller-load.md) measures short-action
admission and drain under concurrent clients, alongside idle polling with
retained runs. The [verification proposal](design-notes/depth-signoff.md)
defines additional load and fault traces for evaluating a change in storage
or dispatch architecture.

The verification suite includes generated graph and receipt properties,
mutational JSON tests, and a replayable queue simulation with nightly swarm
and coverage-guided campaigns. Pickglass identified Ra writes during
unchanged polls. A majority-confirmed snapshot check now validates those
receipts. Worker polls can reuse the same check to confirm a remembered
terminal snapshot before decoding it. In the 64-build workload, the
combined changes used about one seventeenth of the original CPU per
empty poll. The deployment runbook and performance skill cover adding
capacity and repeating the benchmark.
[Stable gateway origin and readiness](running.md#give-clients-one-stable-origin)

Environment reads, the worker schema lookup, and Docker environment
policy use Gleam bindings. The queue store distinguishes authorization,
snapshot conflicts, and the quiet-queue path through typed adapter
outcomes. [Runtime boundaries](architecture/runtime.md#components)

The CLI and onboarding are Gleam. `gantry_core/request` owns the build
and submit request rules for both the controller and `gantry/cli`, and
unknown keys are rejected on both sides
([ADR 002](adr/002-one-owner-for-request-rules.md)). The release's third
launcher runs `gantry@cli`, so the CLI needs no jq, curl, or OpenSSL.
`gantry/cli/onboarding` replaces the Bash helper with the same profile
layout. A Weft actor in `gantry/cli/service` owns each controller and
worker child and tears down its process group, and
`setpriv --pdeathsig TERM` covers a signalled CLI. Gleeunit tests with an
injected transport replace `scripts/check-cli.sh`. A BEAM CLI call costs
about 230 to 340 ms on the loaded four-core Linux test host, where bash
took 7 to 24 ms. A bare `erl` boot there is about 160 ms. A `start_clean`
boot would save about 50 ms if that ever matters. The interrupt behaviour
is checked by hand on Linux, not by `make e2e`.
[CLI reference](cli.md)

The fleet bootstrap slice adds a managed local smoke build and remote
worker profiles. Local init and worker setup preserve profile identity
on repeat runs. The proposal also describes staged controller
maintenance, per-worker credentials, and managed queue cutover.
[Fleet bootstrap design](design-notes/fleet-bootstrap.md)
[Queue verification](queue-verification.md) ·
[Controller benchmark](controller-load.md)
