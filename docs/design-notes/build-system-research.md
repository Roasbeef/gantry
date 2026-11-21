# Build system and merge queue research

**Status** · Evidence and proposed implications · 2026-11-21

Gantry's first useful advantage for agents is a short feedback loop with
inspectable decisions. An agent should be able to state what changed,
watch just the relevant work, and retry a failure in context. The build
engine should use the same evidence to decide cache reuse and submission.

## Build semantics and agent diagnostics

| Source | What the source establishes | Gantry consequence |
| --- | --- | --- |
| [Build Systems à la Carte](https://doi.org/10.1145/3236774) | Scheduling and rebuilding are separate choices. Early cutoff avoids propagating work when an input change produces the same output. | Keep graph and invalidation pure. Make an action ready only when its required inputs are resolved. Schedule its execution independently. |
| [Ninja dependency types, pools, and restat](https://ninja-build.org/manual.html) | A graph can distinguish edges that affect outputs from edges that impose ordering. Restat can prune downstream work after an unchanged output. | Name both edge types. Count content changes in action keys. Expose the dependency that made a target wait. |
| [Bazel action graph query](https://bazel.build/query/aquery) and [Build Event Protocol](https://bazel.build/remote/bep) | Bazel exposes analyzed actions and streams structured events with artifact references. | Make identity and typed diff reasons queryable. Keep run events distinct from text logs. Provide an immutable reference to the input and result manifests. |
| [Bazel Remote Execution API](https://github.com/bazelbuild/remote-apis/blob/main/build/bazel/remote/execution/v2/remote_execution.proto) and [SLSA build provenance](https://slsa.dev/spec/v1.2/build-provenance) | Command and input digests describe remote work. Provenance has additional context about the builder, resolved inputs, and invocation. | Record an action key and a separate trusted build proof. The key addresses reusable work. The proof binds the result to policy and the candidate that the queue may land. |
| [Buck2 explain](https://buck2.build/docs/users/commands/explain/), [what-ran](https://buck2.build/docs/users/commands/log/), and [Nix why-depends](https://releases.nixos.org/nix/nix-2.20.9/manual/command-ref/new-cli/nix3-why-depends.html) | People can inspect an action that ran, its command, and a path explaining a dependency. Buck2's raw logs have a separate schema from the commands used to inspect them. | Give agents a bounded, versioned answer with the first changed input, dependency path, attempt identity, and a replay reference. Keep the raw telemetry separate. |
| [Dagger glossary](https://devel.docs.dagger.io/reference/glossary/) | Dagger's function cache keys account for parameters, parent state, and module source. Its engine traces execution. | A recipe edit can change action identity even when the checkout is unchanged. Correlate diagnostics with the recipe rather than scraping nested tool output for cache decisions. |

A first diagnostic API should answer three different questions directly.

- **Why did this run?** Return a typed reason and the evidence that changed,
  such as a changed input path, toolchain, recipe, or execution policy.
  Include old and new digest references for comparisons.
- **Why is it waiting?** Identify the unresolved dependency or the
  capacity requirement, eligible pool, and queue state that prevents a
  claim. Show whether a prerequisite is running or already stopped.
- **What should I try again?** Return the failed action, which prerequisites
  can be reused, and a scoped replay request for the same inputs and
  policy. An agent can also supply a repaired snapshot.

## Placement, durability, and landing

| Source | Consequence for Gantry |
| --- | --- |
| [Buildbarn worker protocol](https://github.com/buildbarn/bb-remote-execution/blob/main/pkg/proto/remoteworker/remoteworker.proto) and [Buildfarm workers](https://buildfarm.github.io/buildfarm/docs/architecture/workers/) | Keep platform, toolchain, isolation and resources explicit. Measure input staging, execution and upload separately. Locality is a useful tie-breaker after eligibility. |
| [Buildkite dispatch](https://buildkite.com/docs/agent/self-hosted/configure/job-dispatch) and [queue routing](https://buildkite.com/docs/agent/queues) | A waiting worker can signal that it has capacity. Keep the shared reservation transaction authoritative. Start with configured resource classes and age-based fairness. Use wait time and saturation traces to judge richer placement. |
| [Ra state machines](https://github.com/rabbitmq/ra/blob/main/docs/internals/STATE_MACHINE_TUTORIAL.md), [Khepri](https://rabbitmq.github.io/khepri/khepri.html), [Oban job uniqueness](https://oban.hexdocs.pm/unique_jobs.html), and [Temporal activities](https://docs.temporal.io/activity-definition) | Consensus or a durable job record can order decisions. An external effect can still be retried or have an unknown outcome. Keep intent and result records, use cross-controller idempotency, and reconcile Git state before allocating the lane to another candidate. |
| [GitHub merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue), [Zuul gating](https://zuul-ci.org/docs/zuul/latest/gating.html), and [Mergify batches](https://docs.mergify.com/merge-queue/batches/) | Separate the number of candidate builds from the number of PRs that land together. Begin with one active candidate per branch and parallel actions across candidates on different branches. Compare queue age and wasted work before introducing speculative successors. |
| [GitHub Actions OIDC claims](https://docs.github.com/en/actions/reference/security/oidc) and [GitHub indirect merges](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/about-pull-request-merges) | A trusted admission workflow can present scoped, short-lived identity. Gantry resolves PR metadata itself. Preserve actual PR head ancestry and link the landed commit so GitHub can recognize the merge. |

A failed batch proves the tested combination failed. It cannot identify
an individual culprit by itself. A later candidate can pass when two
changes together repair a failure, or fail when individually sound
changes interact. Show the tested prefix or subset and its base. Charge
diagnostic or speculative runs against a separate budget, then measure
executor time wasted when their assumed base never lands.

## Reference probes

These observations check two design assumptions on actual tools. Gantry's
own scheduler, cluster behavior, and GitHub reconciliation require the
implementation sign-off.

A Ninja 1.13.2 graph normalized text and copied the normalized product.
It also had a separate order-only prerequisite. The normalizer preserved
the existing output if the bytes had not changed. `ninja -d explain -v`
reported these action counts and the fixture checked the final bytes.

```text
cold actions=3
unchanged_normalized_bytes actions=1
order_only_change actions=1
changed_normalized_bytes actions=2
```

For Gantry, use this behavior as the action-count oracle. Its content
digests should stop propagation when output bytes are identical, including
when the producer ran remotely. A late or stale result cannot substitute
an output digest.

A Git 2.56.1 fixture created two changes and integrated both into a
candidate. An outside update advanced the bare remote before the guarded
push. The fixture checked exit codes, exact target identity, and ancestry.

```text
CANDIDATE first_parent_chain_has_base=1 integrated_pr_heads=2
STALE_PUSH exit=1 decision=stale-info target_preserved=1
RECONCILE exact_tip_after_push=1 still_reachable_after_later_push=1
```

A second bare Git fixture advanced the ref inside pre-receive, after
the client had initiated the guarded push. The server rejected the
update with `incorrect old value provided` and preserved the new tip.

```text
IN_FLIGHT_REF_RACE exit=1 hook_advanced_ref=1 server_ref_update_rejected=1 target_preserved=1
```

Both experiments exercise the expected-old-ref condition using bare Git.
The provider gate still needs a real GitHub repository to
observe branch rules and PR status. The
[verification proposal](depth-signoff.md) defines those checks.
