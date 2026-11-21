# Current handoff

**2026-11-21**

The product decisions are agreed. Gantry owns a native action graph. Agents
can run declared targets and restricted ad hoc actions with structured
results. Controllers share a durable queue and executor pool with automatic
takeover. GitHub submit lands the exact tested integration commit where
the target rules permit it.

The [design note](design-notes/central-build-submit-queue.md) defines the
agent loop and implementation slices. The
[architecture](architecture/build-and-submit.md) proposes Khepri/Ra for
shared authority and Loom's standalone executor as the first execution
seam to test.

The next implementation decision depends on the
[verification proposal](design-notes/depth-signoff.md). Start by proving
whether the Loom executor can stage pinned inputs and preserve a durable
attempt across controller takeover. Follow with the native graph prototype
and the transaction model for shared capacity and submission intent.

Initial pre-interview experiments in the local workspace explore Gleam,
Loom lint, and SQLite. SQLite fits local ledgers or test fixtures. The shared
queue design uses a quorum-backed store.
