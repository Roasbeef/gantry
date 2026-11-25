# Integrate a repository

A project supplies a `gantry.json` at its root. The Gantry operator registers
the repository, required target, worker pool, and digest-pinned worker image
in `controller.toml`, so the image and pool belong to the repository, not to
individual actions. Agents can then build published commits through the API.
A maintainer can submit an ordered group of PRs after the build-only path
works.

## Run an existing check on Gantry

Start with one action that runs the project's existing check command. For a
repository that already runs `make check`, commit this `gantry.json` at the
root of its default branch.

```json
{
  "targets": {"check": ["verify"]},
  "actions": [
    {
      "name": "verify",
      "argv": ["make", "check"],
      "inputs": ["."],
      "outputs": [],
      "timeout": 900
    }
  ]
}
```

The worker image needs `/bin/sh` and `tar` to stage the workspace. It
also needs `make`, the project's toolchain, and any dependencies the
build expects to find. The action runs without network access. The full
tree input works for build systems that discover their own dependencies.
To reuse work across smaller edits, split the check into actions with
declared inputs and outputs. The example shows how a downstream action
receives an upstream file. [Example manifest](examples/gantry.json)

Add the repository to the controller configuration. For GitHub, set
`name` to `owner/repository` and `branch` to the default branch. Set
`target` to `check`, select a worker `pool`, and set `image` to the
pre-pulled image digest. The controller's `GH_TOKEN` needs access to
the registered repository. Deploy the controller and matching workers
using the runbook. [Controller example](examples/controller.toml) · [Runbook](running.md)

GitHub submissions target the default branch by default. To use another
branch, set `branch` to that exact ref name and
`github_target = "registered"` in the controller's repository entry.
Use the same setting on every voter. Gantry checks the PR base and
pinned head and applies GitHub's merge policy to that configured branch.

From the project checkout, run a commit that the registered remote can fetch.
Set `GANTRY_TOKEN` to the build credential before calling the CLI.

```sh
GANTRY_CLI=/path/to/gantry/scripts/gantry
export GANTRY_URL=https://gantry.example
repo=owner/project
revision=$(git rev-parse HEAD)
run_id="pilot-$(date +%s)"

"$GANTRY_CLI" plan "$run_id" "$repo" "$revision" check
"$GANTRY_CLI" run "$run_id" "$repo" "$revision" check
"$GANTRY_CLI" watch "$run_id"
```

