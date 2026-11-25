# Handoff

This file is where a fresh session starts. It says where the tree stands
against its plan, what to work on next, what was ruled on already, and what
is open on purpose. It is rewritten at the end of each body of work and is
not appended to. [Tour of the code](guide/tour.md) ·
[Status](architecture/runtime.md#status)

**Baseline.** Branch `claude/project-review-refactor-0d0088` at `e13d4d9`
(2026-11-24), 37 commits ahead of `main` at `f4cc695`. Every claim below was
checked against that tree in this pass, or is marked as not checked. The
previous edition of this file was carried forward from earlier slices, and
several of its claims no longer held. They are named under
[what the previous edition got wrong](#what-the-previous-edition-got-wrong).

## Where the tree is

| Area | Where it stands |
| --- | --- |
| Controller and queue | Pinned Git inputs, declared and ad hoc actions, a quorum snapshot with whole-document swap, lease expiry and reassignment (3 attempts), skipped steps after a failure, deferred preparation of waiting groups, retention, typed failure and block reasons |
| Controller API and operations | Per-worker credentials, typed HTTP errors, a persistent Git mirror per repository with per-intent backoff, policy denials that block a run, a supervised listener and reconciler, logging |
| Worker | Result recorded before cleanup, collector preflight, Gun connection reuse with progress timeouts, journal pruned on acknowledgement, SQLite exclusive lock, Weft-run `docker start` with cancel, one port runner, configurable process, file, and `/tmp` limits |
| CLI | Gleam (`gantry/cli*`), no jq or curl at runtime, onboarding (`init --local`, `local start`, `worker setup`) in the same program, schema in `packages/server/priv` |
| Verification | TLA+ model with expiry, waiting, and skipping (TLC: 109,896 distinct states, exit 0), seeded queue simulations (`sweep`, `churn`, `growth`), live gate `make e2e` |
| Throughput | The ADR 001 reconsideration trigger is met. The queue saturates near 20 actions per second on four vCPUs with 100 repositories |
| GitHub | Pilot done on a disposable, unprotected branch. Protected-branch rules are not piloted |
| Documentation | Brought level with the code in this pass, and a tour, an API reference, a scheduling page, and an operations page added |

### What this series changed

The series moved the CLI and onboarding from Bash into Gleam and gave the
admission rules one owner ([ADR 002](adr/002-one-owner-for-request-rules.md)).
It made the core queue enforce leases, which the previous edition and the
model had described but the code did not. It stopped building a group's
candidate at admission, so a group behind another is built on the commit the
first one lands. It bounded the snapshot with retention. In the controller it
replaced the shared worker token with per-worker credentials, classified
failures by type instead of by message text, kept one Git mirror per
repository, and made a policy denial block the run instead of holding the
lane forever. In the worker it recorded results before cleanup, bounded
transfers by progress, and made the sandbox limits configurable. The Node
benchmark became a Gleam module. The new churn simulation
(`packages/core/test/queue_churn_dst.gleam`) and the extended model cover the
new transitions, and each has a mutation that it must fail
([queue verification](queue-verification.md#mutation-checks)).

### What the previous edition got wrong

It said retention and indexed queue metadata both remained open. Retention
is built (`queue.retain`, `[retention]` in `controller.toml`), and the
indexed layout is still open. It listed per-worker credentials only in a
proposal ([fleet bootstrap](design-notes/fleet-bootstrap.md#whats-built-and-whats-not)),
and they have shipped. It said the model covered claim and generation, but
the code had no generation until this series added lease serials with expiry
and the model gained them too. It named Loom executor interop as open work,
and [ADR 003](adr/003-gantry-docker-worker.md) now records that Gantry runs
its own Docker worker and what a proof would need to show. It spread status
across the README, the runbook, and the architecture page, and they disagreed
about the GitHub pilot. They now link to
[one status section](architecture/runtime.md#status).

Not re-checked in this pass, and carried as historical: the Loom pilot
numbers (318 and 319 tests, the landed commit `676951e`), the CLI latency
comparison (about 230 to 340 ms against 7 to 24 ms for the old Bash CLI), and
the hand-checked interrupt behaviour of `gantry local start`. This host is
macOS, so `make e2e` was not run here either. It needs Linux and Docker.

## What to do next

1. **Clear the Loom lint error.** `make check` exits 2 at `e13d4d9`. Format,
   build, and the unit tests pass (core on BEAM and JavaScript, 128 server
   tests), and then `make lint` reports one error-level finding: R21
   case-stanza at `packages/server/src/gantry/worker/custody.gleam:86`, in
   `reopen`, a `case` with no comment above it and no blank line around it.
   It also warns on R9 (`api.require` takes a `Bool`) and R18 (`claim_decoder`
   and `reconcile.on_message` each have one caller). This pass changed no
   code, so the error was already in the tree. **Exit:**
   `make check` exits 0. **Cut:** the three warnings stay unless the fix is
   free.
2. **Measure the current build.** Rerun the offered-rate sweep on a four-vCPU
   Linux host with retention in place ([controller benchmark](controller-load.md)).
   The recorded results predate retention, and the 600-retained-run cell in
   particular should be redone. **Exit:** a table in `controller-load.md`
   with the same cells (10, 15, and 25 actions per second, one and three
   voters, 8 and 32 slots, 100 repositories) from a named commit, and a
   statement of what changed. **Cut:** no code change, and no new cells.
3. **Run the live gates on Linux.** `make e2e` and `make model-check` were not
   run in the documentation pass. **Exit:** both exit 0 from the branch head,
   with the number of cases printed. **Cut:** nothing new is added to either.
4. **Remove stray tracked files.** The repository tracks
   `scratchpad_lint1.py` through `scratchpad_lint7.py` at its root, and two
   `.orig` files (`packages/server/src/gantry/internal/ffi_host.gleam.orig`
   and `packages/server/src/gantry_host_ffi.erl.orig`). They look like
   leftovers from earlier edits. **Exit:** they are gone and `make check`
   still exits 0. **Cut:** no other cleanup in the same commit.
5. **Pilot protected-branch rules.** Use a disposable repository whose target
   has the rules a real deployment would have, and the controller identity
   that deployment will use ([integrating](integrating.md#check-a-live-deployment)).
   **Exit:** a group lands or is refused with a typed reason, and the result
   is recorded next to the earlier pilot.
6. **Decide the per-repository sandbox policy.** The depth run found Loom
   lanes that cannot run under `--cap-drop=ALL` (nested `bwrap` needs user
   namespaces), and a 64 MiB blob cap against a Loom source tree of about
   87.5 MiB. Those findings come from session notes and were not re-measured
   here. **Exit:** a design note that says what a repository may ask for and
   who approves it. **Cut:** no worker change before the note is accepted.

### Ordered slices (pending measurement)

*To be filled by the integrator.* This section will hold the ordered list of
slices after items 1 and 2 above produce current numbers, including whether
and when to build the indexed, batched Khepri layout that ADR 001 names as
the next step. Until then, do not start that work from the older benchmark
results.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Khepri owns queue decisions.** One bounded snapshot with a whole-document
compare-and-swap, until profiling says otherwise. The trigger has fired, and
the next step is an indexed, batched Khepri layout, not a custom Ra state
machine ([ADR 001](adr/001-khepri-owns-queue-decisions.md)).

**One owner for request rules.** `gantry_core/request` decodes and checks every
build and submit request for both the controller and the CLI, and unknown keys
are rejected. Manifest actions keep the lenient decoder
([ADR 002](adr/002-one-owner-for-request-rules.md)).

**Gantry runs its own Docker worker.** Loom's executor is not used until an
interop proof exists ([ADR 003](adr/003-gantry-docker-worker.md)).

**A lapsed lease is reassigned automatically.** After the deadline the action
returns to `pending` with one more attempt, and the third lapse fails the run.
There is no operator retire step. The rule lives in the module comment of
`gantry_core/queue.gleam` and in the model. It has no ADR yet.

**A group is prepared when its lane frees.** Admission pins the heads and
builds nothing, so a later group never builds on a stale base. Same homes as
the previous ruling, and no ADR yet.

**Workers authenticate individually.** The controller holds a SHA-256 per
worker, and the shared worker token is rejected at load. See
`gantry/config.gleam`. No ADR yet.

**The Gleam benchmark replaced the Node driver.** `scripts/bench-controller.mjs`
is gone, and `packages/server/dev/gantry/bench.gleam` is the benchmark.

## Deliberately open

None of these is unfinished work somebody forgot.

- **Indexed queue layout.** Designed in ADR 001, unbuilt. Waits on item 1.
- **Cancellation, workspace overlays, event cursors, resource reservations,
  quotas, and priority.** Described as targets in the
  [design pages](architecture/build-and-submit.md#what-is-built), unbuilt.
- **A cancel route for a stuck landing.** Today the lane frees when the target
  branch moves ([operations](operations.md#a-landing-is-stuck)). Undesigned.
- **Blob and bundle collection.** Unbuilt. `blob_dir` grows with every run.
- **Restoring a voter from backup, and replacing a lost voter.** Unbuilt and
  unrehearsed ([operations](operations.md#back-up-and-restore-the-voter-data)).
- **Fleet commands beyond `init --local` and `worker setup`.** Unbuilt
  ([fleet bootstrap](design-notes/fleet-bootstrap.md#whats-built-and-whats-not)).
- **Placement beyond first-fit.** No fairness across repositories, no
  load-awareness, no advertised capacity
  ([how work is spread](scheduling.md)). Unbuilt.

## How to verify

```sh
make check                                      # format, build, tests on BEAM and JavaScript, Loom lint
make model-check TLA2TOOLS=/absolute/path/to/tla2tools.jar
make e2e                                        # Linux, Docker, three voters, a bare Git remote
scripts/queue-dst.sh sweep 1 1000 128           # seeded simulation, 1,000 seeds
```

Capture each command's exit status directly, and report the cases it ran.
The unit gate does not need Docker. The live gate does, and it uses `jq` and
`curl` as test tooling.

**The Loom lint is part of `make check`.** Several commits in this series
exist only to satisfy its case-stanza and flow-spine rules, so run
`make lint` before committing Gleam changes.

**The agent skill and the CLI's copy are the same file.**
`packages/server/priv/skill/SKILL.md` is a symlink to `skills/gantry/SKILL.md`,
and `make e2e` compares the CLI's output with the file. Edit the target and
leave the link alone.

**The docs cite code by line.** The [tour](guide/tour.md) names a file and a
line for each step. Move code and the citation goes stale, so reread the
tour when a function it names changes.

**A pids limit of 128 breaks BEAM builds on many-core hosts.** The worker now
defaults to 4096 and reads `GANTRY_WORKER_PIDS`. A BEAM action on a large host
may still want `ERL_FLAGS` set to fewer schedulers.

There is no `docs/execution.md` yet. [AGENTS.md](../AGENTS.md) carries the rules
for slices, and the [queue verification guide](queue-verification.md) covers
the simulations.
