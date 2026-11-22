# Run Gantry

Gantry workers run actions against immutable Git snapshots. Gantry
supports target plans, declared builds, restricted ad hoc actions,
result polling, artifact and log retrieval, and guarded submission of
ordered PR groups. Controllers share the same replicated queue.

## Build and verify

The pinned toolchain is Gleam 1.19.0, Erlang/OTP 29.0.5, and rebar3 3.27.0.
The local end-to-end check also uses Linux, Git 2.56, Bash, GNU coreutils
and tar, util-linux (`flock`), Docker, curl, jq, and OpenSSL. Node runs
the portable core tests in the JavaScript gate. Docker needs a working
daemon, cgroup CPU and memory limits, and a backend that supports a
bounded tmpfs volume. A rootless worker is preferred.

```sh
make check
make model-check TLA2TOOLS=/absolute/path/to/tla2tools.jar
make e2e
```

To run the same live gate with both installed service entry points, set
`GANTRY_RELEASE_BIN` to the absolute path of the installation's `bin`
directory when running `make e2e`.

The model target verifies the version 1.7.4 release jar by SHA-256.
The [model README](../protocol/models/queue/README.md) documents the
checked invariants and deterministic simulation.

## Build and install a release

Build on Linux for the intended CPU architecture and compatible system
libraries. The build uses the pinned toolchain above and a C compiler and
make for the SQLite native extension.

```sh
make release
make install PREFIX="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
gantryd --version
gantry-worker --version
gantry describe run
```

`make release` builds a host-native Gleam Erlang shipment and uses relx
to package the OTP release, including ERTS and the SQLite NIF. It writes
`build/release/gantry-linux-<arch>.tar.gz`. `make install` builds that
release and installs `gantryd`, `gantry-worker`, and the `gantry` CLI under
`PREFIX/bin`. The default prefix is `$HOME/.local`. Installed hosts need
the system commands for the roles they run. Controllers use Git and GNU
tar, workers use Docker, GNU coreutils, and `flock`, and the CLI uses Bash,
curl, and jq. Python is unnecessary at runtime.

Run `make update PREFIX="$HOME/.local"` from the checkout to build and
install a new release. The installer publishes a complete, immutable
release tree and atomically switches `PREFIX/lib/gantry/current` for
future launches. It retains earlier release trees and records the prior
target in `PREFIX/lib/gantry/previous`. Running services keep using
their original release tree until the operator restarts them through
their service supervisor. For a three-voter deployment, restart
one controller at a time and wait for it to rejoin before restarting the
next. Restart workers with their existing IDs and directories so they
reopen their SQLite journals and recover local custody.

When editing the [worker schema](../packages/server/priv/worker-schema.sql)
or [Parrot queries](../packages/server/src/gantry/worker/sql/custody.sql),
run `make gen-sql` with the SQLite CLI on `PATH`. The target creates a
fresh database from the schema and generates the
[Gleam bindings](../packages/server/src/gantry/sql.gleam), which are
checked in alongside the schema and queries.

## Start a controller

Copy the [controller example](examples/controller.toml) and register
a project. Set three distinct secrets of at least 32 bytes
in `GANTRY_TOKEN`, `GANTRY_WORKER_TOKEN`, and `GANTRY_SUBMIT_TOKEN`.
`GH_TOKEN` supplies GitHub authentication to controllers only. A local
provider can instead set an absolute `local_remote` path and use bare Git
pull refs at `refs/pull/<number>/head`.

```sh
export GANTRY_CONFIG=/absolute/path/to/controller.toml
gantryd
```

From a source checkout, use `gleam run` in `packages/server` with the
same environment.

The API listens on loopback. For remote agents or workers, place a TLS
reverse proxy on each controller and give clients its HTTPS origin.
The first deployment is a single trust domain. Agents with the build
token can inspect registered runs and read blobs by digest. Workers
share a trusted worker role, so each slot needs a unique operator-assigned
ID and a persistent journal directory.

For a quorum, start three distinct named BEAM nodes in separate failure
domains with a shared Erlang distribution cookie. Keep Erlang distribution
inside the trusted control network and use OTP TLS distribution across
hosts. Set OTP VM options such as the node name via `ERL_FLAGS` in the
service environment. Give each controller its own local `data_dir` and
the same shared filesystem mounted at `blob_dir`. Use the same repository
policy and tokens on all nodes. The shared filesystem must provide atomic
renames and file/directory sync.

