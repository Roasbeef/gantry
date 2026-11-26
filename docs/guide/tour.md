# A tour of the code

Someone types `gantry run check-1 owner/project $(git rev-parse HEAD) check`.
Between that command and a passed run on their screen, the request crosses a
Gleam CLI, an HTTP listener, a Git mirror, a replicated queue, a polling
worker, a SQLite journal, a Docker container, and back. Following it once, in
order, with a file and line for every step, is the quickest way to learn where
each piece lives. The other documents go deeper on what each layer is. This
one is about how a request moves through them, and where a step deserves more
depth it links to that depth.

Paths are relative to a package's source root. `gantry_core/queue.gleam` is
`packages/core/src/gantry_core/queue.gleam`, and `gantry/api.gleam` and the
`gantry_*_ffi.erl` files are under `packages/server/src`. Line numbers point
at the definition and were checked against the tree this page was written
from, so a stale one means the code moved, not that the step changed.
The tour describes what is built. For what is only designed, see
[the status section](../architecture/runtime.md#status).

## 0. The shape of the system

Two Gleam packages. `packages/core` is the pure part: the manifest compiler
(`gantry_core/graph.gleam`), the admission rules (`gantry_core/request.gleam`),
the queue (`gantry_core/queue.gleam`), and the JSON codecs that persist and
transmit it (`gantry_core/protocol.gleam`). It imports no process, OTP, or
filesystem package and declares no FFI, so it also runs on JavaScript, and
every transition is a function from a state and an observation (a clock
reading, a Git result) to a new state. `packages/server` holds everything with
an effect. It has three entry points, which the release packages as three
launchers (`scripts/release.sh`): `gantryd`, the controller
(`gantry.gleam:42`); `gantry-worker`
(`gantry/worker.gleam:60`); and `gantry`, the CLI
(`gantry/cli.gleam:211`).

A deployment is one to three controllers, any number of worker slots, and a
shared filesystem. Controllers hold the queue in Khepri on Ra, each run under its
own key with small indexes beside it (`gantry_core/layout.gleam`), and every
change is one transaction that compares the keys the decision read
(`gantry/store.gleam`). Large objects go to the shared filesystem by
SHA-256 (`gantry/blobs.gleam`). A worker keeps a private SQLite journal of its
one active attempt (`gantry/worker/custody.gleam`). Git is read and written
only by controllers, through a persistent bare mirror per repository
(`gantry/git.gleam`). Custom Erlang is private to the `gantry_*_ffi.erl`
modules and their typed `gantry/internal/ffi_*.gleam` bindings.

The rule that explains most of the code: a transition is decided in the core
from the keys the caller read, the caller commits the resulting plan only if
every key it relied on is unchanged, and an external effect (a Docker start, a
Git push) happens only after the decision it depends on has committed. A stale
planner loses the commit and recomputes, so a lost reply or a restart is
always recoverable by replaying the same identity.

## 1. Before the request

**Install.** `make install` builds an OTP release with the Erlang runtime and
the SQLite native extension (`scripts/release.sh`, `scripts/install.sh`) and
switches `PREFIX/lib/gantry/current` atomically. No jq or curl is needed at
runtime, because the CLI is Gleam too.

**First run.** `gantry init --local` (`gantry/cli/onboarding.gleam:149`)
creates a private profile, writes a `controller.toml` for a fixture repository
with one worker entry (`gantry/cli/onboarding.gleam:688`),
starts the installed controller and worker as supervised children
(`gantry/cli/service.gleam:106`), and runs a Docker smoke build.
`gantry local start` (`gantry/cli/onboarding.gleam:170`) keeps both
running, and `gantry worker setup` and `gantry worker start`
(`gantry/cli/onboarding.gleam:217`) prepare a remote slot.

**`controller.toml`.** The controller reads it once at startup
(`gantry/config.gleam:122`). It fixes the storage roots, the port,
the Raft `seed`, every registered repository (name, branch, target, pool,
digest-pinned image, and either a GitHub identity or a local bare remote), the
workers, and the retention bounds. `config.parse`
(`gantry/config.gleam:141`) rejects an unpinned image, a relative
storage path, and equal role tokens. A configuration with no `[[worker]]`
entry is refused (`gantry/config.gleam:265`), because the
shared worker token no longer exists.

**Roles.** Three kinds of credential reach the HTTP API. The agent token
(`GANTRY_TOKEN`) plans, runs, and reads. The submit token
(`GANTRY_SUBMIT_TOKEN`) admits and reads group submissions. Each worker has
its own token, and the controller keeps only its digest. A bearer token
selects the worker's identity through `gantry/config.gleam:193`)
and no body field can choose it. Role tokens must be at least 32 bytes
(`gantry/config.gleam:220`).

**Boot.** `start` loads the configuration, opens the replica, and starts one
supervisor with two children (`gantry.gleam:65`,
`gantry.gleam:78`): the Mist HTTP listener, bound to loopback, and
the reconciler. `store.boot` decides from a marker file and the seed whether
this node reopens, bootstraps, or joins (`gantry/store.gleam:94`),
and it refuses a node whose name changed or whose Ra server vanished
(`gantry/store.gleam:128`). A child that crashes five times in a
minute ends the supervisor and the VM, and the service manager restarts it.

## 2. A repository declares its graph

The project commits `gantry.json`: `actions`, and `targets` that name the
actions to satisfy ([example](../examples/gantry.json)). The decoder reads
those two keys and nothing else
(`gantry_core/graph.gleam:150`), and each action decodes with
defaults (`gantry_core/graph.gleam:166`): `inputs` is `["."]`,
`timeout` 300). `graph.compile` (`gantry_core/graph.gleam:62`)
checks names, edges, outputs, and paths (`gantry_core/graph.gleam:306`),
orders the actions topologically (`gantry_core/graph.gleam:355`), and keeps
the closure of the requested target. Path components are restricted so
nothing reaches `.git` or escapes the workspace
(`gantry_core/graph.gleam:95`). The image and pool are not in
the manifest. They come from the repository entry, which is how an operator,
and not a pull request, controls where code runs.

