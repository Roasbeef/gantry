# Verification proposal for Gantry

**Status** · Proposed · 2026-11-21

The design depends on two beliefs. A native action graph should save
actual work when an agent edits and retries a target. Loom's existing
executor should let a different controller continue an attempt without
moving authority over the build to the executor. Prove both before
freezing the graph or worker interfaces.

## Raw material and instruments

| Question | Record and instrument | Independent verdict |
| --- | --- | --- |
| Can the graph explain what an edit costs? | Pin a Loom revision. Use its `make check` package graph and `make check-affected` selection as inputs. Capture actual command starts, Git changes with `git diff --name-status`, input manifests, and artifact digests across a dividing set of source, definition, and toolchain edits. On a separate build, use `ninja -t graph` and `ninja -d explain` to exercise explicit and order-only edges. | Compare the observed run closure and output digests with cold rebuilds on each resulting snapshot. Keep a second target and edit series out of graph tuning. |
| Can a controller recover execution on another machine? | Use the real Loom helper and standalone executor. Submit a pinned source tree and an output larger than one wire frame. Capture dispatch, admission, result, and retirement records across a controller kill and a connection drop. Run Loom's `make executor-smoke` before the adapter trace. | An automated probe counts native admissions for an attempt and hashes the recovered output. Replayed dispatches must return the saved result or a typed loss. |
| Can several controllers share the queue safely? | Record a three-voter Khepri/Ra trace with two simultaneous claimers, a lost leader, a worker incarnation change, and a late result. Use a finite TLA+ model under TLC for reservations, generation acceptance, and submission intents. | TLC reports its state count and invariants. The live trace must show one reservation for one slot and no state transitions accepted from expired attempts. |
| Does a tested group land only that commit? | Use bare Git repos for deterministic race injection and a scratch GitHub repo for the provider trace. Use `git rev-parse`, `git merge-base --is-ancestor`, and GitHub PR metadata. Advance the base during a build and drop the successful push response. | The Git ref and landed record identify the same tested candidate. Each recorded source head is its ancestor. GitHub reports the original PR state and links independently. |

## Challenge the design early

Run the executor trace before writing Gantry's distributed scheduler. If
the existing public seam cannot stage a pinned tree and expose a durable
attempt identity across a controller takeover, capture the first failed
operation and the required missing input. Keep Loom reuse at the helper
and standalone package boundary until an adapter or a reviewed upstream
change closes the gap.

For the build graph, replay a focused edit in Loom's executor code and
capture which baseline commands execute again. If the trace exposes no
substantial reusable work across a class of ordinary agent edits, change
the granularity of Gantry's first actions before tuning the scheduler.
Use a held-out edit series to ask which action boundary saves the most
critical-path time per byte of artifact data transferred. Record the
complete trace to make the result reproducible.

## Targets and guards

- **Incrementality.** On the recorded edit series, execute zero actions
  outside the changed-input closure. For deterministic fixtures, compare
  every declared output digest with a cold run. A policy, platform, or
  toolchain identity change must invalidate its affected keys. Report
  command counts and cache outcomes per snapshot.
- **Agent wait.** Aim for p95 under 250 ms from a warm, 10,000-action
  manifest to the first paginated plan response on a documented 8-core
  test machine. Compare the full plan against the graph oracle and
  include a typed reason for each invalidation. Report the actual
  machine, dataset, iterations, and timing distribution.
- **Failover.** Aim for p95 under 10 seconds from restoration of a reachable
  majority to resumption of agent events under repeated controller kills.
  Enumerate the failure interleavings in the model. A late worker result
  cannot complete work after reassignment. A lost push reply cannot
  authorize a second candidate through the same unresolved intent.
- **Protected state.** Require a passing proof for the exact candidate
  and trusted policy before every Git update. Show the stale-base and
  lost-reply tests failing when the expected-base comparison and intent
  reconciliation are removed, respectively.

These are proposed thresholds. Report observed values and the constraint
that sets any miss. A proof requiring a Loom protocol extension or a new
dependency produces a scoped proposal with the measured need before
changing the public interface. Run all reproducible gates from a clean
checkout and retain their exit codes and raw results.

## Execution choices

| Choice | Work and dependencies |
| --- | --- |
| Full evidence pass | Set up the pinned Gleam and OTP toolchain, Loom's native helper, Ninja, TLC, a three-voter lab, two executor hosts, and an authorized scratch GitHub repo. Capture a representative Loom workload and the held-out traces. |
| Local harness first | Use the action fixture, real helper, local Khepri/Ra nodes, TLC, and bare Git. This gives early feedback on graph and fencing mechanics. GitHub reconciliation and cross-host timings remain open. |
| Design only | Review the interfaces and invariants in this proposal. Keep the targets as acceptance criteria for future implementation. |

[Beefstack Depth](https://github.com/Roasbeef/beefstack/blob/71134453b93d1f946203398ee8a8ebd739849e37/skills/depth/SKILL.md) ·
[Loom execution guide](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/docs/execution.md)
