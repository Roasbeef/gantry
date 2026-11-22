# Start Gantry locally and grow a fleet

**Status** · Proposed · 2026-11-22 · Based on `2c15b84`

**Make the first successful build one command on an installed Linux host
with Docker. Give the deployment a saved profile so adding a worker or
changing controller topology leaves projects and agents using the same API.**

Today an operator installs a release, writes TOML, sets three role tokens,
starts `gantryd`, and configures each worker slot. Workers already pull
work over HTTP and can share one HTTPS gateway origin. Ra persists each
controller's node name with its local state. The installed binary can
switch releases atomically, and a worker's directory carries its custody
journal across restarts.
[Runbook](../running.md) · [Runtime architecture](../architecture/runtime.md)

## The first ten minutes

These command sketches describe the proposed interface.
Start from a versioned release for the host architecture. A release
catalogue and verified checksums would let onboarding download and stage
that release without a compiler. Reuse the current atomic installer.

```sh
# On the laptop or Linux VM
gantry init --local
gantry fleet status

# On an always-on server
gantry init --server --url https://gantry.example

# On a laptop using the server
gantry connect https://gantry.example --profile remote
```

Local init prepares a user-owned profile, creates the role credentials,
starts a loopback controller and one supervised worker when Docker is
available, and runs a small fixture through the normal build API. It
prints the endpoint, controller identity, worker pool, and run ID.
When Docker is unavailable, it starts the controller and reports the
missing worker prerequisite. The fixture lives under Gantry's state
directory. Registering a project is a separate action.

Server init uses the same installer and profile format. It checks the
configured origin, service supervisor, writable state directory, and
the storage and network prerequisites for the requested role. In server
mode a worker is an explicit choice. A laptop can switch between local
and remote profiles, submit through the CLI, and optionally run a worker
for either deployment.

Plan on Linux for controller and worker services. On macOS, the first
path is a client connected to a Linux server or the same Linux release
in a local VM. A cross-platform desktop supervisor can be evaluated once
the Linux lifecycle is proven.

## Add capacity without changing the client URL

| Goal | Operator action | Gantry handles |
| --- | --- | --- |
| Add more slots to an existing host | Choose a pool and capacity budget | A stable slot ID, separate journal, and one supervised process per slot |
| Add a remote build host | Install Gantry and run `gantry worker setup` with the gateway URL, pool, and worker credential | Validate outbound HTTPS and Docker, write the slot configuration, start it, and report first contact |
| Add a controller to a quorum | Enroll the host as an explicitly authorized controller on the private network | Stage certificates and configuration, join through an existing voter, verify catch-up and committed membership, then add its HTTP backend |
| Add a laptop as an operator | Run `gantry connect` and select a saved profile | Store the origin and the granted client credentials |

A worker host can start with one slot, then grow within its host budget.
Existing slots keep their IDs and journal paths. The first remote setup
can import an operator-issued profile and use the existing role token
supplied through stdin or a private credential file. This uses the
current trust model for an operator's own machines. The controller
authorizes active lease replay by worker ID, and the worker locks its
journal directory locally. Reject duplicate slot IDs in managed
configuration and keep an existing ID paired with its original journal.
Per-worker credentials and invitations are a later slice. Each
invitation should be short-lived, single-use, bound to a
deployment and pool, and exchangeable for a revocable worker credential.
The server must enforce that scope on claims and results. Retirement
needs a way for a draining worker to publish its final receipt before
revoking its credential.

Keep each slot profile bound to its original deployment. A controller
currently uses HTTP 409 to tell the worker that its lease is fenced.
Before supporting a change of origin for a live journal, bind worker
requests and lease replies to the queue's stable deployment identity.
An unrelated queue must never be able to acknowledge or clear a spool.

Once host setup is reliable, an optional `gantry fleet add --ssh HOST`
can stage an exact release and run the same setup over the operator's
existing SSH configuration. Keep the on-host command available for
cloud-init and machines that only dial out.

