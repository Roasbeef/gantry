//// A submission's whole life through the store and the reconciler: it is
//// admitted waiting, built when it heads a free lane, worked by a claim and
//// landed by an expected-old-OID push. These tests share one Khepri store,
//// so each uses its own repository name and run IDs.

import gantry/api
import gantry/config
import gantry/reconcile
import gantry/store
import gantry/support.{type Remote}
import gantry_core/protocol
import gantry_core/queue
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile

fn repo_name(prefix: String) -> String {
  "test/" <> support.run_id(prefix)
}

/// Admit an ordered group through the HTTP path's function.
fn admit(
  cfg: config.Config,
  id: String,
  repo: String,
  pulls: List(Int),
) -> Nil {
  let body =
    json.object([
      #("id", json.string(id)),
      #("repo", json.string(repo)),
      #("pulls", json.array(pulls, json.int)),
    ])
    |> json.to_string
  let assert Ok(_) = api.group(cfg, body)
  Nil
}

fn run(id: String) -> queue.Run {
  let assert Ok(Some(found)) = store.find(id)
  found
}

fn phase(id: String) -> String {
  protocol.phase_label(queue.phase(run(id)))
}

/// The candidate of a run that has one.
fn candidate_of(id: String) -> queue.Candidate {
  case run(id).submission {
    queue.Queued(c)
    | queue.Landing(c)
    | queue.Landed(c)
    | queue.Blocked(c, _) -> c
    queue.Build | queue.Waiting(_, _) | queue.Unprepared(_, _, _) ->
      panic as "run has no candidate"
  }
}

/// Claim and pass every action that is ready, as a worker would.
fn work_all() -> Nil {
  case store.claim("test-worker", "default", 1000) {
    Ok(Some(assignment)) -> {
      let queue.Assignment(run: id, task:, lease:) = assignment
      let assert Ok(Nil) =
        store.finish(
          id,
          task.action.name,
          "test-worker",
          queue.lease_serial(lease),
          queue.Succeeded([], string.repeat("0", 64)),
        )
      work_all()
    }
    _ -> Nil
  }
}

fn setup(prefix: String) -> #(Remote, config.Config, String) {
  support.boot_store()
  let r = support.remote()
  let name = repo_name(prefix)
  let #(cfg, _) = support.config_for(r, name, queue.Retention(200, 1000))
  #(r, cfg, name)
}

pub fn a_group_waits_then_is_built_tested_and_landed_test() {
  let #(r, cfg, name) = setup("full")
  let _ = support.pull(r, "1", "a.txt", "a")
  let id = support.run_id("group")

  // Admission pins the member and builds nothing.
  admit(cfg, id, name, [1])
  assert phase(id) == "waiting"
  assert run(id).work == []

  // The first pass builds the candidate on the branch tip and stages work.
  reconcile.pass(cfg)
  assert phase(id) == "pending"
  assert queue.candidate_base(candidate_of(id)) == r.base
  assert list.length(run(id).work) == 1

  // A worker passes the action, and the next pass lands it by push.
  work_all()
  assert phase(id) == "passed"
  reconcile.pass(cfg)
  assert phase(id) == "landed"
  assert support.main_of(r) == queue.candidate_commit(candidate_of(id))
  let _ = simplifile.delete(r.root)
}

pub fn a_second_group_waits_and_is_built_on_the_new_tip_test() {
  let #(r, cfg, name) = setup("held")
  let _ = support.pull(r, "1", "a.txt", "a")
  let _ = support.pull(r, "2", "b.txt", "b")
  let first = support.run_id("first")
  let second = support.run_id("second")
  admit(cfg, first, name, [1])
  admit(cfg, second, name, [2])

  // Only the head of the lane is built. The other never builds on a base
  // that is about to move.
  reconcile.pass(cfg)
  assert phase(first) == "pending"
  assert phase(second) == "waiting"
  assert run(second).work == []

  work_all()
  reconcile.pass(cfg)
  assert phase(first) == "landed"
  let tip = support.main_of(r)
  assert tip == queue.candidate_commit(candidate_of(first))

  // The freed lane builds the second group on the commit the first landed.
  reconcile.pass(cfg)
  assert phase(second) == "pending"
  assert queue.candidate_base(candidate_of(second)) == tip
  work_all()
  reconcile.pass(cfg)
  assert phase(second) == "landed"
  let landed = support.main_of(r)
  assert landed == queue.candidate_commit(candidate_of(second))

  // The history carries both groups' files.
  assert support.git(r.remote, ["ls-tree", "--name-only", landed, "a.txt"])
    == "a.txt"
  assert support.git(r.remote, ["ls-tree", "--name-only", landed, "b.txt"])
    == "b.txt"
  let _ = simplifile.delete(r.root)
}