The plan shows the selected action closure. Status includes each action's
phase and the digests of its declared outputs and retained log. Use
`gantry blob <sha256>` to fetch the bytes. Keep the same run ID and inputs
when retrying an admission after a lost response. [CLI and API](running.md#use-the-agent-and-submit-api)

## Declare the graph

The manifest has two keys, and the controller decodes nothing else
(`graph.gleam`). The file has no version field, and unknown keys in it are
ignored. Misspelled keys therefore do nothing, unlike in an API request,
which rejects them.

| Key | Meaning |
| --- | --- |
| `actions` | A list of actions, described below |
| `targets` | An object from a target name to the list of actions that must pass |

A target selects its listed actions and everything they reach through `deps`
and `after`. The compiler rejects an empty target, an unknown action name, a
duplicate name, a cycle, and two actions whose outputs overlap.

| Action field | Default | Meaning |
| --- | --- | --- |
| `name` | required | One path component, unique in the manifest |
| `argv` | required | The command and arguments, executed directly with `exec "$@"` after the archives are extracted, so there is no shell expansion |
| `inputs` | `["."]` | Repository paths staged into `/work`, or `"."` for the whole tree. `[]` stages only upstream outputs |
| `outputs` | `[]` | Regular files the action must leave under `/work`. A passing action publishes exactly these |
| `deps` | `[]` | Actions whose output files are staged here and become part of this action's cache key |
| `after` | `[]` | Actions that must pass first, with no files passed and no effect on the key |
| `timeout` | 300 | Wall seconds, 1 to 3600 |

Paths are at most 240 bytes with components of letters, digits, `-`, `.`, and
`_`, and none may be `.`, `..`, or `.git`. Everything else a project might
want to say per action (the image, the pool, the CPU and memory it needs) is
not in the manifest. Image and pool come from the repository entry, and a
slot's resource limits come from the worker that runs it.

Reuse works at the action. Two actions with the same recipe and the same
upstream output bytes share a proof, even across commits. Narrow `inputs`
and real `deps` edges are what turn an unrelated edit into a cache hit.
How many actions run at once is the width of this graph. See
[how work is spread](scheduling.md).

## Submit an ordered group

Use a pilot repository where the configured controller identity can
fast-forward the default branch under its existing rules. Keep the
target protected against rewinds and deletion so recovery can use ancestry
as evidence. Gantry checks that GitHub reports each pinned PR open, ready,
and `CLEAN` before pushing. The branch enforces its rules on the update.

Copy the [manual workflow](examples/github-submit.yml) to
`.github/workflows/gantry-submit.yml` in the project's default branch.
Configure the repository variable `GANTRY_URL` with the controller's
trusted HTTPS endpoint and store `GANTRY_SUBMIT_TOKEN` as a secret. Keep
repository Git credentials on the controller. The submit credential covers
all registered repositories in the deployment's trust domain. Give it to
workflows whose maintainers have that authority. [GitHub workflow example](examples/github-submit.yml)

Use a runner that can reach the controller's HTTPS endpoint. Dispatch the
workflow from the default branch with a JSON list such as `[12,13]` in the
order the heads should be integrated. The same group can be admitted with the CLI.
Set `GANTRY_SUBMIT_TOKEN` in the CLI environment for this path.

```sh
"$GANTRY_CLI" submit pilot-submit-12-13 "$repo" 12 13
"$GANTRY_CLI" watch pilot-submit-12-13
```

The controller compiles the required target from the pinned base's manifest
and runs it on the combined commit. Status `landed` gives the exact tested
commit in `.submission.candidate.commit`. The workflow posts that commit on
each original PR. GitHub can mark the PRs merged when their heads become
reachable from the default branch. A `blocked` result after an external
branch advance calls for a fresh group under a fresh run ID.

If a PR head changes or GitHub policy refuses the push while the target
still equals the pinned base, the group can stay in `landing`. Its
outstanding intent holds the lane, so later groups wait. Include this
case in the pilot when validating operator recovery.
[Runtime architecture](architecture/runtime.md#land-an-ordered-pr-group)

## Check a live deployment

Start with one build-only run, then submit two small PRs in a pilot
repository. Compare the landed SHA with the candidate in the Gantry run
record, check that both pinned heads are ancestors of the landed commit,
and inspect both PR links. The end-to-end harness exercises those Git
invariants with a local bare remote. The live pilot supplies the GitHub
branch policy and PR reconciliation evidence.
[Verification plan](design-notes/depth-signoff.md)

On 2026-11-22 a GitHub Actions runner booted an installed controller and
Docker worker behind a fixture HTTPS endpoint. The default-branch policy
refused the disposable target. With `github_target = "registered"`, the
documented workflow's submission step tested and landed
`0b7c4b298e9a84c332a75958a27751aee0cf07da` on the pilot branch. The job
verified both pinned heads as ancestors, downloaded the verified output,
and replayed the workflow to check that each PR had one comment linking
the final tested commit. GitHub marked both PRs merged. The pilot branch
was unprotected. Rehearse your repository's branch rules and the
controller's write identity as part of deployment. Protected-branch rules are
the one GitHub item still open ([status](architecture/runtime.md#status)).
[Pilot run](https://github.com/Roasbeef/gantry/actions/runs/45058513752) ·
[Pilot PR #6](https://github.com/Roasbeef/gantry/pull/6) ·
[Pilot PR #7](https://github.com/Roasbeef/gantry/pull/7)
