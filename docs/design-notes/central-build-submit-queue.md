# An agent build system with a submit queue

**Status** · Product decisions agreed · Architecture proposed · 2026-11-21

Gantry gives an agent a way to follow a change from its working tree to a
build result and, when authorized, to a landed Git commit. An agent can ask
what ran, why an action reran, which dependency blocked a target, and which
artifact or log to fetch. An agent can repeat an isolated action while
another agent builds a different project on the same pool.

## Decisions

| Area | Decision | Consequence |
| --- | --- | --- |
| Build model | Gantry owns a native target and action graph. Bash, Bazel, Ninja, Make, and language tools can run inside actions. | Gantry schedules and caches work at declared action boundaries. A legacy tool can remain responsible for its inner graph. |
| Agent authority | Agents can request declared targets and ad hoc actions in a restricted executor. | Agents get typed failures, logs, and artifacts. Project policy controls resources and isolation. |
| Deployment | Many controllers share one durable queue and a pool of executors. | Any controller can serve an agent and recover work after another controller fails. Executors advertise capacity for actions. |
| Submission | Build an ordered group of PR heads against a pinned base. Push the tested commit when the base still matches and GitHub permits it. | Each source PR can be linked to the actual integration commit. A failed or blocked group has no success record. |
| GitHub integration | A GitHub Actions workflow can hand off trusted admission requests and surface Gantry status. | The executors run on hardware chosen by the operator. Git and the build API are usable without GitHub Actions. |

Bazel separates the action description, content-addressed inputs, execution,
and result cache. Gantry takes those boundaries and makes the reason for a
miss available to the caller. Ninja shows how far a small graph vocabulary
can go with explicit dependencies, downstream invalidation, and limited
pools. Gantry starts with declared edges and adds dependency discovery only
when there is a workload that needs it.
[Bazel Remote Execution API](https://github.com/bazelbuild/remote-apis/blob/main/build/bazel/remote/execution/v2/remote_execution.proto) ·
[Ninja manual](https://ninja-build.org/manual.html)

## The first agent loop

1. Give Gantry a registered repository, an immutable commit, and optionally a
   content-addressed workspace overlay. Inspect the plan or run selected targets.
2. Watch a run by an opaque cursor. If a controller disappears, reconnect to
   any controller and resume from the last cursor. Inspect a typed failure
   and request just the relevant log range or artifact.
3. Reproduce the failed action, try one restricted ad hoc action, or submit a
   repaired snapshot. A retry reports reused prerequisites and gives the new
   work its own attempt identity.
4. A principal with submit permission queues a pinned PR revision. Gantry
   chooses an ordered group for its target branch, integrates their commits,
   and builds the repository's required targets for that exact candidate.
5. After Git confirms the tested commit landed, link it from each original PR
   and reconcile its status. An agent can fetch the group, candidate, result
   evidence, and landing record from one run history.

First-class action graphs, concurrent controllers, executor pooling, and
exact-commit submission belong in the first release. An Actions runner
protocol implementation, Bazel Remote Execution API compatibility, a
general-purpose rules language, speculative merge trains, and cross-project
cache sharing can each be evaluated separately. Start with GitHub as the PR
provider and immutable Git snapshots as the build input.

## Implementation order

| Slice | Done when |
| --- | --- |
| Graph and agent API | A fresh source snapshot produces a plan with stable action keys. A one-file edit reruns exactly the affected work. A failure can be watched, inspected, and replayed through the same API. |
| Distributed control and execution | Two controllers accept and resume requests. Kill one during an active build and finish through the other. Two real executors consume resource reservations from the same pool without overbooking. |
| Git submission | A scratch GitHub repo demonstrates a two-PR group landing exactly the tested candidate. Local fault tests cover a changed base, an ambiguous push, and a source head update. |
| Loom-style sign-off | Source provenance, package contracts, the handoff, and setup instructions agree with a clean tree. `make check`, `make model-check`, and `make e2e` report their own status and count completed cases. |

See the [architecture](../architecture/build-and-submit.md) for the durability,
execution, and Git boundaries. The [Depth proposal](depth-signoff.md) defines
what would falsify the design and how to measure it.