pub fn a_pull_that_moved_while_waiting_is_unprepared_test() {
  let #(r, cfg, name) = setup("moved")
  let _ = support.pull(r, "1", "a.txt", "a")
  let id = support.run_id("moved")
  admit(cfg, id, name, [1])

  // The pull gets a new head before the group heads the lane.
  let _ = support.pull(r, "1", "a.txt", "changed")
  reconcile.pass(cfg)
  assert phase(id) == "unprepared"
  let assert queue.Unprepared(_, _, queue.MemberMoved(1)) = run(id).submission
  assert support.main_of(r) == r.base
  let _ = simplifile.delete(r.root)
}

pub fn members_that_conflict_are_unprepared_test() {
  let #(r, cfg, name) = setup("conflict")
  let _ = support.pull(r, "1", "same.txt", "one")
  let _ = support.pull(r, "2", "same.txt", "two")
  let id = support.run_id("conflict")
  admit(cfg, id, name, [1, 2])
  reconcile.pass(cfg)
  assert phase(id) == "unprepared"
  let assert queue.Unprepared(_, _, queue.Unmergeable(_)) = run(id).submission
  let _ = simplifile.delete(r.root)
}

pub fn an_unreachable_remote_leaves_the_group_waiting_test() {
  let #(r, cfg, name) = setup("offline")
  let _ = support.pull(r, "1", "a.txt", "a")
  let id = support.run_id("offline")
  admit(cfg, id, name, [1])

  // The remote disappears, so the outcome is unknown and nothing is recorded.
  let assert Ok(Nil) = simplifile.delete(r.remote)
  reconcile.pass(cfg)
  assert phase(id) == "waiting"
  let _ = simplifile.delete(r.root)
}

pub fn a_moved_pull_blocks_the_landing_without_a_push_test() {
  let #(r, cfg, name) = setup("denied")
  let _ = support.pull(r, "1", "a.txt", "a")
  let id = support.run_id("denied")
  admit(cfg, id, name, [1])
  reconcile.pass(cfg)
  work_all()

  // The pull changes after the candidate was tested.
  let _ = support.pull(r, "1", "a.txt", "changed")
  reconcile.pass(cfg)
  assert phase(id) == "blocked"
  let assert queue.Blocked(_, queue.PolicyDenied(_)) = run(id).submission
  assert support.main_of(r) == r.base
  let _ = simplifile.delete(r.root)
}

pub fn a_target_that_advanced_blocks_the_landing_test() {
  let #(r, cfg, name) = setup("advanced")
  let _ = support.pull(r, "1", "a.txt", "a")
  let id = support.run_id("advanced")
  admit(cfg, id, name, [1])
  reconcile.pass(cfg)
  work_all()

  // Someone else lands on the branch first.
  support.git(r.work, ["checkout", "--quiet", "-B", "other", r.base])
  let other = support.commit_file(r.work, "other.txt", "other")
  support.git(r.work, [
    "push",
    "--quiet",
    "-f",
    r.remote,
    other <> ":refs/heads/main",
  ])
  reconcile.pass(cfg)
  assert phase(id) == "blocked"
  let assert queue.Blocked(_, queue.TargetAdvanced) = run(id).submission
  assert support.main_of(r) == other
  let _ = simplifile.delete(r.root)
}

pub fn a_missing_bundle_keeps_the_landing_open_test() {
  let #(r, cfg, name) = setup("bundle")
  let _ = support.pull(r, "1", "a.txt", "a")
  let id = support.run_id("bundle")
  admit(cfg, id, name, [1])
  reconcile.pass(cfg)
  work_all()

  // An unreadable bundle is an unknown outcome, so the intent stays open.
  let bundle =
    cfg.blobs
    <> "/git/"
    <> name
    <> "/"
    <> queue.candidate_commit(candidate_of(id))
    <> ".bundle"
  let assert Ok(saved) = simplifile.read_bits(bundle)
  let assert Ok(Nil) = simplifile.delete(bundle)
  reconcile.pass(cfg)
  assert phase(id) == "landing"
  assert support.main_of(r) == r.base

  // Restoring it lets the same intent resolve.
  let assert Ok(Nil) = simplifile.write_bits(saved, to: bundle)
  reconcile.pass(cfg)
  assert phase(id) == "landed"
  let _ = simplifile.delete(r.root)
}

pub fn retention_trims_finished_runs_through_the_store_test() {
  support.boot_store()
  let r = support.remote()
  let name = repo_name("retain")
  let #(cfg, _) = support.config_for(r, name, queue.Retention(1, 1000))
  let _ = support.pull(r, "1", "a.txt", "a")
  let ids = [
    support.run_id("old"),
    support.run_id("middle"),
    support.run_id("new"),
  ]
  list.each(ids, fn(id) { admit(cfg, id, name, [1]) })

  // Each group is unprepared in turn because the pull moves.
  let _ = support.pull(r, "1", "a.txt", "changed")
  list.each(ids, fn(_) { reconcile.pass(cfg) })

  // Only the newest finished run survives the bound of one.
  let assert Ok(state) = store.read()
  let assert [old, middle, newest] = ids
  assert queue.find(state, old) == Error(Nil)
  assert queue.find(state, middle) == Error(Nil)
  let assert Ok(_) = queue.find(state, newest)
  let _ = simplifile.delete(r.root)
}
