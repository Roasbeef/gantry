//// Resolve trusted manifests against immutable source trees.

import gantry/blobs
import gantry/config
import gantry/fault.{type Fault}
import gantry/git
import gantry/github
import gantry_core/graph
import gantry_core/queue
import gantry_core/request
import gantry_core/sandbox
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// Stage a pinned revision, including proposed changes to its manifest.
///
/// ## Examples
///
/// ```gleam
/// // prepare.build(cfg, repo, pinned)
/// ```
pub fn build(
  cfg: config.Config,
  repo: config.Repository,
  pinned: request.Build,
) -> Result(List(queue.Task), Fault) {
  // The request carries a full object ID, so a ref change cannot retarget
  // this build. Its ad hoc action already passed the request rules.
  use s <- git.session(cfg, repo)
  use sha <- result.try(git.fetch(s, request.revision(pinned)))
  tasks(
    cfg,
    repo,
    s,
    sha,
    sha,
    request.target(pinned),
    request.build_id(pinned),
    request.action(pinned),
  )
}

/// Pin the heads of an ordered group at admission. The pins are what the
/// submitter reviewed, and preparation later refuses a group whose pulls moved.
///
/// ## Examples
///
/// ```gleam
/// // prepare.pin(cfg, repo, group)
/// ```
pub fn pin(
  cfg: config.Config,
  repo: config.Repository,
  group: request.Submit,
) -> Result(List(queue.Member), Fault) {
  use s <- git.session(cfg, repo)
  list.try_map(request.pulls(group), fn(n) { member(cfg, repo, s, n) })
}

/// What preparing a waiting group produced.
pub type Prepared {
  /// The candidate on the current branch tip, and its staged action graph.
  Ready(candidate: queue.Candidate, tasks: List(queue.Task))

  /// A definite refusal that the queue records. A `Fault` instead means the
  /// outcome is unknown, and the caller retries later.
  Refusal(failure: queue.PrepareFailure)
}

/// Build a waiting group's candidate on the branch's current tip and stage
/// its action graph. This is the one place a group is integrated, and it
/// runs only when the group heads a free lane, so the base it records is the
/// tip that the landing will expect.
///
/// A pinned member that moved, a merge that conflicts, and a provider or
/// manifest refusal are `Refusal`s. A Git or GitHub failure is a `Fault`.
///
/// ## Examples
///
/// ```gleam
/// // prepare.candidate(cfg, repo, preparation)
/// ```
pub fn candidate(
  cfg: config.Config,
  repo: config.Repository,
  preparation: queue.Preparation,
) -> Result(Prepared, Fault) {
  let pinned = queue.preparation_members(preparation)
  let branch = queue.preparation_branch(preparation)

  // The registered branch is the one lane this repository can land on.
  use Nil <- result.try(case branch == repo.branch {
    True -> Ok(Nil)
    False -> Error(fault.Internal("registered branch changed while waiting"))
  })

  use s <- git.session(cfg, repo)
  use base <- result.try(git.fetch(s, "refs/heads/" <> branch))
  use moved <- result.try(first_moved(cfg, repo, s, pinned))

  // A moved pin is refused before any merge work.
  case moved {
    Some(failure) -> Ok(Refusal(failure))
    None -> {
      use merged <- result.try(integrate(s, base, pinned))

      // A conflict is refused. Otherwise stage the graph on the merge commit.
      case merged {
        Error(failure) -> Ok(Refusal(failure))
        Ok(commit) -> stage(cfg, repo, s, base, commit, pinned)
      }
    }
  }
}

/// Re-read each pinned pull and report the first one that no longer matches
/// its pin, or that the provider now refuses.
fn first_moved(
  cfg: config.Config,
  repo: config.Repository,
  s: git.Session,
  pinned: List(queue.Member),
) -> Result(Option(queue.PrepareFailure), Fault) {
  list.try_fold(pinned, None, fn(found, pin) {
    // The earliest failure stands, and later pulls are not read.
    case found {
      Some(_) -> Ok(found)
      None ->
        case member(cfg, repo, s, pin.pull) {
          Ok(current) if current == pin -> Ok(None)
          Ok(_) -> Ok(Some(queue.MemberMoved(pin.pull)))
          Error(fault.Invalid(detail)) | Error(fault.NotFound(detail)) ->
            Ok(Some(queue.Refused(detail)))
          Error(other) -> Error(other)
        }
    }
  })
}

