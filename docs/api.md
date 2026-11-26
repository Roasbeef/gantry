# HTTP API and run status

The `gantry` CLI is a thin client over this API, and the worker speaks the
same protocol. Everything here is read from `http_api.gleam`, `api.gleam`,
`fault.gleam`, and `gantry_core/protocol.gleam`. For the CLI's own flags and
exit codes see [the CLI reference](cli.md), and `gantry describe` prints the
request schemas.
[Tour of a request](guide/tour.md#3-the-request)

## Roles and routes

A request carries `Authorization: Bearer TOKEN`. There are four kinds of
credential. The agent token and the submit token are role tokens set in the
controller's environment as `GANTRY_TOKEN` and `GANTRY_SUBMIT_TOKEN` (at least
32 bytes each, and different from each other). A worker token is per worker.
The controller stores only its SHA-256 in a `[[worker]]` entry, and the
worker's identity comes from which entry matches, never from the request body.
The optional view token, `GANTRY_VIEW_TOKEN`, reads run status, the fleet
snapshot, and blobs, and nothing else. It is meant for the dashboard, so a
browser never holds a credential that admits work. It has the same length
floor as the role tokens and must differ from them and from every worker
token.

| Route | Credential | Purpose |
| --- | --- | --- |
| `GET /health` | none | Quorum check, `{"status":"ok"}` |
| `GET /ready` | none | Quorum check for gateways, `{"status":"ready"}` |
| `GET /v1/worker/ready` | worker | Same check, after authenticating the worker |
| `POST /v1/plans` | agent | Resolve a graph without admitting it |
| `POST /v1/runs` | agent | Admit a pinned build |
| `POST /v1/submits` | submit | Admit an ordered group of PRs |
| `GET /v1/runs/{id}` | agent, submit, or view | Read a run's status |
| `GET /v1/fleet` | agent, submit, or view | Read the dashboard's snapshot |
| `POST /v1/claims` | worker | Poll for an assignment |
| `POST /v1/results` | worker | Report a finished action |
| `PUT /v1/blobs/{sha256}` | worker | Upload a log or output |
| `GET /v1/blobs/{sha256}` | agent, view, or worker | Download a blob |
| `GET /ui`, `GET /ui/{file}` | none | The dashboard's page, script and stylesheet |

`/health` and `/ready` return 503 when Ra cannot confirm a majority. Any
other route answers 404. Bodies of POST requests are JSON and at most 256 KiB
(`request.body_limit`). Blobs are at most 64 MiB (`blobs.limit`). Every body
needs a `Content-Length` and no `Transfer-Encoding`.

## Requests

