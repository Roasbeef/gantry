# Khepri owns queue decisions

**Status** · Accepted for the initial deployment · 2026-11-21

A ready claim, generation, capacity reservation, and dispatch intent must
commit together. A local mailbox or a broker delivery may carry a wakeup.
A replacement controller needs enough committed information to reconcile
the exact attempt after losing that wakeup or its reply.

The Beefstack council selected Khepri/Ra as the transactional authority.
Three independent Astra 6.2 seats and the judge ranked it ahead of a
queue-specific Ra state machine and RabbitMQ quorum dispatch with a
separate transactional database. Khepri reuses the quorum, conditional
write, and ownership patterns already exercised in Loom. The first
Gantry store deliberately uses one bounded snapshot CAS so a claim and
its capacity hold share a clear commit boundary.

The strongest alternative is a Ra state machine with maintainable ready
and eligibility indexes. Profiling should first test an indexed, batched
Khepri layout. Reconsider the queue-specific state machine if the Khepri
implementation develops a sustained backlog or misses a proposed one
second p99 ready-to-dispatch target when eligible capacity is free at
100 actions per second across 100 repositories. Compare both on the same
hardware. Require zero duplicate admissions, stale result acceptances,
and overlapping submission intents when injecting leader loss, lost
worker replies, and late completions. These are performance targets.

RabbitMQ quorum queues can supply replicated dispatch with acknowledgements.
That option also requires the broker, state store, and an outbox
reconciler. Keep dispatch on the worker API until measured demand
justifies the extra recovery boundary.

[Beefstack council](https://github.com/Roasbeef/beefstack/blob/71134453b93d1f946203398ee8a8ebd739849e37/skills/council/SKILL.md) ·
[Loom Khepri ownership](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/docs/architecture/directory.md)
