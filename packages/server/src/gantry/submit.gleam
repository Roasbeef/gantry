//// Replay only the committed exact-candidate intent. An indeterminate remote
//// observation or push retains the lane for later reconciliation, and a
//// definite refusal resolves it.
////
//// ## Flow
////
//// `reconcile` fetches the target and the stored bundle, then decides from
//// history alone whether the candidate already landed, the target moved
//// away from the tested base, or the same update can still be replayed.
//// Before a replay it checks policy, and it dispatches the push only when
//// every member passes.
////
//// | Observation | Result |
//// | --- | --- |
//// | Candidate is an ancestor of the target | `Ok(Landed)` |
//// | Target is neither the base nor contains the candidate | `Ok(Refused)` |
//// | Target is the base and policy refuses, and a second look still shows the base | `Ok(Refused)` |
//// | Target is the base and policy passes | push, then `Ok(Landed)` |
//// | Network failure, unknown merge state, unreadable object graph, failed push | `Error`, intent stays open |
////
//// A refusal is definite only before this controller has dispatched a push.
//// A push that this or another controller left in flight can apply after the
//// first observation and make GitHub report the pull as merged. A policy
//// refusal therefore looks at the target again, and a landed candidate wins
//// over the refusal.

import gantry/config
import gantry/fault.{type Fault}
import gantry/git
import gantry/github
import gantry/prepare
import gantry_core/queue
import gleam/list
import gleam/result

/// The decision an observation of the remote supports.
pub type Outcome {
  /// The candidate is part of the target's history.
  Landed

  /// The landing can never proceed, for the stated reason.
  Refused(reason: String)
}

/// Return the observed landing outcome. An error keeps the intent open.
///
/// ## Examples
///
/// ```gleam
/// // submit.reconcile(cfg, repo, intent)
/// ```
pub fn reconcile(
  cfg: config.Config,
  repo: config.Repository,
  intent: queue.Intent,
) -> Result(Outcome, Fault) {
  let c = intent.candidate

  // Confirm the registered remote still owns the intent’s lane.
  use Nil <- result.try(
    case intent.repo == repo.name && c.branch == repo.branch {
      True -> Ok(Nil)
      False -> Error(fault.Internal("landing configuration changed"))
    },
  )

  use s <- git.session(cfg, repo)
  let target = "refs/heads/" <> c.branch
  use observed <- result.try(git.fetch(s, target))
  use _ <- result.try(
    git.command(s, [
      "fetch",
      "--quiet",
      "--no-tags",
      "--",
      git.bundle(cfg, repo, c.commit),
      "refs/heads/candidate",
    ]),
  )
  use restored <- result.try(git.oid(s, "FETCH_HEAD"))
  use ff <- result.try(git.ancestor(s, c.base, c.commit))

  // The bundle must restore the tested commit and preserve the expected base.
  use Nil <- result.try(case ff && restored == c.commit {
    True -> Ok(Nil)
    False ->
      Error(fault.Internal("invalid stored candidate ancestry or identity"))
  })

  use landed <- result.try(git.ancestor(s, c.commit, observed))

  // History confirms a landing, excludes it, or permits replay of the same update.
  case landed, observed == c.base {
    True, _ -> Ok(Landed)
    False, False -> Ok(Refused(advanced))
    False, True -> {
      use verdict <- result.try(check_members(cfg, repo, s, c))
      case verdict {
        github.Permitted -> {
          use _ <- result.try(
            git.command(s, [
              "push",
              "--porcelain",
              "--force-with-lease=" <> target <> ":" <> c.base,
              "--",
              s.url,
              c.commit <> ":" <> target,
            ]),
          )
          Ok(Landed)
        }
        github.Denied(reason) -> confirm_refusal(s, target, c, reason)
        github.Pending ->
          Error(fault.Unavailable("GitHub has not computed the merge state"))
      }
    }
  }
}

const advanced = "target advanced outside the tested candidate"

/// Look at the target once more before a policy refusal becomes final. A
/// push that was in flight when the first observation ran can have applied
/// since, and that landing must not be recorded as a block.
fn confirm_refusal(
  s: git.Session,
  target: String,
  c: queue.Candidate,
  reason: String,
) -> Result(Outcome, Fault) {
  use observed <- result.try(git.fetch(s, target))
  use landed <- result.try(git.ancestor(s, c.commit, observed))
  case landed, observed == c.base {
    True, _ -> Ok(Landed)
    False, False -> Ok(Refused(advanced))
    False, True -> Ok(Refused(reason))
  }
}

/// Judge every member's current source state, stopping at the first one that
/// is not permitted. A transport failure is an error and never a verdict.
fn check_members(
  cfg: config.Config,
  repo: config.Repository,
  s: git.Session,
  c: queue.Candidate,
) -> Result(github.Verdict, Fault) {
  list.try_fold(c.members, github.Permitted, fn(verdict, m) {
    case verdict {
      github.Permitted -> check_member(cfg, repo, s, c, m)
      github.Denied(_) | github.Pending -> Ok(verdict)
    }
  })
}

/// GitHub provides policy and head together. A local repository supplies its
/// pull ref, and a moved pin means the tested candidate is stale.
fn check_member(
  cfg: config.Config,
  repo: config.Repository,
  s: git.Session,
  c: queue.Candidate,
  m: queue.Member,
) -> Result(github.Verdict, Fault) {
  case repo.provider {
    config.GitHub(target) -> {
      use pull <- result.try(github.read_landing_pull(
        cfg.github_token,
        repo.name,
        m.pull,
      ))
      Ok(github.landing_verdict(pull, c.branch, m.head, target))
    }
    config.Local(_) -> {
      use actual <- result.try(prepare.member(cfg, repo, s, m.pull))
      case actual == m {
        True -> Ok(github.Permitted)
        False ->
          Ok(github.Denied("pull head changed while submission unresolved"))
      }
    }
  }
}
