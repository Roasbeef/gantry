# Gantry runs actions on its own Docker worker

**Status** · Accepted, recorded after the fact · 2026-11-24

The [build and submit design](../architecture/build-and-submit.md) planned to
reuse Loom's executor, and Gantry shipped with its own worker instead. This
record states that decision so the next reader does not look for an executor
integration that is not there. The reasons come from the design notes and the
code. No head-to-head comparison with Loom's executor was run.

## Decision

Gantry executes actions with `gantry/worker`, a Gleam program that pulls
leases over the controller's HTTP protocol and runs each action in Docker.
For every attempt the worker stages the verified source and dependency
archives, creates a tmpfs volume, runs the action in a container with no
network, all capabilities dropped, a read-only root, an unprivileged user,
and per-slot CPU, memory, process, file, and `/tmp` limits, and reads the
declared outputs through a second read-only container. A SQLite journal
records the assignment, a possible-start marker, and the result, so a restart
or a lost reply never runs an action twice from the same slot.

The controller does not depend on Docker. A worker that implements
`/v1/claims`, `/v1/blobs`, and `/v1/results` is interchangeable with this one.

## Why

Loom's executor ledger is keyed to session effects, and its pool placement
counts resident sessions per orchestrator. Gantry needs global action leases
across controllers and source snapshots that exist without a session. The
design named a standalone-executor interop proof as the first thing to run
and listed what it would show: two real hosts, an immutable input tree, a
declared command, a fetched result, and native process retirement on cancel.
That proof has not been done. Shipping a working queue needed an executor
now, and a small worker that speaks the queue's own protocol was the shortest
path to one.

Docker also gives the cache key something to hold. The image digest is part of
every action's recipe, so a change of toolchain is a change of key, and
`--network=none` with a pinned image makes an action's inputs the declared
archives and nothing else.

## Costs

The sandbox is Docker's, not Loom's jail. Lanes that need user namespaces
(for example a nested `bwrap`) cannot run under `--cap-drop=ALL`, and the
default process limit once broke BEAM builds on many-core hosts, which
`GANTRY_WORKER_PIDS` now raises. Cancellation, workspace overlays, and
resource reservations are not built. Workers need Docker, so macOS hosts are
out of scope.

## What would change it

Revisit this when a Loom executor can pass the interop proof above against the
controller's lease protocol, and either its sandbox runs lanes that Docker
cannot or its placement removes the per-slot sizing that operators do by hand
today. Re-open it as well if a per-repository sandbox policy proves too
costly to add to the Docker worker. Record the outcome as an addendum here.

## Addendum · 2026-11-25 · macOS hosts can run a worker

The cost above, that macOS hosts are out of scope, did not hold up. The worker
does nothing Linux-specific: it drives the Docker CLI and bind-mounts input
archives from its own directory, and Docker Desktop shares the home directory
with its VM. A laptop now serves two slots in the fleet's `linux` pool, as
the macOS release running natively under launchd.

Two conditions came with it. An Apple Silicon host is arm64, so a pool that
mixes it with amd64 hosts must pin each image to one platform's manifest
digest. The recipe holds the digest but not the platform, so a
multi-platform index would store different outputs under one key. Docker
Desktop then emulates the amd64 image. The second condition was a bug:
Docker prints a platform warning ahead of the container ID, so the worker now
reads the ID from the last line of the output.
