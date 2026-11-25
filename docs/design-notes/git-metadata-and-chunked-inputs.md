# Git metadata and chunked inputs

Status: proposed, slices 4 and 5 of the [handoff](../next.md).

Gantry stages each action a `git archive` tree under a 64 MiB blob limit.
Probing Loom's CI lanes under the worker's exact flags found two causes this
note addresses. Loom's client tests ask Git about the workspace
(`rev-parse --git-dir`, `rev-parse HEAD^{commit}`, `status`, `ls-files`), and
there is no `.git`, so the most common client error was "repository metadata
query failed" (105 occurrences across two shards). And Loom's source tree is
87.5 MiB and the `conformance` closure 65.7 MiB, so neither fits in one blob.

## Slice 4: a declared action receives a shallow `.git`

### Manifest syntax

An action may carry one new optional key:

```json
{ "name": "client", "argv": ["make", "client"], "git": "shallow" }
```

`git` is `"none"` (the default, and what an absent key means) or
`"shallow"`. No other spelling decodes. The same key is accepted in an ad hoc
action file, and `request.action_keys` gains `git`. In Gleam the field is
`graph.Action.git: graph.Metadata`, with variants `NoGit` and `Shallow`, so a
policy match is exhaustive.

### What `shallow` stages

The controller builds a second archive, `git.tar`, for the commit the action
is built from (the pinned commit for a build, the integration commit for a
candidate). It holds a real repository at `.git`:

- `objects/pack/pack-*.{pack,idx}` from `git fetch --depth 1` of that commit
  out of the mirror, so the commit, its trees and its blobs are present and
  the parents are not;
- `shallow` listing the commit, so Git treats the missing parents as a cut;
- `HEAD` as a detached head at the commit, and an index from `git read-tree`
  so `status` and `ls-files` have a baseline;
- a four-line `config` with no remote and no promisor settings, because
  Loom refuses a partial configuration.

The worker extracts `git.tar` after `source.tar`, so `.git` is tar-ordered
like any other member. `graph.valid_path` keeps rejecting `.git` as a declared
input or output, and the worker's source check keeps rejecting a `.git` entry
in `source.tar`. Only `git.tar` may write under `.git/`, and every entry in it
must begin with `.git/`; the worker refuses the archive otherwise.

### Key rules

The action recipe is a hash of an identity array. Today it is
`["gantry-action-v1", scope, repo, pool, image, source, action]`.

1. An action with `NoGit` hashes exactly that array. `encode_action` omits
   `git` when it is `NoGit`, so every existing key is unchanged. This is the
   guard's "and only then".
2. An action with `Shallow` appends `["git-shallow-v1", commit]` to the array
   and carries `"git":"shallow"` inside the encoded action. The commit ID
   names the commit object, hence its parents' IDs, message and dates, which
   are everything the shallow repository exposes. The key does not hash the
   pack bytes, because Git may encode the same objects differently.
3. Consequently an action that declares `shallow` misses the cache on every
   new commit even when its tree is unchanged. That is the price of reading
   the commit, and a declared action pays it, not its neighbours.

### Wire and storage changes

`queue.Task` gains `git: Option(Input)`, where `Input` is defined under
slice 5. The task JSON adds an optional `git` object, and the action JSON adds
the optional `git` string. Both default to none when absent, so a durable
snapshot written before this change decodes unchanged. No existing HTTP field
changes meaning. The new fields appear in the claim response because the
worker needs them, and they are additive.

## Slice 5: inputs larger than one blob

### Input layouts

`queue.Input` is one of:

- `Blob(digest)`: the object is the archive, as today.
- `Chunked(digest)`: the object is a chunk manifest.

`queue.Task.source` becomes an `Input`. On the wire the task keeps its
`source` string (the blob or manifest digest) and adds `source_layout`,
`"blob"` or `"chunks"`, defaulting to `"blob"`. An old snapshot and an old
worker's claim response therefore read the same, and only a chunked source
carries the new tag.

### The chunk manifest

A chunk manifest is a small JSON blob, decoded by `gantry_core/chunks`:

```json
{ "version": 1, "total": 91750400, "digest": "<sha-256 of all bytes>",
  "chunks": [ { "digest": "<sha-256>", "length": 33554432 }, ... ] }
```

The decoder is total and constructs only valid values. It refuses a version
other than 1, an empty chunk list, a chunk of length zero or above
`chunk_limit` (32 MiB), a chunk count above 64, a `total` that is not the sum
of the lengths, and a `total` above `input_limit` (512 MiB). Chunks are byte
ranges of one tar stream, so the planner is pure arithmetic
(`chunks.plan(total, chunk_limit)`), is testable on both targets, and never
splits a file's header from its data because the worker reassembles before
anyone reads the tar.

Each chunk is an ordinary blob, so `blobs.put`, the upload route and the
64 MiB bound apply to it unchanged. A source at or under `blobs.limit` stays a
`Blob`, so every existing key and the existing blob tests are untouched.

### Worker staging

The worker fetches the manifest, then each chunk in order, and refuses on the
first violation:

1. the manifest fails its own digest, or decodes to an invalid value;
2. a chunk's byte length differs from the manifest entry;
3. a chunk's SHA-256 differs from the manifest entry;
4. the running SHA-256 over the reassembled bytes differs from `digest` at the
   end.

Chunks are appended to `source.tar` on disk, and the entry check reads the
file by path instead of holding 87 MiB in memory. The dependency archive and
the source archive share `input_limit` instead of `blobs.limit`. The
Docker mount and the extraction command are unchanged, apart from a third
read-only mount and `tar xf /git.tar` when the task has git metadata.

### Failure modes and the simulation

New ways a task can fail to stage: a missing chunk, a corrupt chunk, a chunk
with the wrong length, a bad manifest, a total that disagrees with the
reassembled digest. These all reject the action as an invalid input (a
`Rejected` completion, like a failed digest today), and a missing chunk is
the same transient `Offline` that a missing blob is. The queue never sees
chunks, so its model does not change. The fault schedule in
`packages/core/test/queue_dst.gleam` already injects a worker result that is
lost or corrupted at staging, and gains an `InputCorrupt` kind whose seeded
occurrence yields a `Rejected("input failed SHA-256 verification")` for a task
with a chunked source. The existing invariants (one lease per slot, a rejected
action fails the run, no proof from a rejection) must hold under it.

### Exits and guards

- Slice 4 exit: Loom's client tests that read repository metadata pass under
  the worker's flags with `"git":"shallow"`.
- Slice 4 guard: property tests on the recipe: equal for `NoGit` before and
  after, different for a different commit under `Shallow`, and equal for two
  commits under `NoGit` when their source digest is equal.
- Slice 5 exit: Loom's `static` and `conformance` lanes stage and run.
- Slice 5 guard: unit tests for each chunk violation above, a property test
  that `plan` covers `total` exactly with no chunk above the limit, and the
  existing blob tests.

## Not in this note

The bwrap sandbox (slice 3), streaming a chunk without holding it in memory
(a chunk is at most 32 MiB), and garbage collection of chunk blobs, which
joins the open item for unreferenced blobs.