/// Merge the pinned heads onto the base in order, one integration commit per
/// member. A conflict returns the typed refusal instead of a commit.
fn integrate(
  s: git.Session,
  parent: String,
  members: List(queue.Member),
) -> Result(Result(String, queue.PrepareFailure), Fault) {
  // Each member's commit becomes the parent of the next.
  case members {
    [] -> Ok(Ok(parent))
    [m, ..rest] -> {
      use merged <- result.try(git.merge_tree(s, parent, m.head))

      // A conflicted tree has no commit to build on.
      case merged {
        git.Conflicted(detail) ->
          Ok(
            Error(queue.Unmergeable(
              "pull " <> int.to_string(m.pull) <> ": " <> detail,
            )),
          )
        git.Merged(tree) -> {
          use date <- result.try(merge_date(s, parent, m.head))
          let author =
            git.Session(..s, env: [
              #("GIT_AUTHOR_DATE", date),
              #("GIT_COMMITTER_DATE", date),
              ..s.env
            ])
          use sha <- result.try(
            git.command(author, [
              "commit-tree",
              tree,
              "-p",
              parent,
              "-p",
              m.head,
              "-m",
              "Integrate pull " <> int.to_string(m.pull),
            ]),
          )
          use commit <- result.try(git.oid(s, string.trim(sha)))
          integrate(s, commit, rest)
        }
      }
    }
  }
}

/// Stage the manifest's action graph for the integration commit and publish
/// its bundle. A manifest or input the controller rejects is a refusal.
fn stage(
  cfg: config.Config,
  repo: config.Repository,
  s: git.Session,
  base: String,
  commit: String,
  pinned: List(queue.Member),
) -> Result(Prepared, Fault) {
  // A manifest the controller rejects ends the wait. Anything else retries.
  case tasks(cfg, repo, s, base, commit, repo.target, "", None) {
    Error(fault.Invalid(detail)) -> Ok(Refusal(queue.Refused(detail)))
    Error(other) -> Error(other)
    Ok(plan) -> {
      use Nil <- result.try(git.preserve(cfg, repo, s, base, commit))
      Ok(Ready(queue.candidate(repo.branch, base, commit, pinned), plan))
    }
  }
}

/// A merge timestamp one second after its newest parent is stable on replay.
fn merge_date(
  s: git.Session,
  parent: String,
  head: String,
) -> Result(String, Fault) {
  use dates <- result.try(
    list.try_map([parent, head], fn(sha) {
      use value <- result.try(
        git.command(s, ["show", "-s", "--format=%ct", sha]),
      )
      int.parse(string.trim(value))
      |> result.replace_error(fault.Internal("invalid Git parent timestamp"))
    }),
  )
  let time = list.fold(dates, 0, int.max) + 1
  Ok("@" <> int.to_string(time) <> " +0000")
}

/// Resolve a pull’s current revision and configured target policy.
///
/// ## Examples
///
/// ```gleam
/// // prepare.member(cfg, repo, s, 1)
/// ```
pub fn member(
  cfg: config.Config,
  repo: config.Repository,
  s: git.Session,
  n: Int,
) -> Result(queue.Member, Fault) {
  use sha <- result.try(git.fetch(
    s,
    "refs/pull/" <> int.to_string(n) <> "/head",
  ))

  // A local pull ref supplies the pin. GitHub also supplies its targeting policy.
  case repo.provider {
    config.Local(_) -> Ok(queue.Member(n, sha))
    config.GitHub(target) -> {
      use pull <- result.try(github.read_pull(cfg.github_token, repo.name, n))

      // Resolve the GitHub admission branch from the current repository policy.
      let allowed = case target {
        config.DefaultBranch -> pull.default_branch
        config.RegisteredBranch -> repo.branch
      }

      use branch <- result.try(github.validate_submission(pull, sha, allowed))

      // Only the operator-selected branch can receive this integration.
      case branch == repo.branch {
        True -> Ok(queue.Member(n, sha))
        False -> Error(fault.Invalid("unexpected pull target"))
      }
    }
  }
}

