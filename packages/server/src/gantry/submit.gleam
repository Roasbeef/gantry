//// Replay only the committed exact-candidate intent. An indeterminate remote
//// observation or push retains the lane for later reconciliation.

import gantry/config
import gantry/git
import gantry/github
import gantry/prepare
import gantry_core/queue
import gleam/list
import gleam/result

/// Return the observed landing decision. An outer error keeps the intent open.
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
) -> Result(Result(Nil, queue.Block), String) {
  let c = queue.intent_candidate(intent)

  // Confirm the registered remote still owns the intent’s lane.
  use Nil <- result.try(
    case
      queue.intent_repo(intent) == repo.name
      && queue.candidate_branch(c) == repo.branch
    {
      True -> Ok(Nil)
      False -> Error("landing configuration changed")
    },
  )

  use s <- git.session(cfg, repo)
  let target = "refs/heads/" <> queue.candidate_branch(c)
  use observed <- result.try(git.fetch(s, target))
  use _ <- result.try(
    git.command(s, [
      "fetch",
      "--quiet",
      "--no-tags",
      "--",
      git.bundle(cfg, repo, queue.candidate_commit(c)),
      "refs/heads/candidate",
    ]),
  )
  use restored <- result.try(git.oid(s, "FETCH_HEAD"))
  use ff <- result.try(git.ancestor(
    s,
    queue.candidate_base(c),
    queue.candidate_commit(c),
  ))

  // The bundle must restore the tested commit and preserve the expected base.
  use Nil <- result.try(case ff && restored == queue.candidate_commit(c) {
    True -> Ok(Nil)
    False -> Error("invalid stored candidate ancestry or identity")
  })

  use landed <- result.try(git.ancestor(s, queue.candidate_commit(c), observed))

  // History confirms a landing, excludes it, or permits replay of the same update.
  case landed, observed == queue.candidate_base(c) {
    True, _ -> Ok(Ok(Nil))
    False, False -> Ok(Error(queue.TargetAdvanced))
    False, True -> {
      use _ <- result.try(
        list.try_map(queue.candidate_members(c), fn(m) {
          // GitHub provides policy and head together. A local repository supplies its pull ref.
          case repo.provider {
            config.GitHub(target) ->
              github.can_land(
                cfg.github_token,
                repo.name,
                queue.candidate_branch(c),
                target,
                m.pull,
                m.head,
              )
            config.Local(_) -> {
              use actual <- result.try(prepare.member(cfg, repo, s, m.pull))

              // A changed pin leaves any previous in-flight push unresolved.
              case actual == m {
                True -> Ok(Nil)
                False -> Error("pull head changed while submission unresolved")
              }
            }
          }
        }),
      )

      use _ <- result.try(
        git.command(s, [
          "push",
          "--porcelain",
          "--force-with-lease=" <> target <> ":" <> queue.candidate_base(c),
          "--",
          s.url,
          queue.candidate_commit(c) <> ":" <> target,
        ]),
      )
      Ok(Ok(Nil))
    }
  }
}
