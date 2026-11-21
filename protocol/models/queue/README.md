# Queue safety model

Run from this directory with Java and the v1.7.4 release artifact (TLC2 2.19).
The jar SHA-256 is
`936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.
[TLA+ release](https://github.com/tlaplus/tlaplus/releases/tag/v1.7.4)

```sh
java -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -workers 1 -metadir "$(mktemp -d)" Queue
```

Two immutable run IDs represent competing tested commits with the same
expected base. Each has at most two attempt generations. Both share one
executor slot. External writers can advance the base. Worker completion and
receipt acceptance are separate events. The durable intent survives Git CAS
until reconciliation. Lost replies and controller restarts may stutter at any
point. An enabled transition can also occur after any number of such failures.
The claim transition assumes linearizable durable writes. Delivery assumes
durable worker admission and deduplication.

`Fence` models a positive physical custody fence which terminates old work
and prevents further admissions of that token. It allows evaluation of a
future reassignment protocol. The initial queue keeps an uncertain reservation
until the worker reports completion. A clock reading supplies no fencing evidence.

TLC explored 2,537 generated states, 1,034 distinct states and depth 21.
Removing the capacity guard in Claim violated Capacity. Removing the generation
guard in Accept violated Fresh. Removing the base guard in GitCAS violated
Exact. Each mutation produced a counterexample in a separate run.

The model checks bounded safety. Consensus internals, hash verification, Git
ancestry after subsequent advances, unbounded workloads, and liveness require
separate evidence.

Run `gleam test` in `packages/core` for the real-core simulation. Six fixed
Park–Miller seeds drive 1,000 events each. The harness delays controller
snapshots, loses or replays polls, reorders stored deliveries, advances a
competing ref, and separates Git mutation from recording its outcome. Focused
cases cover an uncertain worker and recovery of a successfully applied intent.
