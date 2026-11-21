# Gantry

Gantry is a build system for coding agents. It plans a native graph of targets
and actions, runs ready work on a shared pool of self-hosted executors, and
returns structured results an agent can inspect and act on. The same build
system can test a group of GitHub PRs and submit the resulting commit.

- [Integrate a repository](docs/integrating.md)
- [Run Gantry and verify it locally](docs/running.md)
- [Runtime architecture](docs/architecture/runtime.md)
- [Design and scope](docs/design-notes/central-build-submit-queue.md)
- [Proposed architecture](docs/architecture/build-and-submit.md)
- [Pure decisions and durable effects](docs/architecture/state-machines.md)
- [Build system and merge queue research](docs/design-notes/build-system-research.md)
- [Verification proposal](docs/design-notes/depth-signoff.md)
- [Current handoff](docs/next.md)
