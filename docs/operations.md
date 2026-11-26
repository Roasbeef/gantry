# Operate a deployment

Two things operators do after the first install: add a machine, and recover
when something breaks. The mechanisms behind each are in
[the runtime architecture](architecture/runtime.md), and the
[runbook](running.md) has the full setup of controllers and workers.

## Add a machine

A machine joins as one or more worker slots. Each slot is a `gantry-worker`
process with its own ID, token, and journal directory. Controllers need a new
`[[worker]]` entry for it and read those entries at startup.
[How slots share work](scheduling.md)

1. **Install the release** on the Linux host (`make install`, or unpack the
   release archive) and check `gantry-worker --version`. The service user
   needs Docker access, `env`, `kill`, and `realpath`.
2. **Pre-pull images.** Pull each digest-pinned action image that the pool's
   repositories register (`image` in `controller.toml`), and the collector
   image `alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f`.
   The worker exits at boot with the exact `docker pull` command if the
   collector is missing, and it never pulls on its own (`--pull=never`).
3. **Pick the pool.** `GANTRY_POOL` must equal the `pool` of the repositories
   the slot should serve. A slot never claims work from another pool.
4. **Choose a unique worker ID and a token.** The ID is one path component
   and must be unique across the deployment. Mint the token with
   `openssl rand -hex 32` and take its digest with
   `printf '%s' "$token" | sha256sum | cut -d ' ' -f 1`.
5. **Register it.** Add `[[worker]]` with `id` and `token_sha256` to
   `controller.toml` on every controller, then restart the controllers one at
   a time, waiting for `/ready` between restarts. A worker with no entry gets
   401.
6. **Point it at the gateway.** `GANTRY_ENDPOINT` takes one or more HTTPS
   origins. The gateway must pass the `Authorization` header and answer
   `GET /v1/worker/ready`.
7. **Set up and start.** `gantry worker setup https://gantry.example POOL`
   mints an ID and token and saves them in the slot's profile. Until the
   controllers list the worker it fails with `auth_failed` and the exact
   `[[worker]]` entry to add. Rerun it after the restart to check Docker and
   authenticated readiness. Then
   `gantry worker start` runs it in the foreground for your supervisor.
   Without the CLI profile, export `GANTRY_WORKER_ID`, `GANTRY_POOL`,
   `GANTRY_ENDPOINT`, `GANTRY_WORKER_TOKEN`, and `GANTRY_WORKER_DIR` and run
   `gantry-worker`.
8. **Size the slot.** `GANTRY_WORKER_CPUS`, `GANTRY_WORKER_MEMORY_MIB`,
   `GANTRY_WORKSPACE_MIB`, `GANTRY_WORKER_PIDS`, `GANTRY_WORKER_NOFILE`, and
   `GANTRY_WORKER_TMP_MIB` become Docker flags for that slot only. For
   several slots on one host, give each its own ID and directory and keep
   the sum of their limits within the host. A slot in a pool whose
   repositories use `sandbox = "userns"` also needs
   `GANTRY_WORKER_USERNS_SECCOMP` ([runbook](running.md)), and that pool
   belongs on a host with no strict repository's slots. If its actions run
   their own cgroup-limited sandbox, give each slot a cgroup base in
   `GANTRY_WORKER_USERNS_CGROUP` and a `cgroupfs` Docker daemon in
   `DOCKER_HOST`, as the runbook describes.
9. **Verify.** Run an uncached action on a repository in the pool and check
   `.work[].step.lease.worker` in `gantry watch RUN_ID`. Fetch its log with
   `gantry blob`. If several slots can claim the action, use a smoke pool.

The local profile made by `gantry init --local` has one slot in the pool
`local` and runs its controller without a GitHub token. A repository added to
its `controller.toml` therefore needs `pool = "local"` and an absolute
`local_remote` path to a bare Git repository, because the controller cannot
authenticate to GitHub. Edit the file while the controller is stopped.

## Watch the fleet