Workers reach the gateway over outbound HTTPS. An outbound connector can
publish a loopback controller API to a gateway. Ra voters use the private
controller network for replication and share the blob store. The
gateway's `/ready` probe establishes quorum access. Voter catch-up and
gateway admission are separate checks.

Loom's enrollment bundles and the separation of learners from voters
are useful precedents. Gantry can first borrow the workflow of
provisioning a host, reporting the join outcome, and preserving its
identity. Implementing controller enrollment requires checking what
Gantry's pinned Khepri/Ra interface can guarantee for join, catch-up,
promotion, and removal.
[Loom enrollment and upgrades](https://github.com/Roasbeef/loom/blob/9aa1383e620aff97aad4acfa3f1d91ce53642b50/docs/distributed-setup.md#3a-adding-replacing-and-removing-nodes)

## Move from a laptop to an always-on service

Adding workers keeps the existing queue on the laptop. Moving the queue
preserves its runs, receipts, leases, and submit intents, so it needs a
separate migration procedure. For a deployment intended to grow a quorum,
choose the first controller's stable private name at initialization.
For a loopback-only deployment, prove a fenced cutover to another
host or identity before offering it as a managed operation.

That cutover needs an explicit plan to stop admissions, settle or
reconcile outstanding work, back up queue state and referenced blobs,
verify the target, and switch the stable API origin. Only one
deployment may hold submission authority at a time. A laptop that
sleeps can participate as a client or worker. Keep the shared service's
voting majority on durable, always-on hosts.

## Maintain what was installed

Use a `gantry fleet` namespace for deployment commands. The existing
`gantry status RUN_ID` remains the build query. Fleet commands should
offer structured output and actionable errors. A `gantry fleet doctor`
report can distinguish an unavailable API, a missing quorum, a shared
blob mount failure, a missing Docker daemon, and a slot with an
unpublished result. Keep a dry-run update plan separate from applying
the update. Check readiness and membership on the voter being updated.

- **Rerun setup** to reconcile missing managed files and preserve the
  profile's identity, credentials, and state. Interrupted setup resumes
  its recorded phase. A missing Ra directory for an existing deployment
  requires explicit recovery.
- **Drain a worker** by stopping new claims, resolving any claim already
  in flight, and publishing the active result before stopping. A claim
  can commit before the worker receives or journals it. Drain needs a
  recovery operation that can recover that lease without allocating new
  work. An offline slot with uncertain custody requires recovery or proof
  that the old action cannot still run.
- **Update or roll back** by staging the immutable release, checking
  configuration and stored-data compatibility, and restarting under
  the service supervisor. Renew controllers one at a time with a
  readiness check between restarts. Rollback needs a compatible prior
  release. Slot identity and journal paths survive both operations.
- **Back up and restore** the queue together with referenced blobs.
  Keep an operator-visible runbook and rehearse restoration before
  automating it.

## Build in slices

| Slice | Exit condition |
| --- | --- |
| Local init and diagnostics | An installed release boots on a clean Linux host and passes a fixture. Interrupt and rerun init and verify that it keeps the same profile, node, and slot identities. |
| Remote setup and profiles | A second host adds a worker through a stable gateway using the existing token. The worker completes a job with the expected pool and reopens its journal on restart. A laptop can choose the remote profile. |
| Maintenance | Kill upgrade or drain at each durable step. Verify that retry preserves journal ownership and that a slot stops receiving new work once draining. |
| Enrollment and controller lifecycle | Exercise lost and replayed enrollments, revoked credentials, minority refusal, staged membership, and gateway routing with real voters. Rehearse a single-controller migration before offering managed cutover. |

Keep the lifecycle and authorization decisions in typed Gleam.
Use typed adapters for supervisor, filesystem, network, and Ra
effects. Run deterministic simulation for interruption and reply loss.
Exercise service and membership changes in the installed-release
end-to-end gate. Extend the queue safety model when a feature can
change lease fencing or submission authority.
[State machine design](../architecture/state-machines.md) ·
[Queue verification](../queue-verification.md)
