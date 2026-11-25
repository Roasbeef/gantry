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

Use the [controller load benchmark](controller-load.md) to measure short
actions and idle polling as the worker fleet grows. The
[queue verification guide](queue-verification.md) covers replayable fault
schedules and the checks behind controller failover.

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
tar, workers use Docker, `env`, `kill`, and `realpath`, and the CLI uses
Bash, curl, and jq. Python is unnecessary at runtime.

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

## Choose a deployment

### Verify a local installation

Run this command on Linux with the installed release, Docker, OpenSSL,
and util-linux (`flock`, `setsid`, and `setpriv`).

```sh
gantry init --local
```

Init saves a loopback profile, boots the controller, and runs a fixture
with the installed worker and Docker. It pulls the digest-pinned fixture
image if needed. The JSON result includes the endpoint, BEAM node,
worker ID, pool, run ID, and the verified artifact digest. Init stops its
services on exit. If Docker is unavailable, it verifies controller
readiness, reports the missing prerequisite, and stops. Retry init after
the user running Gantry can reach the Docker daemon.

The profile lives in `${XDG_STATE_HOME:-$HOME/.local/state}/gantry/local`
with private permissions. It holds the fixture's own Git repository,
controller configuration and queue, worker journal, logs, and role
credentials. Init reopens the same identity, credentials, and journal on
rerun and verifies the existing artifact if the smoke already passed.
Set `GANTRY_LOCAL_PORT` on first init to choose a port other than 4737.
Restore an established profile's Ra state or worker journal from backup
if either is missing or damaged.

Use `gantry local start` to run both services in the foreground or as
one supervisor-managed process. Load the agent credential and endpoint
in the shell that will use the CLI.

```sh
. "${XDG_STATE_HOME:-$HOME/.local/state}/gantry/local/client.env"
gantry status RUN_ID
```

The generated controller configuration registers only the smoke fixture.
Add other repositories explicitly in `controller.toml` while the
controller is stopped.

### Prepare a remote worker

Install the release on a Linux Docker host. Use a stable HTTPS gateway
origin and the existing deployment's worker role token. The gateway
must pass `GET /v1/worker/ready` and its authorization header to a current
controller. Readiness checks the token and queue quorum without
acquiring a lease.

```sh
gantry worker setup https://gantry.example linux --token-stdin < /private/path/worker-token
gantry worker start
```

You can also supply the token through `GANTRY_WORKER_TOKEN`. Setup checks
Docker and authenticated gateway readiness, saves one slot, and exits.
Use the explicit start command as the foreground command for your
supervisor. Install a gateway's private CA in the system trust store on
the worker when needed. Pre-pull the images required by the pool before
admitting a build.

Keep the profile at
`${XDG_STATE_HOME:-$HOME/.local/state}/gantry/worker` with its journal.
Rerunning setup reuses the slot's identity and saved token and requires
the original gateway and pool. Keep the gateway routed to the same
deployment for the lifetime of the journal. Use a fresh profile and slot
to connect to a different deployment.

### Size the controller fleet

Run one controller for a single-host deployment. For controller failover,
run three controllers as voters on separate hosts. Two of three voters
can serve the queue. All controllers in the quorum serve the same queue
and use the same blob store.

Workers and controller API endpoints have a many-to-many relationship.
Each worker polls its preferred controller and tries alternate origins
on connection failures and HTTP 5xx responses. Many workers can use any
controller, and each worker can list every controller in its quorum. Give
different workers different first origins to spread the initial requests.
List origins from the same quorum. The configured worker pool determines
which actions the slot can claim.

### Give clients one stable origin

Put an HTTPS gateway in front of the controller proxies and point every
worker and agent at its DNS name.

```sh
export GANTRY_ENDPOINT=https://gantry.example
export GANTRY_URL=https://gantry.example
curl -fsS --max-time 10 "$GANTRY_URL/ready"
```

Configure the gateway with the members of one quorum, or supply those
backends through the platform's service registry. Probe `GET /ready` with
a timeout of at least six seconds. It returns HTTP 200 after Ra confirms
a majority and 503 when the check fails. The endpoint is available
without a role token. Keep each backend's Git and blob access configured
as usual. Pass the authorization header through and allow the same 64 MiB
uploads as the controller proxies. Let clients reconcile ambiguous
requests using their original run ID or lease serial. The gateway should
send each request once.

The [HAProxy example](examples/haproxy.cfg) uses verified TLS to each
controller proxy. Configure the public gateway hostname as a virtual-host
alias on each controller proxy, because HAProxy forwards that Host header
on requests and health checks. During a rolling upgrade, enable the new
gateway check once the backend controllers serve `/ready`. Replace the
example's hostnames and certificate paths, then check it with
`haproxy -c -f haproxy.cfg`. Use a shared DNS name in front of a
redundant gateway if the front door also needs failover. To add or remove
controller origins, change the gateway backend list or registry. Worker
endpoint settings stay the same.

