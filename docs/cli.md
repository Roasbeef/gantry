# Gantry CLI

Use `gantry` from a release or `scripts/gantry` from a source checkout.
The CLI is a Gleam program on the release's bundled BEAM runtime, so it
needs neither jq nor curl. The source shim builds `packages/server` with
Gleam and runs the same `gantry/cli` module, which you can also start with
`gleam run -m gantry/cli -- ARGS` from `packages/server`. The CLI reads
credentials from the environment and runs without prompts. It validates
requests with the controller's own rules in `gantry_core/request`, so a
request that passes locally fails on the controller only for reasons that
need the controller, such as an unregistered repository.

## Discover commands

```sh
gantry --help
gantry --help --json
gantry describe run
gantry describe submit
gantry describe skill
```

Discovery runs without authentication or network access. Machine-readable
help includes positional arguments, option descriptions, endpoint methods,
request schemas, response formats, and exit codes. `gantry describe COMMAND`
returns the metadata for one command. Put options before `--` when a
positional argument starts with a dash, for example `gantry status -- -build`.
Request schemas use local references
into the document's `$defs` object. Object keys in the printed document
are sorted. The `build`, `submit`, and `action` definitions carry
`examples`, and the test suite checks each one against the Gleam rules.

## Load the agent skill

```sh
gantry skill
```

The command writes the bundled `SKILL.md` to standard output as Markdown
with its front matter. Run `scripts/gantry skill` from a source checkout.
Both invocations work offline and require no controller or credentials.
An extracted Linux release also includes the file at
`share/gantry/skill/SKILL.md` relative to its root. Use the command to load
the instructions or redirect its output to a `SKILL.md` file in your
agent's skill directory.

## Plan and run a build

```sh
revision=$(git rev-parse HEAD)
gantry plan check-123 owner/project "$revision" check --output json
gantry run check-123 owner/project "$revision" check --output json
gantry watch check-123 --fields id,phase,submission.kind --output json
```

The revision must be a full lowercase Git SHA. A plan resolves the graph
without admitting a run. A run queues a build against that revision.
An optional fifth positional argument is the path to an ad hoc action JSON
file. Gantry scopes ad hoc action results to the run, and those actions
cannot satisfy submission policy. See `gantry describe run` for the action
schema and defaults.

Keep the same ID and inputs when retrying admission after an ambiguous
response. Use a new ID when the requested inputs change.

## Preview and submit an ordered group

The `--json` option accepts a request object inline. Use `--json -` to
read one object from stdin. Use either JSON or positional arguments in
an invocation. The CLI validates the object and sends its serialized
form. Use standard JSON with unique object keys and decimal integers.
Unknown keys are rejected, both by the CLI and by the controller, so a
misspelled field fails instead of being ignored.

```sh
payload='{"id":"group-12-13","repo":"owner/project","pulls":[12,13]}'
gantry submit --json "$payload" --dry-run --output json
gantry submit --json "$payload" --output json
gantry watch group-12-13 --fields id,phase,submission.kind,submission.candidate.commit
```

`--dry-run` is available on `plan`, `run`, and `submit`. It validates the
request locally and prints the method, URL and body, without credentials or
a controller. The preview checks the base URL scheme, authority form, and
port bounds. Repository registration, commit availability and submit
eligibility are checked by the controller on a live request. A live submit
queues the supplied PRs in order and can advance the project's configured
branch when its build, policy, and Git checks pass.

## Read status and artifacts

```sh
gantry status check-123 --fields id,phase,submission.kind --output json
gantry watch check-123 --output json
gantry blob "$digest" --output raw > artifact.bin
```

`gantry init --local`, `gantry local start`, `gantry worker setup`, and
`gantry worker start` run in the same program. Their profiles, processes,
and exit codes are described in the [deployment runbook](running.md).
`--token-stdin` reads the worker token as one line up to end of input, so
an interactive user types the token, Enter, and Ctrl-D. The token is
echoed on a terminal, so prefer redirecting it from a private file.

Plan, run, submit, status, and describe produce one JSON object. Watch emits
changed run states as NDJSON and ends on a terminal outcome. Failed and
blocked terminal states are included in the stream before exit 1. If the
first poll gets no HTTP status at all, watch fails at once with
`transport_error` instead of waiting out its deadline. After the
controller has answered once, watch retries transport failures and HTTP
5xx until `GANTRY_WATCH_SECONDS` (default 1800). A passed build and a
landed submission exit 0.

Use comma-separated object fields or dotted object paths with `--fields`.
It retains the original object structure, omits missing paths, and leaves
arrays intact when selected as a whole. Keys are printed in sorted order.
Watch prints a new line only when the projected output changes, and
evaluates terminal state from the full response. The default output leaves the full JSON object
available for inspecting work, artifacts, and log digests.

Blob output is raw bytes. Redirect it to a file when retrieving binary
artifacts or logs. A blob ID is a lowercase, 64-character SHA-256 digest.

## Credentials and exit codes

Set `GANTRY_URL` to the controller base URL. Its default is
`http://127.0.0.1:4737`. Use `GANTRY_TOKEN` for plan and run,
`GANTRY_SUBMIT_TOKEN` for submit, and either token for status or watch.
Blob reads authorize the agent or worker credential. The CLI checks
`GANTRY_TOKEN` first and then `GANTRY_WORKER_TOKEN` for blob reads.

Failures emit a JSON object on stderr such as
`{"error":{"code":"not_found","message":"unknown run","http_status":404}}`.
Fields vary by error. An HTTP failure includes `http_status`, and a local
validation failure usually names the offending `field`. The exit codes are
also available through `gantry --help --json`.

| Exit | Meaning |
| --- | --- |
| 0 | Success, including a locally validated dry run |
| 1 | Local resource, transport, or service failure, any HTTP status without a more specific code (including 5xx and 429), watch deadline, or failed or blocked terminal outcome |
| 2 | Invalid arguments, payload, or configuration, or HTTP 400, 411, 413, or 422 |
| 3 | Missing or invalid credentials, or HTTP 401/403 |
| 4 | HTTP 404 or a missing local profile |
| 6 | HTTP 409, a local profile conflict, or a busy profile |

The controller never sends HTTP 429, so earlier releases' exit 5 is gone.
A gateway that rate limits returns exit 1 with `http_status` 429.
The controller's own statuses and error body are in the [HTTP API reference](api.md#errors).
