# Handoff

This file is where a fresh session starts. It says where the tree stands
against its plan, what to work on next, what was ruled on already, and what
is open on purpose. It is rewritten at the end of each body of work and is
not appended to. [Tour of the code](guide/tour.md) ·
[Status](architecture/runtime.md#status)

**Baseline.** Branch `claude/project-review-refactor-0d0088` at `8c84edf`
(2026-11-25), ahead of `main` at `f4cc695`. At that commit `make check` exits 0
(37 core tests on BEAM and JavaScript, 129 server tests, Loom lint with 0
errors and 3 warnings). The 1,000-seed `sweep` reports 0 safety and 0 liveness
violations. On a Linux host (Ubuntu 24.04, 4 vCPU) the release,
install, and `make e2e` exit 0 with 9 checks passing, and `make model-check`
exits 0 with 109,896 distinct states. The previous edition of this file was
carried forward from earlier slices, and several of its claims no longer held.
They are named under
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
the hand-checked interrupt behaviour of `gantry local start`. `make e2e` needs Linux and Docker; the
baseline above records the run on the controller host.

## What to do next

The slices below are ordered by what the measurements in this series say
binds first. Each names its measured payoff, its exit, and the property that
must not regress. The numbers come from the depth run recorded in
[controller load](controller-load.md) and the Loom lane probes described in
the third slice.

### Ordered slices

1. **Re-measure the controller with retention in place.** The offered-rate
   sweep predates retention, and its 600-retained-run cell fell to 1.3 to 1.7
   actions per second at a 563 KiB snapshot. **Exit:** the same cells (10, 15,
   and 25 actions per second; one and three voters; 8 and 32 slots; 100
   repositories) from a named commit, run with `gleam run -m gantry/bench`.
   **Guard:** the benchmark's own proof and artifact re-read. **Cut:** no code
   change.
2. **Build the indexed, batched Khepri layout.** ADR 001's reconsideration
   trigger is met: every cell at 25 actions per second either fell behind the
   offered rate or exceeded 1 s p99 ready-to-dispatch, and CPU per operation
   grew from 12 ms at a 31 KiB snapshot to 52 to 75 ms at 94 to 141 KiB because
   each change rewrites and replicates the whole snapshot. Put each run under
   its own key with a small ready and lane index, so a claim and its
   reservation still commit in one transaction. **Exit:** at 100 actions per
   second across 100 repositories, ready-to-dispatch p99 under 1 s on the same
   host, and drain at 10 actions per second unchanged with 1,000 retained runs.
   **Guard:** the TLA model and both simulations with 0 violations, the
   planted-mutation checks in [queue verification](queue-verification.md),
   and `make e2e`. **Cut:** no custom Ra state machine unless the indexed
   Khepri layout misses the exit.
3. **Let a trusted repository ask for a wider sandbox.** Real Loom lanes run
   on the 32-core worker host under the worker's exact flags: `static` and `mid` pass; the
   `fast`, `conformance`, and `client` lanes fail, mostly because Loom's own
   `bwrap` jail cannot create user namespaces under `--cap-drop=ALL`, plus
   tests that write outside `/work`. Loom's jail and self-test lanes cannot pass
   at all.
   Write the design note first: what a repository may request (user
   namespaces, a seccomp profile, a delegated cgroup, or a microVM), who
   approves it in `controller.toml`, and how an untrusted repository keeps the
   current flags. **Exit:** the note is accepted, then the Loom `fast` and
   `client` lanes pass under the approved profile. **Guard:** an action in a
   repository without the profile still runs with `--cap-drop=ALL` and no
   network. **Cut:** no change to untrusted defaults.
4. **Stage Git metadata when an action needs it.** Gantry stages a `git
   archive` tree, and "repository metadata query failed" was the most common
   client error, 105 occurrences across two shards. Let a declared action receive the commit's
   metadata (a shallow `.git` or the values it reads), counted in its key.
   **Exit:** those client tests pass. **Guard:** cache keys change when the
   metadata the action declares changes, and only then.
5. **Move inputs larger than one blob.** Loom's source tree is 87.5 MiB
   against the 64 MiB blob limit, and the `conformance` lane's package closure
   is 65.7 MiB, so whole-tree lanes cannot be staged. Chunk or stream input
   archives. **Exit:** the Loom `static` and `conformance` lanes stage and run.
   **Guard:** digest and length checks on every chunk, and the existing blob
   tests.
6. **Write Loom's `gantry.json` and run it across hosts.** Loom's ten most
   recent green CI runs give 114 minutes of Linux lane work with a 20-minute
   critical path, and no lane is more than 14% of the work, so the action
   graph is not what limits speed. Six to eight four-CPU slots reach the
   floor. Cut the manifest along the CI lanes, then run it with the
   controller on its own host and slots on the 32-core worker host. **Exit:** makespan
   within 1.15 times max(critical path, total work divided by slots).
   **Guard:** the same pass and fail per lane as Loom's CI at that commit.
   Depends on slices 3 to 5.
7. **Deploy the first fleet.** The gateway and one controller on
   a four-vCPU controller host, worker slots on the 32-core worker host, and the laptop's Docker as
   an optional worker running the Linux release in a container with the
   Docker socket mounted (untested; the worker directory must have the same
   path inside and outside the container, because input archives are bind
   mounts). **Exit:** a Loom group lands through the gateway. Add a second
   and third voter for failover only when there are three machines that stay
   up. **Status (2026-11-24):** the gateway, controller and four slots are up
   at 10fd0ef. The gateway is `tailscale serve` on
   the controller host's tailnet HTTPS name, in front of `gantryd` on loopback
   (systemd unit `gantryd`, files in `~/gantry-fleet`). The worker host runs the
   slots `worker-01` to `-04` as user units `gantry-worker@NN`, each with
   4 CPUs and 3 GiB, in pool `linux`. The fan-out fixture `fleet/fanout`
   (eight 20-second shards and a collector) passed in 66 s through the
   gateway, with four containers running at once in each of two waves; the
   floor is about 40 s, and each wave added about 7 s for collector start,
   cleanup and the poll gap. The worker host's `/etc/resolv.conf` bypasses
   MagicDNS, so the slots resolve the gateway through `ERL_INETRC`
   (`~/gantry-fleet/inetrc`) until that host's DNS uses Tailscale. The Loom
   group and the laptop worker are still open.
8. **Schedule beyond first-fit.** Today each slot polls and takes the oldest
   ready action in its pool, one action per slot. Add fairness across
   repositories, then one worker process with several slots and CPU and
   memory accounting instead of one process per slot. **Exit:** with two
   repositories admitted at once, both make progress within one dispatch
   round. **Guard:** one lease per slot, in the model and the simulations.
9. **Smaller follow-ups found in review.**
   - Bind a worker credential to its pool as well as its ID.
   - Let an attempt interrupted after `docker start` lapse and be reassigned
     instead of recording a failure.
   - Scale Git's 120 s deadline for a first mirror fetch.
   - Give the churn simulation an oracle that tells a wrongly rejected result
     from a poison action. Both now end as an expired run.
   - Pilot protected-branch rules on a disposable repository
     ([integrating](integrating.md#check-a-live-deployment)).
   - Collect unreferenced blobs and bundles.

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

- **Indexed queue layout.** Designed in ADR 001, unbuilt. It is slice 2.
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