Workers initiate every HTTP request. For controllers behind NAT, an
outbound tunnel connector can publish each controller's loopback API
to the gateway. Give the gateway a distinct origin per controller and
probe `/ready` through the same route as client traffic. Controllers
still need a private network path to each other for Ra replication.
Use the private mesh or overlay addresses for their Erlang node names.

For the controller network, DNSCluster can discover BEAM nodes from a
DNS query. Libcluster supports multiple discovery backends. These tools
find and connect nodes. Gantry's configured `seed` and Khepri join still
control admission as a Ra voter. OTP's `pg` can publish process groups
after nodes connect. A gateway publishes the HTTP service independently
of those BEAM mechanisms.
[DNSCluster](https://github.com/phoenixframework/dns_cluster) ·
[Libcluster](https://github.com/bitwalker/libcluster) ·
[OTP `pg`](https://www.erlang.org/doc/apps/kernel/pg.html)

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

For a new deployment, generate the three role tokens once with a separate
`openssl rand -hex 32` invocation for each and load them from a private
service environment. Give each client only the token for its role.
From a source checkout, use `gleam run` in `packages/server` with the
same environment.

The HTTP listener binds to `127.0.0.1`. Use
`http://127.0.0.1:4737` from the controller host when using the example
port. For workers and agents on other hosts, run a TLS reverse proxy on
each controller. Give each proxy a DNS name reachable from clients and
a matching certificate trusted by their operating system. With a private
LAN CA, install its root in the trust stores used by Erlang/OTP and curl
on the client hosts. Forward the full path, query, and authorization
header to `http://127.0.0.1:4737`, support HTTP/1.1, and allow up to
64 MiB per upload with a `Content-Length` at the upstream. Workers and
agents reach the proxy on HTTPS. Restrict it to their networks.

For example, add this Nginx server block on A. Use each controller's
own hostname and API certificate on the other hosts.

```nginx
server {
    listen 443 ssl;
    server_name controller-a.example gantry.example;
    ssl_certificate /etc/nginx/tls/gantry-api-chain.pem;
    ssl_certificate_key /etc/nginx/tls/gantry-api-key.pem;
    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:4737;
        proxy_http_version 1.1;
        proxy_request_buffering on;
        proxy_set_header Authorization $http_authorization;
    }
}
```

```sh
curl -fsS --max-time 10 http://127.0.0.1:4737/health | jq -e '.status == "ok"'
curl -fsS --max-time 10 https://controller-a.example/health | jq -e '.status == "ok"'
```

`GET /health` requires no token. A successful response includes a queue
read, so probe each origin after startup or before routing traffic to it.
Use a build to verify worker execution and blob access.

### Form a three-controller quorum

Use the same repository policy, role tokens, and shared filesystem on all
three controllers. Mount that filesystem at `blob_dir` before starting
Gantry. It must provide atomic renames and file and directory sync. Keep
`data_dir` on each controller's local disk for its Ra state.

Copy the controller example for each host and set the top-level values
as shown. The matching paths under `data_dir` are separate local
directories.

| Host | Erlang node name | `seed` | `data_dir` | `blob_dir` |
| --- | --- | --- | --- | --- |
| A | `gantry@controller-a.example` | `""` | `/srv/gantry/controller` | `/srv/gantry/shared` |
| B | `gantry@controller-b.example` | `"gantry@controller-a.example"` | `/srv/gantry/controller` | `/srv/gantry/shared` |
| C | `gantry@controller-c.example` | `"gantry@controller-a.example"` | `/srv/gantry/controller` | `/srv/gantry/shared` |

Ensure the service accounts can write their local directories and the
shared mount. Provision one random distribution cookie for the quorum
and put the same value in each controller service account's
`~/.erlang.cookie` with mode `0400`. Keep the cookie on the controllers.
The host portion of each long node name must resolve on all three hosts
to an address on the control network.

For cross-host distribution, provision a controller-only CA and a key
and certificate for each controller. Use certificates valid for both
TLS server and TLS client authentication, with the node's hostname in
the certificate's DNS subject alternative names. Make the keys readable
only by the corresponding service account. Write the following OTP options
file as `/etc/gantry/dist-tls.conf` on each controller, with the PEM
files supplied by your deployment.

```erlang
[
 {server, [{certfile, "/etc/gantry/dist-cert.pem"},
           {keyfile, "/etc/gantry/dist-key.pem"},
           {cacertfile, "/etc/gantry/dist-ca.pem"},
           {verify, verify_peer}, {fail_if_no_peer_cert, true}]},
 {client, [{certfile, "/etc/gantry/dist-cert.pem"},
           {keyfile, "/etc/gantry/dist-key.pem"},
           {cacertfile, "/etc/gantry/dist-ca.pem"},
           {verify, verify_peer}]}
].
```

Set the VM flags in each controller's service environment, substituting
its name from the table. Then use the controller launch command above.

```sh
export ERL_FLAGS="-name gantry@controller-a.example -proto_dist inet_tls -ssl_dist_optfile /etc/gantry/dist-tls.conf -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100"
```

Allow TCP 4369 (EPMD) and TCP 9100 (the pinned distribution port) between
controllers only. EPMD maps an Erlang node's name to its distribution
port on a known host. The configured `seed` tells Gantry which node to
contact for its initial Khepri/Ra join. Workers use `GANTRY_ENDPOINT` and
ordinary DNS and HTTPS. They need neither EPMD nor distribution access.

Start A and wait for its local health probe, then start and probe B,
then C. Enable normal traffic after all three are healthy. Keep each
controller's node name and Ra directory together on restart. The seed
is used when joining with a fresh directory. If you plan to grow from
one controller to three, give the first controller its final Erlang
name at initial startup. Its Ra directory is tied to that name.
Mount the blob store on all three hosts and join the two fresh
controllers using the existing trusted voter as seed. While the cluster
has two voters, both are required for a majority.
Once the new origins are healthy, add them to worker configurations and
restart each worker with its existing ID and journal directory.
For a same-host rehearsal, use the loopback configuration in the
[end-to-end harness](../scripts/e2e.sh).

<a id="start-an-executor"></a>

## Start a worker

Pre-pull the digest-pinned action images for the slot's pool and the
Alpine 3.22 collector image on each Docker host. The collector uses the
digest in the controller example. Choose images containing `/bin/sh`, `tar`,
and the toolchains your targets need. The action receives its selected Git
files and verified upstream artifacts in a private tmpfs workspace.
It runs without network access and has a read-only container root.
For a worker sharing a host with a single controller, use
`GANTRY_ENDPOINT=http://127.0.0.1:4737`. The following example uses the
three HTTPS origins.

```sh
docker pull alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
export GANTRY_ENDPOINT=https://controller-a.example,https://controller-b.example,https://controller-c.example
export GANTRY_WORKER_ID=linux-01 GANTRY_POOL=linux
export GANTRY_WORKER_DIR=/srv/gantry/worker-linux-01
install -d -m 0700 "$GANTRY_WORKER_DIR"
: "${GANTRY_WORKER_TOKEN:?Load the shared worker token from the private service environment}"
export GANTRY_WORKER_TOKEN
gantry-worker
```

From a source checkout, use `gleam run -m gantry/worker` in
`packages/server` with the same environment.

Run the worker as a user with access to its Docker daemon and write
access to its local directory. One worker process runs one action at a
time. Set these variables to size the slot. Each is validated against
its bounds at startup, and a value outside them stops the worker.

| Variable | Default | Bounds | Limits |
| --- | --- | --- | --- |
| `GANTRY_WORKER_CPUS` | 2 | 1 to 1024 | Container CPUs |
| `GANTRY_WORKER_MEMORY_MIB` | 768 | 128 to 2097152 | Container memory, including `/tmp` |
| `GANTRY_WORKSPACE_MIB` | 256 | 64 to 1048576 | The `/work` tmpfs volume |
| `GANTRY_WORKER_PIDS` | 4096 | 64 to 1048576 | Processes and threads in the container |
| `GANTRY_WORKER_NOFILE` | 65536 | 256 to 1048576 | Open files per process |
| `GANTRY_WORKER_TMP_MIB` | 1024 | 16 to 65536 | The `/tmp` tmpfs size |

The process default matters for BEAM builds. A BEAM starts a scheduler
thread per core, and on a 32-core host it could not start under 128
processes. `/tmp` counts against the memory limit, so a larger size
bounds the file it can hold and does not reserve memory. Match capacity
and isolation policy across slots in the same named pool, and match
`GANTRY_POOL` to the controller's repository pool.

At startup the worker takes an exclusive SQLite lock on its journal, so a
second worker with the same directory exits with an error. It then
inspects the collector image and exits with the `docker pull` command to
run if the image is missing. An idle slot polls the controller with a
jittered delay that grows from about 0.25 s to a 2 s ceiling and resets
as soon as it receives work. Each HTTP exchange has a 10 s connect
timeout, a response wait of 30 s plus 4 s per MiB uploaded, and a 30 s
bound that restarts at every response chunk. A 64 MiB blob therefore
completes over any link that sustains 256 KiB/s. The worker keeps one
connection per controller origin.

Infrastructure faults retry while they are safe to retry, and
[otherwise become a failed action](architecture/runtime.md#worker-faults).
To add slots, launch one supervisor-managed worker per slot with its own
deployment-wide ID and directory, for example `linux-02` and
`/srv/gantry/worker-linux-02`. Size their combined reservations to fit
the host. No controller registration step is needed. Retain each
directory and reuse the same worker ID on restart. The journal records
whether a container could have started and keeps unpublished outcomes
until a controller acknowledges them.

To move a repository to a new pool, configure the new slots and roll the
repository's pool setting across the controllers. Already enrolled actions
carry their original pool. Keep capacity in that pool until they finish.

Run an uncached action on a registered repository in the new slot's pool.
Use `gantry watch RUN_ID --output json` to see the active assignment at
`.work[].step.lease.worker` and the final result. Check the worker ID or
use a dedicated smoke pool when several slots can claim the action.
Retrieve a log or output digest with `gantry blob DIGEST --output raw`
to check blob service.

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
