# Let a trusted repository ask for a wider sandbox

**Status** · Proposed 2026-11-24 on `6a561d4`, not built. Slice 3 of the
[handoff](../next.md).

**Add one operator-approved sandbox profile, `userns`, beside the default
`strict`. A repository cannot ask for it. The operator sets it on the
repository's entry in `controller.toml`, the task carries its name, and only
the worker turns the name into Docker flags. A repository with no `sandbox`
line runs with today's flags, byte for byte.**

Real Loom lanes ran on the 32-core worker host under the worker's exact flags.
`static` and `mid` pass. `fast`, `conformance`, and `client` fail, mostly
because Loom's own `bwrap` jail cannot create user namespaces under
`--cap-drop=ALL`. [ADR 003](../adr/003-gantry-docker-worker.md) already names a
per-repository sandbox policy as something that may be added to the Docker
worker. This note proposes that policy and the first profile that policy
carries.

## What a repository may request

A repository may request nothing. The word "request" here means the operator's
repository entry, not anything inside the repository: the image and pool are
already operator policy ([integrating](../integrating.md)), and the sandbox is
the same kind of setting. The four candidates were:

| Candidate | Reaches the exit? | Decision |
| --- | --- | --- |
| User namespaces: a seccomp profile that permits `unshare` and `clone` with `CLONE_NEWUSER` and the mount calls `bwrap` makes, plus the narrowest other relaxations that work | Yes, and it needs no new software on the host | Offer as `userns` |
| Delegated cgroup | No. `bwrap` fails on the user namespace, and a cgroup subtree does not change that. uid 65534 also cannot write a cgroup tree it does not own | Not offered |
| gVisor (`runsc`) | Unproven. Not installed on the worker host, `docker run -d` and `docker create` would need `--runtime` plumbing, and the tmpfs volume and bind staging would need re-verifying | Not offered now. A later constructor |
| Firecracker or Kata | Needs KVM and a root filesystem path, not a Docker image | Not offered |

The type has two values and no reserved ones:

```gleam
pub type SandboxProfile {
  Strict
  UserNamespaces
}
```

Adding `MicroVm` later is one constructor and one match arm in the worker's
mapping function. No wire format changes, because the wire carries a name.

## Who approves it

The operator, in `controller.toml`, on the repository entry:

```toml
[[repository]]
name = "owner/loom"
pool = "linux-wide"
image = "alpine@sha256:..."
sandbox = "userns"        # optional; "strict" is the default
```

`config.validate_repository` decodes the field with `decode.optional_field`
and the default `strict`, and an unknown name is a load error, as an unpinned
image is today. The agent API, the manifest, and the submit request have no
field for it and the request decoder rejects unknown keys
([ADR 002](../adr/002-one-owner-for-request-rules.md)), so a repository has no
route to its own entry.

One more load rule: a pool serves one profile. A `[[repository]]` with
`sandbox = "userns"` must use a pool that no `strict` repository uses. This
is the placement rule. It keeps wide-profile work on the slots the operator
prepared for it, ideally on a host that does not run strict repositories'
slots at all, and it needs no change to the claim protocol because a pool is
already a routing label.

## How the request reaches the worker

1. `Repository` gains `sandbox: SandboxProfile`.
2. `prepare` copies it into the `Task` beside `pool` and `image`
   (`prepare.gleam`, where `queue.Task` is built). `queue.Task` gains the
   field, defined in `gantry_core` so the core stays portable.
3. The recipe identity includes the profile name **only when it is not
   `Strict`**. The identity is a JSON array that already holds
   `repo.pool` and `repo.image`. A `Strict` task keeps its current recipe, so
   existing proofs stay valid, and a proof produced under a wide sandbox can
   never satisfy a strict repository's key.
4. The wire carries the name as a string. `task_decoder` uses
   `decode.field` throughout today, so the new field uses
   `decode.optional_field` with `Strict` as the default. A persisted snapshot
   or an older controller's claim decodes as `Strict`. An unknown name fails
   the decode, and the worker records a typed rejection instead of guessing.
5. In `docker.gleam`, one pure function maps a profile to the flags the
   action container adds. `Strict` adds nothing.

### How the worker enforces it

- The worker knows no path from the wire. It reads the seccomp profile's path
  from its own environment, as it reads `GANTRY_WORKER_*` today:
  `GANTRY_WORKER_USERNS_SECCOMP=/absolute/path/userns.json`. The controller
  never ships a path or a flag.
- A worker without that variable is not capable of `userns`. If it receives a
  `UserNamespaces` task it refuses before creating anything and reports
  `Unavailable`. It never runs the task with the strict flags and calls it
  done, and it never runs it wide without the profile file. The lease lapses
  and the task is reassigned, and the third lapse fails the run with a typed
  reason. A worker with the variable set checks at startup that the file is
  readable, as `preflight` checks the collector image.
- Only the action container widens. The collector container, which reads the
  tmpfs volume the action wrote, keeps `restrictions` and `collector_limits`
  exactly. The action's flags are `action_flags`, so the mapping applies there
  and nowhere else.
- The task decides the flags, not the slot. A slot configured for `userns`
  that receives a `Strict` task runs it with the strict flags.

The flags `userns` adds are a hypothesis until the experiment below runs:
`--security-opt seccomp=<profile>` and `--security-opt systempaths=unconfined`
(a fresh `/proc` in a nested PID namespace needs the unmasked paths). Docker's
`docker-default` AppArmor profile denies `mount`, and Ubuntu 24.04 restricts
unprivileged user namespaces with `kernel.apparmor_restrict_unprivileged_userns`,
so the set may also need `--security-opt apparmor=unconfined` or a custom
AppArmor profile. Network stays none, the root stays read-only, the user stays
65534, and `--cap-drop=ALL` stays.