Two edge kinds matter later. `deps` stages an upstream action's output files
into the downstream action and puts their digests in its cache key. `after`
only orders. [Field reference](../integrating.md#declare-the-graph).

## 3. The request

`gantry run` is a client of the HTTP API. `cli.run` parses options and
dispatches (`gantry/cli.gleam:228`). For `plan`, `run`, and `submit` it
builds the body through the same `gantry_core/request` rules the controller
uses (`gantry/cli.gleam:883`, `gantry_core/request.gleam:224`),
so a request that fails there fails locally with the controller's answer. It then
posts the JSON with the agent token (`gantry/cli.gleam:821`).

**HTTP.** Mist hands each request to `gantry/http_api.gleam:38`,
which matches the method and path and picks the credential the route needs
(`gantry/http_api.gleam:125`). It checks the token before it reads
the body, requires a bounded `Content-Length`
(`gantry/http_api.gleam:245`), and refuses a body that is not UTF-8.
`POST /v1/runs` calls `gantry/api.gleam:43`. Every route and status is
in the [API reference](../api.md).

**Admission.** `api.build` parses the body (unknown keys are rejected), looks the
repository up in the operator's allowlist (`gantry/api.gleam:371`),
then calls `prepare.build` (`gantry/prepare.gleam:26`). That opens a
Git session on the repository's mirror (`gantry/git.gleam:54`),
which takes a node-local lock, fetches the pinned commit
(`gantry/git.gleam:221`), and runs `tasks`
(`gantry/prepare.gleam:275`). `tasks` reads `gantry.json` at that commit,
compiles the target, and for each action archives its declared inputs from the
Git tree (`gantry/prepare.gleam:390`) and stores the archive with
`blobs.put_input` (`gantry/blobs.gleam:122`): one blob up to 64 MiB, or chunks
of at most 32 MiB plus a manifest above that. An action that declares
`"git": "shallow"` also gets a `.git` archive for its commit
(`gantry/git.gleam:431`). `blobs.put` writes under a random name,
syncs the file and directories, and renames it to `objects/<sha256>`, so a
reader sees the whole object or none.

**The recipe.** Each task gets a recipe, the SHA-256 of a fixed tag, the cache
scope, the repository, the pool, the image, the source archive's digest, and
the encoded action, plus the commit when the action declared Git metadata
(`gantry_core/graph.gleam:217`, called at `gantry/prepare.gleam:360`). A declared
target shares one scope. An ad hoc action is scoped to its run ID, so its
results cannot satisfy a declared target. `gantry plan` stops here and returns
the action list.

**The commit.** For a run, `api.admit` (`gantry/api.gleam:158`) calls
`store.admit` (`gantry/store.gleam:401`), which plans `layout.admit`
(`gantry_core/layout.gleam:704`) around `queue.admit`
(`gantry_core/queue.gleam:450`). `queue.admit` appends the run in
admission order with every action `Pending(0)`. If the ID already exists, it
returns the stored run only when the inputs match, which is what makes a
retry after a lost response safe. The layout gives the run the next
enrollment number and writes its record and index entries. The store commits
the plan (`gantry/store.gleam:256`, over `gantry_khepri_ffi.erl:150`) as one
transaction that compares every key the decision read and writes all of its
own, and a refused plan is recomputed from fresh reads up to eight times
(`gantry/store.gleam:313`) before it answers 503 `queue contention
exceeded retry budget`. A queue that already holds 10,000 runs refuses a new
one as unavailable (`layout.max_runs`).

## 4. Waiting

The run is durable and nothing has executed. An action runs when a polling
slot qualifies for it, and four things decide that.

**Prerequisites.** `queue.next_work` (`gantry_core/queue.gleam:935`)
returns a `Pending` action only when every action named in `deps` and `after`
has passed or been reused, and it builds the cache key from the recipe and the
resolved dependency files. The `ready` index lists a run under each pool where
`next_work` finds an action, and `layout.entries`
(`gantry_core/layout.gleam:188`) recomputes it whenever the run changes.

**Pools.** Only a task whose pool equals the slot's pool is considered.
Admission copied the repository's pool into the task, so editing
`controller.toml` later does not move queued work.

**Serving.** A run is served (`gantry_core/queue.gleam:923`) if it is a
`Build`, or a `Queued` group that has not failed. A failed run's pending
actions are `Skipped` at the moment of failure
(`gantry_core/queue.gleam:1071`), which keeps an idle queue
recognizably quiet.

**Lanes and preparation.** A group submission is different. It is admitted as
`Waiting`, holds no graph, and waits for its lane (repository and branch) to
be free. `queue.preparations` (`gantry_core/queue.gleam:609`)
offers the first waiting run of each free lane, and a lane is held by a
`Queued` run that has not failed or by a `Landing` run
(`gantry_core/queue.gleam:731`). The reconciler acts on the offer
once a second (`gantry/reconcile.gleam:124`) and records the
result with `queue.record_preparation`
(`gantry_core/queue.gleam:660`), which accepts it only
for the exact run it offered, so a stale controller's outcome is refused.
Section 9 follows a group through that.

## 5. A worker claims

A slot is one `gantry-worker` process. `worker.boot`
(`gantry/worker.gleam:68`) reads its identity, pool, endpoint, token, and
limits, opens the journal with its exclusive lock
(`gantry/worker/custody.gleam:51`), and checks that the collector image
exists (`gantry/worker/docker.gleam:347`). The slot loop runs as a
supervised actor (`gantry/worker.gleam:123`). Each tick calls
`slot.step` (`gantry/worker/slot.gleam:96`), which reads the journal's
phase first and claims new work only when the journal is empty. After an empty
poll the loop waits 0.25 s to 2 s with jitter
(`gantry/worker.gleam:197`).

**The poll.** The slot posts `{worker, pool}` to `/v1/claims`
(`gantry/worker/slot.gleam:132`) through
`gantry/worker/controllers.gleam:98`. That tries its preferred origin
first and moves to the next after a transport error or a 5xx answer
(`gantry/worker/controllers.gleam:156`), over one reused Gun
connection per origin with connect, first-byte, and idle bounds. On the
controller, `handle` authenticates the worker and calls
`gantry/api.gleam:192`, which checks that the body's worker matches the
credential's (`gantry/api.gleam:380`) and calls `store.claim`
(`gantry/store.gleam:428`).

**The quiet path.** `store.claim` (`gantry/store.gleam:428`) plans
`layout.claim` (`gantry_core/layout.gleam:837`), which reads the `active`
index (leases and their deadlines) and the pool's `ready` index. A poll whose
worker holds no lease, with no lapsed lease and nothing ready, reads no run
and writes nothing. The store confirms that plan with a Ra consistent query
that the leader answers after a majority confirms its authority
(`gantry_khepri_ffi.erl:207`), returns 204, and appends nothing to the log.
It takes no lock, so empty polls never wait behind real claims.

**The decision.** The full path runs `queue.claim`
(`gantry_core/queue.gleam:776`) on only the runs the layout loaded: those with
a lapsed lease, the worker's own lease, and the oldest ready ones. It runs
`queue.expire` first. Then it
returns the lease this worker already holds, if any
(`gantry_core/queue.gleam:857`), so a replayed poll costs
nothing. Otherwise `offer` walks the runs in admission order
(`gantry_core/queue.gleam:874`) and `allocate`
(`gantry_core/queue.gleam:891`) handles the first action `next_work`
returns. A cached proof for the same repository and key turns the action into
`Reused` and the scan continues, so cache hits are resolved at claim time.
A miss writes `Active` with a lease: a new global serial, the worker, an attempt
number, and a deadline of the claim time plus the action's timeout plus 150
seconds (`gantry_core/queue.gleam:83`). The lease is committed
before the answer leaves the controller, so a worker never runs an action the
queue does not know about. [How slots share work](../scheduling.md).

**Expiry.** Nothing renews a lease. `queue.expire`
(`gantry_core/queue.gleam:801`) returns every action past its deadline
to `Pending` with one more attempt, and the third lapse fails the action as
`LeaseExpired` (`gantry_core/queue.gleam:77`,
`gantry_core/queue.gleam:802`). Because the next lease has a new
serial, a result for the old one is refused. A result that arrives before any
claim has expired the lease is still accepted, since expiry runs only inside
a claim.

## 6. Execution

The worker's first act on a 200 is to journal the assignment
(`gantry/worker/slot.gleam:155`). It checks that the lease names this
slot and pool, derives an attempt name from the directory, worker, run, action,
and serial, and inserts the row (`gantry/worker/custody.gleam:277`). The
journal is the slot's memory: at most one attempt exists, and its phase
(`Ready`, `Interrupted`, or `Recorded`, `gantry/worker/custody.gleam:38`)
tells `slot.step` what to do next.

**Staging.** `slot.perform` (`gantry/worker/slot.gleam:193`) calls
`docker.execute` (`gantry/worker/docker.gleam:440`). It first removes
any container, volume, or staging directory left under the attempt's name
(`gantry/worker/docker.gleam:333`), so a retry starts clean. It
fetches the source archive, the Git metadata archive if there is one, and
each dependency's output through `controllers.fetch`, which rejects bytes
whose SHA-256 differs from the requested digest
(`gantry/worker/controllers.gleam:187`). A chunked input goes through
`inputs.stage` (`gantry/worker/inputs.gleam:42`), which checks each chunk's
length and digest and the reassembled digest. Staging builds the tar files
without extracting anything on the host (`gantry/worker/docker.gleam:483`).

**The sandbox.** `docker.run` creates a tmpfs volume sized by
`GANTRY_WORKSPACE_MIB`, starts a read-only collector container that mounts it,
and creates the action container (`gantry/worker/docker.gleam:688`). Every
container gets `--network=none`, `--cap-drop=ALL`, a read-only root, user
65534, `no-new-privileges`, and no log driver
(`gantry/worker/docker.gleam:51`). The action container adds the
slot's limits (`gantry/worker/docker.gleam:294`): CPUs,
memory, a process limit, an open-file limit, and a `/tmp` tmpfs, each from a
`GANTRY_WORKER_*` variable read once at boot
(`gantry/worker/docker.gleam:121`). These flags are the only use of
the limits. The controller never sees them. The container's command extracts
the two archives into `/work` and then `exec`s the action's `argv`.

**The start marker.** Just before `docker start`, the one effect that runs
action code, the worker commits a started flag to the journal
(`gantry/worker/custody.gleam:298`). If the process dies after
that and before a result is recorded, the next step finds an `Interrupted`
attempt, cleans up, and records the outcome `Interrupted` instead of running
it again (`gantry/worker/slot.gleam:107`). The controller lapses that lease
at once, so the action is leased again under a fresh serial, and the
attempt counts toward the bound. On SIGTERM the worker first drains:
`drain` in `gantry/worker.gleam` stops claiming, waits as a Weft task for
the journal to empty, and past `GANTRY_WORKER_DRAIN` calls `slot.release`
to report the attempt `Interrupted` itself.

**Running.** `start_action` runs `docker start -a` as a Weft task with a
deadline of the action's timeout plus a grace period, and removing the
containers is the task's cancel (`gantry/worker/docker.gleam:843`).
Output is capped and spooled into the journal. On a normal exit the
declared output files are read through the collector, which refuses symlinks,
non-regular files, and files over the limit
(`gantry/worker/docker.gleam:948`). A nonzero status, a timeout,
or a bad output becomes a `Rejected` completion, and the log is kept either
way (`gantry/worker/docker.gleam:919`).

## 7. Publishing

The finished result is journaled before the worker touches the Docker
resources again (`gantry/worker/custody.gleam:327`), so a cleanup fault
retries without losing the result. In the `Recorded` phase `slot.step` removes
the containers once and calls `publish`
(`gantry/worker/slot.gleam:263`).

`publish` uploads only the blobs the receipt names. Each is a `PUT
/v1/blobs/<sha256>`; the controller refuses a body whose digest differs
from the path (`gantry/http_api.gleam:288`) and stores it through
`blobs.put`. Then the worker posts the receipt to `/v1/results`.
`api.finish` (`gantry/api.gleam:318`) checks that the body's worker
matches the credential, that every referenced blob exists
(`gantry/api.gleam:354`), and proposes `queue.finish`
(`gantry_core/queue.gleam:996`). The queue accepts a result only for the
live serial held by that worker. A success must list exactly the action's
declared outputs, and it becomes a `Passed` proof that is also indexed for
reuse (`gantry_core/queue.gleam:1020`). A rejection becomes `Failed`
and strands the run's pending actions as `Skipped`
(`gantry_core/queue.gleam:1059`). An interruption lapses the lease as an
expiry would.

The answer is 200 `{"accepted":true}`, or 409 when the lease is no longer
active. The worker treats both as final: it deletes the attempt row and clears
the blob spool in one transaction (`gantry/worker/custody.gleam:401`)
and goes back to polling. Until then, a lost reply, a restart, or a dead
controller only repeats the same uploads and the same receipt, and those are
idempotent.

## 8. Watching and fetching

`gantry watch` polls `GET /v1/runs/<id>` (`gantry/cli.gleam:1171`).
The controller reads the run's record and encodes it
(`gantry/api.gleam:177`), adding a phase computed from the steps
(`gantry_core/queue.gleam:1214`,
`gantry_core/protocol.gleam:115`). The phase is derived on
output and never stored. The stream ends at a terminal phase, and the exit
code says whether it passed. `gantry blob <sha256>` fetches a log or an output
from `GET /v1/blobs/<sha256>` (`gantry/http_api.gleam:299`), where the
controller re-hashes the bytes before returning them. The status JSON is
described in the [API reference](../api.md#run-status).

Meanwhile the reconciler trims history. Once a minute it applies
`queue.retain` (`gantry_core/queue.gleam:1187`) through `layout.retain`
(`gantry_core/layout.gleam:1261`) and `gantry/reconcile.gleam:195`, dropping
the oldest terminal runs and proofs beyond the `[retention]` bounds in batches
of 250 commits. Blobs are not collected.

## 9. Landing a group

`gantry submit` posts an ordered list of PR numbers to `/v1/submits` with the
submit token. `gantry/api.gleam:84` pins each head
(`gantry/prepare.gleam:55` and `gantry/prepare.gleam:240`),
which fetches `refs/pull/N/head` and, for GitHub, reads the pull and checks its
base branch. It admits the group as `Waiting` with those pins and no graph.
Repeating the request with the same ID replays the stored run.

**Preparation.** When the group heads a free lane, the reconciler calls
`prepare.candidate` (`gantry/prepare.gleam:87`). It fetches the
branch tip, re-reads every pinned pull (a moved head refuses the group as
`member_moved`), and merges the heads in order, one two-parent commit per member
(`gantry/prepare.gleam:146`). The commit timestamps derive from the
parents, so a replay produces the same OIDs. A conflict refuses the group as
`unmergeable`. Otherwise `stage` reads the manifest at the tip, archives the
inputs from the candidate, and `git.preserve` writes the candidate's objects as
a bundle in shared storage (`gantry/prepare.gleam:195`,
`gantry/git.gleam:364`). `queue.record_preparation` makes the run
`Queued`, with the candidate (branch, base, commit, members) and the graph.
A Git or GitHub failure records nothing, and the reconciler retries the group
with its own backoff.

**Proof.** The candidate's actions run exactly as in sections 4 to 7. While
none has failed, the run holds its lane. If one fails, the run's phase is
`failed` and the lane is free.

**Intent.** Every tick the reconciler proposes `queue.landings`
(`gantry_core/queue.gleam:1100` through `gantry/reconcile.gleam:220`).
Each `Queued` run whose actions all passed becomes `Landing`, and the committed
`Landing` state is the intent. A lane holds at most one such run, so a lane
never has two intents. The reconciler then calls `submit.reconcile` for each
due intent (`gantry/reconcile.gleam:241`).

**The push.** `submit.reconcile` (`gantry/submit.gleam:53`) fetches
the target and restores the candidate bundle, then decides from history alone.
If the candidate is an ancestor of the target, it has landed. If the target is
neither the base nor contains the candidate, the landing is refused as
`target_advanced`. If the target is still the base, `check_members` asks the
provider about each pull
(`gantry/submit.gleam:153`), and a permitted group is pushed with
`--force-with-lease=<target>:<base>`, so Git itself refuses the update if the
branch moved. A policy denial is looked at once more before it stands
(`gantry/submit.gleam:134`), because a push left in flight by
another controller may have landed in the meantime.

**The result.** `reconcile_one` records the outcome through
`queue.record_landing` (`gantry_core/queue.gleam:1134`,
`gantry/reconcile.gleam:328`), which matches it to the exact
outstanding intent. `landed` leaves the commit in
`submission.candidate.commit`. `blocked` carries `target_advanced` or
`policy_denied` and frees the lane. Any error (network, an unknown GitHub merge
state, a failed push) keeps the intent open, and the retry table backs it off
from 1 s to 60 s (`gantry/reconcile.gleam:298`).

## 10. A crash anywhere

The design lets each point of failure recover from durable state, and the
end-to-end gate (`scripts/e2e.sh`) kills most of them.

| What dies or is lost | What recovers it |
| --- | --- |
| A controller | The other voters hold quorum. Workers move to their next origin (`gantry/worker/controllers.gleam:156`). The controller restarts with its node name and Ra directory, and refuses to start if either is wrong (`gantry/store.gleam:94`). The e2e kills a voter during an active lease (`scripts/e2e.sh:203`). |
| The reply to an admission | The client repeats the request with the same ID and gets the stored run (`gantry_core/queue.gleam:524`). |
| The reply to a claim | The next poll gets the same lease, because the worker already holds it (`gantry_core/queue.gleam:857`). |
| The reply to a result | The worker keeps the receipt and blobs until it hears 200 or 409. The e2e loses a committed reply on purpose (`scripts/e2e.sh:404`). |
| A worker before `docker start` | The journal says `Ready`. The restart cleans by name and runs the attempt (`gantry/worker/slot.gleam:96`). |
| A worker after `docker start` | The journal says `Interrupted`. The restart cleans up and reports the attempt interrupted, and the controller reassigns it (`scripts/e2e.sh:305`). |
| A worker sent SIGTERM | It drains: the action finishes and is published, then the worker exits. Past the drain deadline it reports the attempt interrupted (`scripts/e2e.sh:419`). |
| A worker for good | The lease expires and the action runs again on another slot, up to three attempts (`gantry_core/queue.gleam:802`). |
| The Docker daemon, mid-cleanup | The result was recorded first, so cleanup retries without losing it. |
| The reconciler | The supervisor restarts it. Its backoff table is forgotten, and every intent is re-attempted, which is safe because each attempt re-observes the remote before acting. |
| A push whose reply was lost | The next `submit.reconcile` finds the candidate on the target and records `Landed`. |
| A push that was in flight and a policy refusal | `confirm_refusal` looks at the target once more before a block stands. |

The same pattern repeats under the table: identity first (a run ID, a lease
serial, an intent), an effect only after its decision commits, and a
re-observation by identity after any doubt. The seeded simulations and the
TLA+ model check those properties under reordered and lost events
([queue verification](../queue-verification.md)).

## 11. Growing the fleet

More capacity means more slots, each its own process with its own worker ID,
token, and journal directory. Registering a slot is a `[[worker]]` entry in
`controller.toml` on every controller (`gantry/config.gleam:84`),
which is read at startup. A slot claims only from its pool, one action at a
time, in admission order. A single action never splits across slots, so more
machines help a repository only if its manifest has independent actions. The
checklist is in [Operations](../operations.md#add-a-machine), and the rule
for how work is spread is in [Scheduling](../scheduling.md).

The controller side scales differently. All voters serve the same keys, and
every mutation is committed through Raft, so more voters add safety and not
throughput. The [benchmark](../controller-load.md#measurements-on-the-gleam-benchmark)
(`packages/server/dev/gantry/bench.gleam`) measures where that limit is.

## 12. What is not built

Cancellation, workspace overlays, event cursors, resource reservations,
quotas, priority, indexed queue storage, blob collection, a cancel route for a
stuck landing, restore-from-backup tooling, fleet commands beyond local init
and worker setup, and Loom's executor are all absent. Some are described as
targets in the [design pages](../architecture/build-and-submit.md#what-is-built), and
[the status section](../architecture/runtime.md#status) keeps the list.

## 13. A reading order

Read `gantry_core/queue.gleam` first, starting with its module comment: the flow,
the two transition tables, and the invariants are the specification, and the
simulations test them. Then `gantry/store.gleam` (how a proposal commits),
`gantry/http_api.gleam` and `gantry/api.gleam` (what a request can do),
`gantry/prepare.gleam` and `gantry/submit.gleam` (the Git effects),
`gantry/reconcile.gleam` (the background decisions), and
`gantry/worker/slot.gleam` with `custody.gleam` and `docker.gleam` (a slot's
life). `gantry_core/protocol.gleam` shows what the JSON looks like. For
checking a change, `make check` is the unit gate, `make e2e` the live one, and
[queue verification](../queue-verification.md) explains the simulations. The
[handoff](../next.md) says where to work next.
