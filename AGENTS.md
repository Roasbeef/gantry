# Gantry

Start with [the handoff](docs/next.md), then read the
[build and submit architecture](docs/architecture/build-and-submit.md) and
[pure decisions and durable effects](docs/architecture/state-machines.md).

Apply Loom's pinned Gleam style. Keep graph and transition decisions in a
portable core. Use opaque types and exhaustive matches. Put storage, clocks,
processes, Git, and FFI behind typed effect boundaries. Decode persisted and
wire data totally. Use domain variants for policy and state fields. Reserve
panics and assertions for tests. Document the invariant each transition
preserves in the module's flow and transition table. A queue decision carries the state it expects to replace.
Durably record externally visible intentions before dispatch and recover them
by identity. Use Weft for supervised process lifecycles and deadlines.

Use native Gleam or a maintained typed binding when it provides the required
behavior. Keep custom Erlang calls private to `gantry/internal/ffi_*` and
document the OTP or library primitive that needs the bridge. Keep policy,
validation, and retry decisions in Gleam. Expose typed requests and domain
outcomes to callers. Keep the core portable across BEAM and JavaScript.

[Loom Gleam style](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/docs/gleam-style.md) ·
[Loom execution guide](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/docs/execution.md)

Work in slices with an independently checkable exit. Record architectural
decisions in `docs/adr/` and proposals in `docs/design-notes/`. Reuse Loom's
linter and pin its provenance. Capture gate exit codes directly, report the
cases exercised, and update `docs/next.md` at the end of the slice.

Keep the queue's safety model and deterministic simulation aligned with
changes to leases, capacity, or submit authority. Extend the seeded fault
schedule when adding a new failure mode. Run the model and use the live
end-to-end gate for effects that cross process or provider boundaries.