## How an untrusted repository keeps today's flags

By construction, not by a check that has to remember to run:

- `restrictions` is a constant and the profile mapping never touches it. The
  action's flags are `restrictions`, then `action_flags`, then whatever the
  mapping returns, and `Strict` returns the empty list.
- The only input to the mapping is the task's profile, and the only source of
  that profile is the operator's repository entry, whose default is `Strict`.
- The default is the failure direction. A missing field decodes as `Strict`. A
  mixed-version fleet that ignores the field runs narrower and fails safe.
  An unknown name is rejected, never widened.

The guard test pins this. It asserts that the full argument list of an action
with no `sandbox` line equals today's exactly: `--pull=never`,
`--network=none`, `--cap-drop=ALL`, `--read-only`, `--user=65534:65534`,
`--security-opt=no-new-privileges`, `--log-driver=none`, and the limit flags.
It also asserts that a task for a repository with no profile never reaches the
`UserNamespaces` branch, and that the collector's flags are the same for both
profiles.

## What `userns` exposes

An action under `userns` gets `CAP_SYS_ADMIN` inside its own user namespace.
That opens kernel code that unprivileged processes cannot normally reach
(`nf_tables`, `overlayfs`, mount paths), and it has a record of local
privilege escalations (CVE-2024-1086 and CVE-2022-0185 are in that class).
The host kernel is shared, so a bug there is host root on a worker that holds
its journal, its credential, and every other slot's workspace. The profile
also loosens seccomp, unmasks `/proc` and `/sys` paths, and may relax AppArmor.
This is why the profile is for repositories whose code the operator already
trusts, and why the placement rule above puts them on their own pool. It does
not make an untrusted repository safe to run.

## What this does not fix

The same lanes also fail on tests that write outside `/work`. The root is
read-only and only `/tmp` is writable. A sandbox profile does not change that,
so `fast` and `client` may still fail after `bwrap` works. The measurement
that decides it is the experiment below, then a rerun of the two lanes. If
what remains is `$HOME` or `XDG_*` pointing at a read-only path, the fix is an
environment setting on the action, which is not a sandbox decision and is not
part of this slice. The exit says the lanes pass, so the slice reports what the
rerun shows and names any remaining failure instead of widening the profile
to make it go away.

## Council ruling

The choice of sandbox is the fork that shapes everything above, so it went to
a council: three seats, each reading the code blind to the others, then one
judge (Opus) who saw the packet and the ballots and never the caller's
preference. The options were `userns`, `cgroup`, `microvm`, and a four-way
menu.

**Ruling.** User namespaces behind a closed two-value profile. All three seats
reached this shape. Simplicity and fit called it "`userns`, carried as a closed
name", and risk called it "a menu, built narrow". The judge found the
disagreement was the label and not the design, and chose it on the evidence:
operator-only approval already exists through `Repository` and `prepare`, the
recipe identity already holds pool and image, the collector can stay strict,
and `cgroup` cannot reach the exit.

**Cut.** Reserved variants that the worker would reject. They add decoding,
validation, and simulation surface for profiles nobody can run.

**Dissent.** Risk made the strongest case against: nested user namespaces put
the host kernel's attack surface in reach of action code, and if Ubuntu 24.04
needs `apparmor=unconfined` as well, the exposure grows enough that a microVM
becomes the more honest choice. The mitigations above (operator-only
approval, a dedicated pool, a strict collector, the cache key) fence the
damage. They do not remove it.

**What would reopen it.** The experiment shows `userns` needs
`apparmor=unconfined` or anything wider than a seccomp profile plus
`systempaths=unconfined`, or a `userns` repository ends up on a host that also
runs strict repositories' slots. Then add a `MicroVm` constructor and weigh it.

## Experiment before any code

On the worker host, with the current `restrictions` plus
`--security-opt seccomp=<profile> --security-opt systempaths=unconfined`, run
`bwrap --unshare-all --ro-bind / / true` inside a Loom-image container. If it
fails, add `--security-opt apparmor=unconfined` and run it again. Record which
set passes, and the value of `kernel.apparmor_restrict_unprivileged_userns`.
This settles the one factual split in the ballots, and no Gleam is written
until the answer is in the note.

## Plan

| Step | Exit |
| --- | --- |
| Run the experiment and record the passing flag set here | The note states the exact flags |
| `SandboxProfile` in `gantry_core`, the `Task` field, the optional wire field, the recipe rule | Core tests on BEAM and JavaScript. An old snapshot decodes as `Strict`. A strict task's recipe is unchanged, and a `userns` task's differs |
| `sandbox` in `controller.toml`, with the one-profile-per-pool rule | Config tests for the default, an unknown name, and a shared pool |
| Worker mapping, the profile file preflight, the refusal | The guard test above, and a refusal test for a worker without the file |
| Simulation | The seeded fault schedule gains a slot that cannot run a profile, and a snapshot written before the field. 0 violations over the 1,000-seed `sweep` |
| Loom `fast` and `client` under the approved profile | Both lanes pass, or the note names what remains |

Gates: `make check`, `make e2e` on Linux, and the DST sweep. The TLA model
does not describe task contents, so it should not need to change, and the
step that adds the field confirms that.