Start the first node with an empty `seed`. Set the other two nodes' seeds
to its full Erlang node name. Join serially, then serve worker and agent
traffic. Subsequent restarts use each node's existing Ra directory.
Two of three voters can commit queue transitions. The local deployment
recipe in [the end-to-end harness](../scripts/e2e.sh) runs all three on
one host.

<a id="start-an-executor"></a>

## Start a worker

Pre-pull the configured digest-pinned action image and the Alpine 3.22
collector image on each Docker host. The collector uses the digest
in the controller example. Choose images containing `/bin/sh`, `tar`,
and the toolchains your targets need. The action receives its selected Git
files and verified upstream artifacts in a private tmpfs workspace.
It runs without network access and has a read-only container root.

```sh
docker pull alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
export GANTRY_ENDPOINT=https://controller-a.example,https://controller-b.example
export GANTRY_WORKER_TOKEN=WORKER_TOKEN_FROM_CONTROLLER_CONFIGURATION
export GANTRY_WORKER_ID=linux-large-1 GANTRY_POOL=linux
export GANTRY_WORKER_DIR=/srv/gantry/worker-linux-large-1
export GANTRY_WORKER_CPUS=16 GANTRY_WORKER_MEMORY_MIB=16384 GANTRY_WORKSPACE_MIB=8192
gantry-worker
```

From a source checkout, use `gleam run -m gantry/worker` in
`packages/server` with the same environment.

Use one worker process per capacity slot. Defaults are two CPUs,
768 MiB of container memory, and 256 MiB of workspace. Match the capacity
and isolation policy across workers in the same named pool. Several
workers may share a machine when the operator sizes their combined
reservations to fit. Retain the worker directory on restart. It records
whether a container could have started and keeps unpublished outcomes
until a controller acknowledges them.

The Gleam worker uses Gun for HTTP, SQLite for the local custody journal,
and the Docker CLI to manage containers and volumes. Action images supply
the tools their commands need.
[Worker lifecycle](architecture/runtime.md#run-an-action-graph)

## Use the agent and submit API

Commit a `gantry.json` to the project. The
[manifest example](examples/gantry.json) has a producer and a dependent
test. Each action takes an argument vector, input file or directory paths,
declared file outputs, and a timeout in seconds. `inputs: ["."]` projects
the whole tree. `inputs: []` starts with only upstream artifacts. The
`deps` edges stage artifacts and participate in the cache key. The
`after` edges affect scheduling only.

```sh
revision=$(git rev-parse HEAD)
gantry plan try-check owner/project "$revision" check
gantry run try-check owner/project "$revision" check
gantry watch try-check
gantry blob OUTPUT_OR_LOG_SHA256
gantry submit group-12-13 owner/project 12 13
gantry watch group-12-13
```

Use `GANTRY_URL` to select a reachable controller. The CLI emits JSON
for plans, runs, and status. `watch` polls and emits changed snapshots
as JSON lines. Pass a file containing one action as the optional final
CLI argument for isolated ad hoc work. Ad hoc keys are scoped to their
run ID. The submit token can admit or inspect submissions. It cannot
claim work or upload worker outputs.
[CLI reference](cli.md)

The [GitHub Actions example](examples/github-submit.yml) uses a trusted
manual workflow to submit an ordered list, wait for landing, and link the
confirmed commit on the original PRs. GitHub can recognize the merge by
ancestry. This path requires the configured GitHub identity to be allowed
to fast-forward the target, with source PR policy satisfied. Protect
the target against rewinds and deletion. A stale-base result blocks the
old attempt. A fresh submission uses a fresh run ID and rebuilds against
the current target.

## Current implementation boundaries

The first store replaces a bounded 4 MiB metadata snapshot with an atomic
Khepri CAS. High-throughput placement, indexed state and retention remain
separate work. Startup and failover tests use real voters. The worker uses
Docker while Loom executor integration awaits its own interop proof. The
GitHub adapter and workflow require deployment validation on a live
repository. The full gate exercises the same Git preparation and mutation
against a local bare remote.

The API uses immutable commits and optional ad hoc actions. Workspace
overlays, cancellation, and event cursors are described in the
[design](architecture/build-and-submit.md) for later protocol work.
