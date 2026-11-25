# Queue safety model

Run from this directory with Java and the v1.7.4 release artifact (TLC2 2.19).
The jar SHA-256 is
`936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.
[TLA+ release](https://github.com/tlaplus/tlaplus/releases/tag/v1.7.4)

```sh
java -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -workers 1 -metadir "$(mktemp -d)" Queue
```

Two groups share one lane and an independent build shares the one executor
slot. Each group starts `waiting` and holds no graph. `Prepare` moves the
head of the lane to `queued` only while no other group holds the lane, and
it records the head as the group's expected base. `Refuse` ends the wait
as `unprepared` and frees the lane. A queued group whose action has not
failed, or a landing group, holds the lane. Each run has at most two attempt
generations.

`Claim` leases the slot and starts a new generation. `Expire` models the
core's `expire`: a lease past its deadline returns the action to pending,
or fails the run at the last attempt and skips its remaining actions. A
clock reading supplies no fencing evidence, so the expired worker keeps its
custody and can still deliver a receipt later. `Accept` takes a receipt only
for the live generation, so a receipt from an expired generation stays
unusable. `RejectLive` is a worker rejection of the live generation and also
skips the run's remaining actions. Worker completion and receipt acceptance
are separate events, and lost replies and controller restarts may stutter at
any point.

A group with a proof can start landing, which creates a durable intent. The
Git update succeeds only while the head still equals the group's base, so an
external writer that advanced it blocks the group. `Reconcile` resolves an
intent as landed or blocked, and `Deny` models a provider policy refusal
before any push. The claim and landing transitions assume linearizable
durable writes.

The invariants are:

| Invariant | Meaning |
| --- | --- |
| `Capacity` | One lease per slot and at most one live lease. |
| `Fresh` | A proof exists only for a generation that was live on acceptance. |
| `Exact` | An intent, the head, and each landed group rest on a proof of the live generation. |
| `OneWrite` | An intent mutates the target at most once. |
| `WaitingIdle` | A waiting group never builds. |
| `Skips` | An action is skipped exactly when its run failed. |
| `OneHolder` | At most one group holds the lane. |
| `Ordered` | Groups are prepared in queue order. |

TLC explored 600,781 generated states, 109,896 distinct states and depth 36
with no violation, and `make model-check` exited 0. Each of the following
mutations produced a counterexample in a separate run. Removing the capacity
guard in `Claim` violated `Capacity`. Removing the generation guard in
`Accept` violated `Fresh`. Removing the base guard in `GitCAS` violated
`OneWrite`. Removing the lane guard in `Prepare` violated `OneHolder`.
Removing the skip on a failed run violated `Skips`.

The model checks bounded safety. Consensus internals, hash verification, Git
ancestry after subsequent advances, unbounded workloads, retention, and
liveness require separate evidence. The simulation covers retention and the
post-heal liveness of every run.

Run `gleam test` in `packages/core` for the real-core simulation. Six fixed
Park–Miller seeds drive 1,000 events each. The harness delays controller
snapshots, loses or replays polls, reorders stored deliveries, advances a
competing ref, and separates Git mutation from recording its outcome. Focused
cases cover an uncertain worker, a lapsed lease, a poison action, preparation
order, and recovery of a successfully applied intent.