Every controller serves a dashboard at `/ui`. It polls
[`GET /v1/fleet`](api.md#the-fleet-snapshot) every two seconds and shows
each pool's ready actions against its busy and free slots, each slot's
lease against its deadline, every retained run with its graph and a line
saying why it is or is not moving, and the chosen action's lease, timing,
and log.

Set `GANTRY_VIEW_TOKEN` (32 bytes or more) in the controller's environment
and paste that token into the page. It reads and cannot admit work. Give a
slot a `host` label in its `[[worker]]` entry to show which machine holds a
lease. A slot's pool and last poll are what the controller behind the page
has served since it started. In a three-voter quorum a slot that polls
another voter reads as unseen there, though its leases still show, because
leases are queue state. [Design note](design-notes/dashboard.md)

## Recovery

### A worker is lost

A lease carries a deadline: the claim time plus the action's `timeout` plus
600 seconds, which covers collecting, journaling, and uploading outputs after
the action exits. Nothing renews it. Lease times are wall-clock seconds taken
on whichever controller serves the poll, so keep the controllers' clocks in
sync with NTP: a clock step forward larger than that slack expires live
leases. The slack also sets how long a lost worker holds its action: the
action is reassigned 10 minutes after its timeout, a poison action takes three
such lapses before its run fails, and a submission's lane stays held in the
meantime. A repository removed from `controller.toml` while groups wait on it
leaves them waiting, and the reconciler logs an error each pass; register a
repository on every controller before anything is submitted to it. Every claim from any slot first expires the
leases past their deadline. An expired action goes back to `pending` with one
more attempt, and the next eligible poll can lease it to another slot. The
third lapse fails the run: the action's step becomes `expired`, the run's
other pending actions become `skipped`, and `gantry watch` reports phase
`failed`. No operator step is needed in between.

Two consequences to plan for. An action can have run, or half run, on the lost
machine before it is leased again, so actions with effects outside the
sandbox should tolerate a repeat. And a slow action that outlives its deadline
is treated as lost: its result gets 409 once the lease moved on, and the
worker drops it. Set the manifest `timeout` for the slowest legitimate run.
A result that arrives after the deadline but before any claim has expired the
lease is still accepted.

To replace a machine for good, start a new slot with a new ID. Reusing the lost ID on a fresh journal is a hazard, because a poll under
that ID returns the lease still recorded for it, and the action then runs
again while the old machine, if it is alive, may still be running it.

### A worker restarts or loses a reply

Nothing to do. The journal keeps the assignment, a possible-start marker, and
the recorded result until the controller answers 200 or 409. A restart
cleans up Docker resources under the attempt's name and publishes the saved
result, or reports the attempt `interrupted` when the action may have
started and never recorded an outcome. The controller treats an interrupted
attempt as a lease that lapsed: the action goes back to `pending` with one
more attempt and runs again on the next eligible poll, and only the third
lapse or interruption fails the run, with step `expired`. Keep the worker ID and
directory together. A second worker on the same directory exits because the
journal's SQLite lock is held. A directory bound to another ID is refused.
A managed profile (from `gantry worker setup`) also refuses to start when its
journal is missing or has no identity, since an action could have started.
Use a fresh profile and slot ID in that case, and let the old lease expire.

### Drain a worker

Send the worker SIGTERM, as `systemctl stop` or a restart after
`make update` does. The worker stops claiming and lets the action it holds
finish, records and publishes the result, logs `gantry worker: drained`,
and exits 0. An idle worker exits within one poll, about 2 s.

The drain deadline is `GANTRY_WORKER_DRAIN` seconds, 60 by default. An
action still running at the deadline is given up: the worker logs
`drain deadline passed, releasing`, removes the container, reports the
attempt `interrupted`, and exits. The controller reassigns the action at
once, and the attempt counts toward the bound of three. If no controller
answers, the report stays in the journal and the next start of the slot
publishes it; if the slot never returns, the lease lapses at its deadline
instead. A second SIGTERM during the drain is ignored.

Under systemd, give the unit `KillMode=mixed`, so only the worker's VM
receives SIGTERM, and a `TimeoutStopSec` longer than the drain deadline
plus at least 15 s for cleanup and the report, more if Docker is slow to
answer. With the default
`KillMode=control-group`, the Docker client is signalled too, and it
forwards the signal into the container, which ends the action before the
drain can let it finish. A stop that SIGKILLs the worker skips the drain;
the next start reports the attempt `interrupted`, as after any crash.

### Upgrade across a queue format change

Releases up to `6a561d4` keep the queue as one snapshot with no format
version, and each decodes only the step kinds and fields it knows. A newer
release reads an older snapshot, but an older one refuses a newer one: it
answers requests that read the queue with 400 `invalid durable queue
snapshot`. The release after `f4cc695` was such a change, with `skipped` and
`expired` steps, attempt counts, and the proof cache.

The indexed layout names its format. The key `format` holds `indexed-v1`,
written in the same transaction as the layout, and a voter checks it at boot
(`store.upgrade`). A name it does not know stops the voter with `unknown queue
format <name>`, so a rollback past a later format change fails by name and
not by a decode error.

Across a format change, upgrade every voter together:

1. Stop admitting work and let the queue go idle. A controller can be
   replaced while a worker keeps running, and the worker delivers its
   result to the new release.
2. Stop all voters and back up each `data_dir/queue-ra`.
3. Install the new release on every voter and start them all.

Rolling back after the new release has written means restoring those
backups, which loses whatever was admitted since. An upgrade drill on
2026-11-24 from `f4cc695` to `10fd0ef` showed this: the controller upgrade
read every earlier run, the rollback refused the snapshot, and the upgraded
worker reopened the old journal but failed its in-flight action. A worker
now drains on SIGTERM and reports an action it could not finish as
`interrupted`, which is reassigned rather than failed
([drain a worker](#drain-a-worker)).

### Upgrade from the single-snapshot release

The indexed layout is the first release with a format name. Voters of the two
releases cannot share a cluster, so follow the steps above. The first voter to
open its replica finds no `format` key, imports the old snapshot into the
layout in one transaction, and then replaces the snapshot with bytes the
earlier release cannot decode, so an earlier release started on the migrated
directory refuses it instead of creating an empty queue beside it. The other
voters find `indexed-v1` and start. A boot that stopped between the import and
the seal finds the layout and an unsealed snapshot, and seals it.

A drill on 2026-11-26 checked this boundary on one controller, from `6a561d4`
to the indexed layout, with one worker that kept running across the change:

| Step | What happened |
| --- | --- |
| `6a561d4` admits run 1, which passes, then runs 2 and 3 | Run 2's first action is active on the worker, and run 3 is pending |
| Stop the controller, start the indexed-layout release on the same `data_dir` | It imports the snapshot and is ready in 2 s. Run 1 reads back as passed, and run 2 still shows its action active |
| The worker reports the in-flight action | Accepted. Runs 2 and 3 pass, and a new run 4 passes |
| Start `6a561d4` again on the migrated `data_dir` | `/health` answers 200, and reading a run answers 400 `invalid durable queue snapshot`. It serves no queue |
| Start the indexed-layout release again | Ready, and all four runs read back as passed |

### The queue is full

The queue holds at most 10,000 runs at once, finished or not. A new run past
that is refused with HTTP 503 `the queue holds the most runs it accepts`, so
agents retry later. The reconciler on each controller trims finished runs and
proofs to `[retention]` once a minute (`keep_runs` 200 and `keep_proofs` 1000
by default, in batches of 250). Runs that are not finished are never dropped,
so a full queue means too many runs are active or waiting, or `keep_runs` is
high for your admission rate. Check that workers are claiming, or lower
`keep_runs` and `keep_proofs` in `controller.toml`, restart the controllers
one at a time (the file is read at startup), and wait a minute for the next
pass. Dropped runs lose their status, but their cached proofs remain reusable
until `keep_proofs` drops them. The cost of one operation no longer grows with
the number of retained runs, so the bound limits memory and not throughput
([controller benchmark](controller-load.md)).

### A landing is stuck

A group in phase `landing` holds its lane. The reconciler retries the intent
after 1 s, then 2 s, doubling to 60 s, and logs each error. Transport faults,
an unknown GitHub merge state, and failed pushes stay open, since the push
may or may not have applied. Read the controller log for the cause and fix it
(token, network, Git remote). Definite outcomes resolve themselves: the
candidate already on the branch is `landed`, a refusal by GitHub policy while
the branch still sits at the base is `blocked` with `policy_denied`, and a
branch that moved elsewhere is `blocked` with `target_advanced`. There is no
cancel route. If the cause cannot be fixed, advancing the target branch by any
other commit makes the next tick resolve the intent as `target_advanced`,
which frees the lane. Submit the group again under a new run ID.

### A controller is lost

With three voters the others keep serving, and workers fail over to their
other origins. Restart the voter with the same Erlang node name and the same
`data_dir`, and it catches up. It refuses to start if its marker file names
another node or if Ra lost its server (`missing durable member`), because
serving an empty queue would be worse than being down. Restart one voter at a
time and wait for `/ready`.

### Back up and restore the voter data

A voter's state is `data_dir/queue-ra` (the Ra log and the `member` marker).
The blobs and candidate bundles are in `blob_dir` (`objects/`, `git/`), shared
by all voters. `data_dir/mirrors` is a cache and can be deleted. To back up,
stop one voter, copy `queue-ra` and the shared `blob_dir`, and start it
again, so the quorum stays up. Keep `controller.toml`, the role tokens, the
Erlang cookie, and the TLS distribution files with the backup.

Restoring a whole quorum from backups, and replacing a voter whose directory
is gone, are not exercised by the end-to-end gate and have no command.
Gantry does not collect blobs either, so `blob_dir` grows with every run.
[Fleet bootstrap](design-notes/fleet-bootstrap.md#whats-built-and-whats-not)
lists these as unbuilt.
