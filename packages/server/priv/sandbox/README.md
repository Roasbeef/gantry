# Sandbox profiles

`userns-seccomp.json` is the seccomp profile for the `userns` sandbox. It is
Docker 23.0.1's default profile (`profiles/seccomp/default.json` in
moby/moby at `v23.0.1`, Apache License 2.0) with one rule appended. The rule
allows `clone`, `mount`, `pivot_root`, `setns`, `umount2`, and `unshare`
without the `CAP_SYS_ADMIN` condition the default puts on them. Nothing else
changes, so `bpf`, `fsopen`, `perf_event_open`, and the rest stay gated.

A worker uses it only when `GANTRY_WORKER_USERNS_SECCOMP` names it. See
`docs/design-notes/sandbox-profiles.md` for the measurement behind it.
