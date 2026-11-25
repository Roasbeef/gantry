# How work is spread across machines

Gantry has no scheduler process. Workers pull work, and the queue decides in
one pure function (`queue.claim`) which action, if any, a polling slot gets.
This page says what that function does, what it leaves out, and what that
means when you add machines.
[Runtime architecture](architecture/runtime.md) · [Tour](guide/tour.md#5-a-worker-claims)

## The rule

A slot is one running `gantry-worker` process with its own worker ID, pool,
and journal directory. While idle, it posts `{worker, pool}` to
`/v1/claims`, waiting 0.25 s to 2 s between empty answers (the delay grows
over the first two polls and carries jitter, `worker.poll_delay`). The
controller answers with the first action that fits, chosen like this:

1. Lapsed leases are expired first (`queue.expire`), so an action whose
   worker went away can be handed out in the same poll.
2. If this worker ID already holds an active lease, the same assignment comes
   back. A repeated poll never costs a second action.
3. Otherwise the queue walks runs in the order they were admitted. In each
   run it takes the first `Pending` action whose pool equals the slot's pool
   and whose `deps` and `after` prerequisites have all passed or been reused.
4. If a proof for the same repository and input key already exists, that
   action becomes `Reused` on the spot and the scan continues. Otherwise the
   action gets a lease with a fresh serial and the poll returns it.

That is first-fit in admission order. The oldest run with eligible work always
goes first, so a large run admitted early can hold every slot in its pool
while later runs wait. Nothing balances across repositories or runs, and
nothing considers where a source archive or an earlier output already lives.

## What a slot is worth

Capacity is the number of slots. A slot runs one action at a time, and the
controller never learns how big the host is. The worker settings
(`GANTRY_WORKER_CPUS`, `GANTRY_WORKER_MEMORY_MIB`, `GANTRY_WORKSPACE_MIB`,
`GANTRY_WORKER_PIDS`, `GANTRY_WORKER_NOFILE`, `GANTRY_WORKER_TMP_MIB`) only
become `docker create` flags for that slot's containers. They are not
advertised, reserved, or checked against the host, so two slots with
`GANTRY_WORKER_CPUS=16` on an 8-core machine both start.

To use a big machine you run several slots on it, each with its own ID,
directory, and token registered as a `[[worker]]` entry. Size the slots so
their combined limits fit the host. The
[add-a-machine checklist](operations.md#add-a-machine) has the steps.

## Where parallelism comes from

Independent actions of one run spread across slots, because each poll can
lease a different ready action. A single action never splits. A repository
whose manifest holds one `make check` action uses one slot at a time, however
many slots exist, and the speedup from a second machine is zero for it.

So parallelism is a property of how the repository's `gantry.json` is cut
into actions. The ceiling for one run is the width of its graph: the most
actions that are ready at once. Actions connected by `deps` or `after` run
one after the other. Narrow `inputs` also let unchanged actions be reused
across commits instead of rerun. [Declaring a graph](integrating.md#declare-the-graph)
covers the manifest fields.

## Pools

A repository registers one pool in `controller.toml`, and admission copies it
into every task of the run (together with the image). A slot claims only tasks
of its own pool, so a pool is the unit of heterogeneity: put slots with a GPU,
a different architecture, or a larger disk in their own pool and register the
repositories that need them. Moving a repository to another pool changes only
runs admitted afterward. Keep slots in the old pool until its runs finish.

## Submission lanes

A lane is a repository and target branch. A submission is admitted as
`Waiting` with its pinned PR heads and builds nothing. The reconciler offers
the head of each free lane for preparation, which builds the candidate on the
branch tip as it is then. A `Queued` run (not failed) or a `Landing` run holds
its lane, so the next group waits until the first lands, is blocked, or fails.
Candidates for one branch therefore build one after another, and each is built
on the commit the previous group landed. Plain builds (`gantry run`) hold no
lane and compete only for slots.

## What is not built

There is no load-aware placement, fairness or quota across repositories,
priority, resource reservation, data locality, or advertised host capacity.
The design documents describe some of these as targets (see
[the status page](architecture/runtime.md#status)). If one repository should
not starve another today, give each its own pool with its own slots.
