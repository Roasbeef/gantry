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
   the sum of their limits within the host.
9. **Verify.** Run an uncached action on a repository in the pool and check
   `.work[].step.lease.worker` in `gantry watch RUN_ID`. Fetch its log with
   `gantry blob`. If several slots can claim the action, use a smoke pool.

The local profile made by `gantry init --local` has one slot in the pool
`local` and runs its controller without a GitHub token. A repository added to
its `controller.toml` therefore needs `pool = "local"` and an absolute
`local_remote` path to a bare Git repository, because the controller cannot
authenticate to GitHub. Edit the file while the controller is stopped.

## Recovery

### A worker is lost

A lease carries a deadline: the claim time plus the action's `timeout` plus
150 seconds. Nothing renews it. Every claim from any slot first expires the
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
result, or reports `worker interrupted before recording outcome` for an
action that may have started and never recorded one. Keep the worker ID and
directory together. A second worker on the same directory exits because the
journal's SQLite lock is held. A directory bound to another ID is refused.
A managed profile (from `gantry worker setup`) also refuses to start when its
journal is missing or has no identity, since an action could have started.
Use a fresh profile and slot ID in that case, and let the old lease expire.

### The snapshot reaches 4 MiB

The queue is one snapshot with a 4 MiB ceiling. A mutation that would exceed
it is refused with HTTP 500 `queue snapshot exceeds 4 MiB`, so new runs stop
being admitted. The reconciler on each controller trims finished runs and
proofs to `[retention]` once a minute (`keep_runs` 200 and `keep_proofs` 1000
by default). Runs that are not finished are never dropped, so a ceiling hit
means either the bounds are too high for your run size, or too many runs are
active or waiting. Lower `keep_runs` and `keep_proofs` in `controller.toml`,
restart the controllers one at a time (the file is read at startup), and wait
a minute for the next pass. Dropped runs lose their status, but their cached
proofs remain reusable until `keep_proofs` drops them. The
[controller benchmark](controller-load.md) shows cost per operation rising
with snapshot size, well before the ceiling.

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
