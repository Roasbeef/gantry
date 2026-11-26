# Handoff

This file is where a fresh session starts. It says where the tree stands
against its plan, what to work on next, what was ruled on already, and what
is open on purpose. It is rewritten at the end of each body of work and is
not appended to. [Tour of the code](guide/tour.md) ·
[Status](architecture/runtime.md#status)

**Baseline.** Branch `indexed-queue-layout`, whose last code commit is
`7fa0052` (2026-11-25), on top of `main` at `6a561d4`. At that commit
`make check` exits 0 (49 core tests on BEAM and on JavaScript, 134 server
tests, Loom lint with 0 errors and 17 warnings, 3 of them from before this
branch). The queue simulations report 0 safety and 0 liveness violations:
`sweep 1 1000 128`, `swarm 1 10000 128`, `churn 73 128`, `growth 2000`, and
`ops`. On a Linux host (Ubuntu 24.04, 4 vCPU) the release and install exit 0,
`make e2e` exits 0 with all 9 checks, and `make model-check` exits 0 with
109,896 distinct states. The benchmark numbers were measured at `9f273c1`,
and the later commits only reshape lint. The previous edition's claims that
changed are under
[what the previous edition got wrong](#what-the-previous-edition-got-wrong).

## Where the tree is

| Area | Where it stands |
| --- | --- |
| Controller and queue | Pinned Git inputs, declared and ad hoc actions, an indexed Khepri layout (a key per run, small indexes, one transaction per decision), lease expiry and reassignment (3 attempts), skipped steps after a failure, deferred preparation of waiting groups, retention, typed failure and block reasons |
| Controller API and operations | Per-worker credentials, typed HTTP errors, a persistent Git mirror per repository with per-intent backoff, policy denials that block a run, a supervised listener and reconciler, logging |
| Worker | Result recorded before cleanup, collector preflight, Gun connection reuse with progress timeouts, journal pruned on acknowledgement, SQLite exclusive lock, Weft-run `docker start` with cancel, one port runner, configurable process, file, and `/tmp` limits |
| CLI | Gleam (`gantry/cli*`), no jq or curl at runtime, onboarding (`init --local`, `local start`, `worker setup`) in the same program, schema in `packages/server/priv` |
| Verification | TLA+ model with expiry, waiting, and skipping (TLC: 109,896 distinct states, exit 0), seeded queue simulations (`sweep`, `churn`, `growth`) that also replay every operation through the layout and compare, live gate `make e2e` |
| Throughput | One voter holds 100 actions per second across 100 repositories on four vCPUs (ready p99 145 ms), and saturates near 110. Three voters on that host hold 75 ([measurements](controller-load.md#the-indexed-layout-9f273c1)) |
| GitHub | Pilot done on a disposable, unprotected branch. Protected-branch rules are not piloted |
| Documentation | Brought level with the code in this pass, and a tour, an API reference, a scheduling page, and an operations page added |

### What this series changed

It re-measured the controller with retention in place and found the
whole-snapshot store could not hold 10 actions per second at 300 runs. It then
replaced the snapshot with an indexed layout ([ADR 001
addendum](adr/001-khepri-owns-queue-decisions.md#addendum--2026-11-24--the-indexed-layout)).
The core decides each operation against the few keys it reads
(`gantry_core/layout`), the unchanged transitions in `queue` run on only the
runs it selected, and the store commits the resulting plan in one Khepri
transaction that compares every key the decision relied on. The churn
simulation replays each committed operation on a reference store and counts a
difference as a safety violation, and a rival-claim check requires that two
claims issuing leases cannot both commit. A review of the layout found a claim
that could hold one worker to two leases, a claim order the simulation could
not reach, and a refusal read from a lagging replica. Each is fixed with a
test that fails without it. An earlier release's data directory opens under the
new one.

### What the previous edition got wrong

It said the retention fix bounded the snapshot and that the offered-rate sweep
needed only a re-measure. At 300 runs the store with retention fell to 2 to 11
actions per second in every cell, because retention runs once a minute and
keeps 200 runs and 1,000 proofs, and a snapshot costs about 0.95 KiB per run. It
said the 10 to 15 actions per second cells kept pace, which held only while the
snapshot was small (about 100 runs). It counted nine `make e2e` checks without
saying the ninth needs `GANTRY_RELEASE_BIN` pointing at the installed
launchers, and it did not say the result-proxy fixture needs Node.js on the
`PATH`. The host had Node.js only under another session's directory. Those
requirements are now under [how to verify](#how-to-verify). It listed the
indexed layout as designed and unbuilt, and it was built here.

Not re-checked in this pass, and carried as historical: the Loom pilot numbers
(318 and 319 tests, the landed commit `676951e`), the CLI latency comparison
(about 230 to 340 ms against 7 to 24 ms for the old Bash CLI), and the
hand-checked interrupt behaviour of `gantry local start`.

## What to do next

The slices below are ordered by what the measurements in this series say
binds first. Each names its measured payoff, its exit, and the property that
must not regress. The numbers come from the depth run recorded in
[controller load](controller-load.md) and the Loom lane probes described in
the third slice.

### Ordered slices

1. **Find what ended three samples with `ResponseTimeout`.** Three of about 40
   one-voter samples at 100 and 150 actions per second ended with the
   benchmark's 60 s timeout on `POST /v1/runs`, and the controller logged
   nothing. 26 consecutive samples at the same settings passed. The suspects are
   the Git mirror lock in admission (`gantry/git.gleam`), the node-local lock
   in `gantry_khepri_ffi:gated/2`, and the benchmark's own connection pool.
   **Exit:** a cause, shown by a sample that fails on purpose or by a trace of
   the stuck request, and a fix or a documented bound. **Guard:** the
   100-per-second exit in [controller load](controller-load.md#the-indexed-layout-9f273c1)
   keeps its p99 under one second. **Cut:** no new subsystem.
2. **Raise the three-voter ceiling.** Three voters on one four-vCPU host hold
   75 actions per second and miss 100, with the voters at about 240% of 400%
   CPU. Profile it with Pickglass ([controller load](controller-load.md#profiling-with-pickglass-commit-b2ff8cb-for-pickglass))
   to see whether the cost is the replicated transaction function, the three
   copies of every index write, or the counters that two nodes contend on
   (about 190 retries per 3,000 runs). The target is 100 actions per second on
   a host with a core per voter, so measure there too. **Exit:** the measured
   split, and either 100 actions per second on three voters or a rule for the
   host size that gets it. **Guard:** the same simulations and mutation checks.
   **Cut:** no custom Ra state machine unless the split says Khepri's
   transaction is the cost.
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
   group and the laptop worker are still open. The fleet's controller still
   runs the single-snapshot release. Upgrading it follows
   [the upgrade steps](operations.md#upgrade-from-the-single-snapshot-release)
   and was not done here, because that service is live.
8. **Schedule beyond first-fit.** Today each slot polls and takes the oldest
   ready action in its pool, one action per slot. Add fairness across
   repositories, then one worker process with several slots and CPU and
   memory accounting instead of one process per slot. **Exit:** with two
   repositories admitted at once, both make progress within one dispatch
   round. **Guard:** one lease per slot, in the model and the simulations.
9. **Smaller follow-ups found in review.**
   - Bind a worker credential to its pool as well as its ID.
   - Let an attempt interrupted after `docker start` lapse and be reassigned
     instead of recording a failure. The upgrade drill showed that every
     worker restart, including a routine `make update`, fails the runs it
     was serving, so this one is first.
   - Roll a future format change out in two steps, a release that reads both
     formats and then one that writes the new one, so voters can be upgraded
     one at a time. The format now has a name (`indexed-v1`) that a release
     checks at boot, and an unknown name refuses to start
     ([operations](operations.md#upgrade-across-a-queue-format-change)).
   - Scale Git's 120 s deadline for a first mirror fetch.
   - Give the churn simulation an oracle that tells a wrongly rejected result
     from a poison action. Both now end as an expired run.
   - Pilot protected-branch rules on a disposable repository
     ([integrating](integrating.md#check-a-live-deployment)).
   - Collect unreferenced blobs and bundles.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Khepri owns queue decisions.** The queue is an indexed Khepri layout, one
key per run, and a decision commits as one transaction that compares what it
read. The layout met its exit on one voter, so a custom Ra state machine stays
out unless a measurement of the three-voter ceiling says Khepri's transaction
is the cost ([ADR 001](adr/001-khepri-owns-queue-decisions.md)).

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

- **Three voters on one four-vCPU host hold 75 actions per second, not 100.**
  A measured limit, not a design target
  ([measurements](controller-load.md#the-indexed-layout-9f273c1)). The likely
  bottleneck is CPU: three BEAM VMs, the load driver, and Git share four vCPUs
  (the voters used about 240% of 400%), every transaction is applied on all
  three, and the counters that two nodes write conflict about 190 times per
  3,000 runs. Slice 2 measures the split.
- **Ordering across overlapping operations.** A claim reads the ready index
  and then the runs, so a run that becomes ready in between can be passed over
  by one claim. Safety does not depend on it, and the oldest-first order is
  exact when operations do not overlap
  ([ADR 001](adr/001-khepri-owns-queue-decisions.md#addendum--2026-11-24--the-indexed-layout)).
- **Per-pool ready cursor.** A claim lists its pool's `ready` entries and
  retention lists `done`, so each grows with the backlog. The entries are
  tens of bytes, and a head cursor replaces the listing if a backlog shows it.
- **The lock processes are not supervised.** `gantry_khepri_ffi` starts three
  mutex processes with `spawn` and registers them. They release on a crash and
  have not died in testing, and a Weft supervisor would own their lifecycle.
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
GANTRY_RELEASE_BIN=$HOME/.local/bin make e2e   # Linux, Docker, Node.js, three voters, a bare Git remote
scripts/queue-dst.sh sweep 1 1000 128           # seeded simulation, 1,000 seeds
```

Capture each command's exit status directly, and report the cases it ran.
The unit gate does not need Docker. The live gate does, and it uses `jq`,
`curl`, and Node.js (the result-proxy fixture `drop-result-reply.mjs`) as test
tooling. `GANTRY_RELEASE_BIN` names the directory of the installed launchers,
and without it the ninth check, the packaged skill and onboarding, does not run
and `make e2e` still exits 0 with eight.

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