/// Resolve the selected graph against policy, then stage immutable Git archives.
fn tasks(
  cfg: config.Config,
  repo: config.Repository,
  s: git.Session,
  base: String,
  revision: String,
  target: String,
  id: String,
  adhoc: Option(graph.Action),
) -> Result(List(queue.Task), Fault) {
  // An ad hoc result has a private cache scope. Declared targets share a
  // scope. The request rules have already closed an ad hoc action over the
  // staging rules and rejected its graph edges.
  use #(actions, scope) <- result.try(case adhoc {
    Some(action) -> Ok(#([action], "ad-hoc:" <> id))
    None -> {
      use #(status, oid) <- result.try(
        git.raw(s, ["rev-parse", "--verify", base <> ":gantry.json"]),
      )

      // The commit is already local, so a nonzero exit means the manifest is
      // missing, which is a refusal. A fault running Git stays an error.
      use Nil <- result.try(case status {
        0 -> Ok(Nil)
        _ -> Error(fault.Invalid("revision has no gantry.json"))
      })

      use file <- result.try(git.command(s, ["unpack-file", string.trim(oid)]))

      // The checkout lands beside the mirror, so remove it once it is read.
      let path = s.dir <> "/" <> string.trim(file)
      let read = simplifile.read(path)
      let _ = simplifile.delete_file(path)
      use manifest <- result.try(
        read
        |> result.replace_error(fault.Internal("cannot read build manifest")),
      )
      graph.compile(manifest, target)
      |> result.map(fn(actions) { #(actions, "declared") })
      |> result.map_error(fault.Invalid)
    }
  })

  // Git gives info/attributes the highest priority, including for attributes
  // inherited from nested paths. Fix export and checkout conversions before
  // projecting tree blobs so packaging rules cannot omit or rewrite inputs.
  use Nil <- result.try(
    simplifile.create_directory_all(s.dir <> "/info")
    |> result.replace_error(fault.Unavailable(
      "cannot configure raw Git projection",
    )),
  )
  use Nil <- result.try(
    simplifile.write(
      s.dir <> "/info/attributes",
      "* -export-ignore -export-subst -text -crlf !eol -ident !filter !working-tree-encoding\n",
    )
    |> result.replace_error(fault.Unavailable(
      "cannot protect raw Git projection",
    )),
  )

  list.try_map(actions, fn(action) {
    use bytes <- result.try(archive(s, revision, action.inputs))
    use source <- result.try(blobs.put(cfg.blobs, bytes))

    // A strict task keeps the identity it had before profiles existed, so
    // its proofs stay valid. Any wider profile is part of the key, so its
    // proofs can never satisfy a strict task.
    let profile = case repo.sandbox {
      sandbox.Strict -> []
      sandbox.Userns -> [json.string(sandbox.name(repo.sandbox))]
    }

    let identity =
      json.to_string(
        json.array(
          [
            json.string("gantry-action-v1"),
            json.string(scope),
            json.string(repo.name),
            json.string(repo.pool),
            json.string(repo.image),
            json.string(source),
            graph.encode_action(action),
            ..profile
          ],
          fn(i) { i },
        ),
      )
    let recipe = blobs.digest(<<identity:utf8>>)
    Ok(queue.Task(action, source, recipe, repo.pool, repo.image, repo.sandbox))
  })
}

/// The tar bytes of an action's declared inputs at a revision.
///
/// ## Examples
///
/// ```gleam
/// // prepare.archive(s, revision, ["src"])
/// ```
fn archive(
  s: git.Session,
  revision: String,
  inputs: List(String),
) -> Result(BitArray, Fault) {
  case inputs {
    // An action with no inputs receives a valid empty archive.
    [] -> Ok(empty_archive())
    _ -> {
      // The whole-tree projection maps to an empty Git pathspec.
      let paths = case inputs {
        ["."] -> []
        other -> other
      }

      let path = git.scratch(s, "source.tar")
      let read = {
        use _ <- result.try(git.command(
          s,
          list.append(
            [
              "archive",
              "--format=tar",
              "--mtime=2000-01-01T00:00:00Z",
              "--output",
              path,
              revision <> "^{tree}",
              "--",
            ],
            paths,
          ),
        ))
        use info <- result.try(
          simplifile.file_info(path)
          |> result.replace_error(fault.Unavailable(
            "cannot inspect Git archive",
          )),
        )

        // Check the protocol transfer bound before allocating the archive in memory.
        use Nil <- result.try(case info.size <= blobs.limit {
          True -> Ok(Nil)
          False ->
            Error(fault.Invalid("source archive exceeds worker transfer limit"))
        })

        simplifile.read_bits(path)
        |> result.replace_error(fault.Unavailable("cannot read Git archive"))
      }
      let _ = simplifile.delete_file(path)
      read
    }
  }
}

/// A tar archive of no members: two zero blocks, padded to tar's default
/// ten-block record. GNU tar writes the same 10240 zero bytes for an empty
/// member list, so the source digest of an action with no inputs is
/// unchanged by writing the bytes natively.
///
/// ## Examples
///
/// ```gleam
/// assert bit_array.byte_size(prepare.empty_archive()) == 10_240
/// ```
pub fn empty_archive() -> BitArray {
  <<0:size(81_920)>>
}