A build request has `id`, `repo`, `revision` (a full lowercase 40-digit SHA),
`target`, and optionally `action` (one ad hoc action, see
[the CLI reference](cli.md#plan-and-run-a-build)). A submit request has `id`,
`repo`, and `pulls`, one to sixteen distinct PR numbers in integration order.
Unknown keys are rejected with 400 (`unknown request field: NAME`).
`/v1/plans` answers `{"revision": SHA, "actions": [...]}` with each action as
`graph.encode_action` renders it. `/v1/runs` and `/v1/submits` answer with the
run object below.

The `id` is the idempotency key. Repeating `/v1/runs` or `/v1/submits` with
the same `id` and the same inputs returns the stored run. The same `id` with
different inputs is 409 `run ID already has different inputs`.

A claim body is `{"worker": ID, "pool": POOL}`. The worker must equal the ID
registered for the credential, or the answer is 403. The answer is 204 with
no body when nothing fits, or 200 with an assignment:

```json
{"run": "check-1",
 "task": {"action": {"name": "verify", "argv": ["make", "check"],
                     "inputs": ["."], "outputs": [], "deps": [],
                     "after": [], "timeout": 900},
          "source": "<sha256>", "recipe": "<sha256>",
          "pool": "linux", "image": "alpine@sha256:..."},
 "lease": {"serial": 7, "worker": "linux-01", "until": 1764000000,
           "attempt": 1, "key": {"recipe": "<sha256>", "dependencies": []}}}
```

`until` is Unix seconds: the claim time plus the action's `timeout` plus 150.
Nothing renews it (see [recovering a lost worker](operations.md#a-worker-is-lost)).

A result body is `{"run", "action", "worker", "serial", "completion"}`.
`completion` is `{"kind":"succeeded","files":[{"path","digest"}],"log":SHA}`
or `{"kind":"rejected","reason":TEXT,"log":SHA}`. Every digest must already be
uploaded, or the answer is 404 `blob unavailable`. A success must list exactly
the action's declared output paths. The answer is `{"accepted":true}`, or 409
`attempt is no longer active` when the serial or worker no longer holds the
lease. The worker treats that 409 as final and clears its journal entry.

A blob upload answers `{"digest": SHA}` and refuses (400) a body whose SHA-256
differs from the path.

## The fleet snapshot

`GET /v1/fleet` answers what the dashboard draws, encoded and decoded by
one module, `gantry_core/fleet`:

```json
{"now": 1764000000, "since": 1763999100,
 "slots": [{"worker": "linux-01", "host": "builder",
            "presence": {"kind": "polled", "pool": "linux", "at": 1763999998}},
           {"worker": "linux-02", "host": null,
            "presence": {"kind": "unseen"}}],
 "runs": [ ...each retained run, as GET /v1/runs/{id} answers it... ],
 "events": [{"kind": "granted", "serial": 7, "run": "check-1", "action": "verify",
             "worker": "linux-01", "pool": "linux", "at": 1763999950, "until": 1764001500},
            {"kind": "settled", "serial": 7, "outcome": "succeeded", "at": 1763999990}],
 "samples": [{"at": 1763999998, "ready": [{"pool": "linux", "count": 4}]}]}
```

`slots` lists every `[[worker]]` entry, with its optional `host` label. A
slot's `presence` is the latest poll that this controller served, kept in
memory and lost on restart, because writing it to the replicated queue would
replicate every idle poll. `unseen` means this controller has not served a
poll from the slot since it started. Behind a gateway that spreads polls
over voters, a live slot can read as `unseen` on one controller. The runs
are read through the indexed layout's run index, without the proof index.

`events` and `samples` are the last fifteen minutes this controller saw, at
most 3,000 entries, held in memory. A `granted` event is recorded once the
claim commits and is keyed by its lease serial, so a replayed poll adds
nothing. A `settled` event is recorded once the result commits. A sample
counts the ready actions per pool each time the snapshot is read, so samples
exist only while some page is watching. `since` is the oldest second the
history covers: the controller's start, the window's start, or the newest
entry dropped by the cap, whichever is latest. Before `since` the history
knows nothing, which is not the same as idle. Expiries and cache reuse happen
inside a claim and have no events; a reader infers a lapse from a grant
without a result whose lease is no longer active.

The route changes nothing in the queue. Reading it records one sample.

## Errors

Every failure carries a kind chosen where it was detected, and the HTTP layer
maps the kind to a status without reading the message
(`fault.status`, `fault.gleam`).

| Status | Kind | Meaning | Caller response |
| --- | --- | --- | --- |
| 400 | `Invalid` | Bad JSON, unknown field, invalid ID, digest or revision, a revision without `gantry.json`, an invalid manifest, a short body | Fix the request |
| 401 | `Unauthorized` | No acceptable credential for this route | Present one |
| 403 | `Forbidden` | The credential names a different worker | Use the right one |
| 404 | `NotFound` | Unknown run, unregistered repository, missing blob, or no such route | Check the name |
| 409 | `Conflict` | The queue refuses the transition: ID reused with other inputs, or the lease is no longer active | Reconcile by ID |
| 411, 413 | none | Missing `Content-Length`, or a body over the route's limit | Fix the request |
| 503 | `Unavailable` | Quorum, storage, Git, or GitHub failed, `queue contention exceeded retry budget`, or `the queue holds the most runs it accepts` | Retry later |
| 500 | `Internal` | Stored state is corrupt or an invariant broke, such as a queue record that does not decode | Operator action |

The body is always `{"error": "message"}`. The CLI wraps it into its own
stderr envelope (`{"error":{"code","message","http_status"}}`).

## Run status

`GET /v1/runs/{id}` returns the stored run plus a derived `phase`. The
durable queue image has no `phase`, and `gantry status` shows it only because
`protocol.encode_run` adds it.

```json
{"id": "check-1", "repo": "owner/project", "revision": "<sha>",
 "target": "check", "phase": "pending",
 "submission": {"kind": "build"},
 "work": [{"task": {...}, "step": {"kind": "active", "lease": {...}}}]}
```

For a group that is still `waiting`, `revision` is empty and `work` is `[]`.

### Phases

| `phase` | Meaning | Terminal |
| --- | --- | --- |
| `waiting` | A pinned group, not yet built because its lane is held | no |
| `pending` | A build or queued candidate with actions still to run | no |
| `passed` | A build whose every action passed or was reused | yes |
| `failed` | An action failed, expired at its last attempt, or was rejected | yes once nothing is active |
| `landing` | A candidate passed and its landing intent is outstanding | no |
| `landed` | The candidate is on the target branch | yes |
| `blocked` | The landing was refused, with a reason | yes |
| `unprepared` | The group could not be turned into a candidate, with a reason | yes |

### Submission kinds

`submission.kind` is `build`, `waiting`, `queued`, `landing`, `landed`,
`blocked`, or `unprepared`. A `waiting` or `unprepared` submission carries
`branch` and `members` (`{"pull", "head"}` pairs). The other group kinds carry
a `candidate` with `branch`, `base`, `commit`, and `members`. The landed
commit is `submission.candidate.commit`.

### Step kinds

| `step.kind` | Fields | Meaning |
| --- | --- | --- |
| `pending` | `attempts` | Not leased, with this many earlier attempts |
| `active` | `lease` | A worker holds the lease |
| `passed` | `proof` | A worker's verified result |
| `reused` | `proof` | A copy of a stored proof with the same repository and key |
| `failed` | `reason`, `log` | The worker rejected the action. `log` is a blob digest |
| `expired` | `attempts`, `log` | The lease lapsed on the last permitted attempt (3) |
| `skipped` | none | Another action in the run failed first |

A `proof` is `{"key", "files": [{"path","digest"}], "log"}`. Fetch `log` and
each file's `digest` with `gantry blob`.

### Reasons

A blocked landing has `submission.reason.kind` of `target_advanced` (the
branch moved outside the candidate) or `policy_denied` with a `detail` (the
provider refused a member). An unprepared group has `reason.kind` of
`member_moved` with the `pull` number, `unmergeable` with a `detail` (the
members do not combine), or `refused` with a `detail` (the provider or the
manifest refused). Text from outside the controller is capped at 1024 bytes.
