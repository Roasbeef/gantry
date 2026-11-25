//// Resolve trusted manifests against immutable source trees.

import gantry/blobs
import gantry/config
import gantry/fault.{type Fault}
import gantry/git
import gantry/github
import gantry_core/graph
import gantry_core/queue
import gantry_core/request
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

/// Integrate ordered pull heads into a candidate, then stage its action graph.
///
/// ## Examples
///
/// ```gleam
/// // prepare.group(cfg, repo, group)
/// ```
pub fn group(
  cfg: config.Config,
  repo: config.Repository,
  group: request.Submit,
) -> Result(#(queue.Candidate, List(queue.Task)), Fault) {
  // Each distinct pull in the validated request contributes one ordered
  // integration step.
  let pulls = request.pulls(group)
  use s <- git.session(cfg, repo)
  use base <- result.try(git.fetch(s, "refs/heads/" <> repo.branch))
  use members <- result.try(
    list.try_map(pulls, fn(n) { member(cfg, repo, s, n) }),
  )
  use commit <- result.try(
    list.try_fold(members, base, fn(parent, m) {
      use tree <- result.try(
        git.command(s, ["merge-tree", "--write-tree", parent, m.head]),
      )
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
          string.trim(tree),
          "-p",
          parent,
          "-p",
          m.head,
          "-m",
          "Integrate pull " <> int.to_string(m.pull),
        ]),
      )
      git.oid(s, string.trim(sha))
    }),
  )
  use plan <- result.try(tasks(
    cfg,
    repo,
    s,
    base,
    commit,
    repo.target,
    "",
    None,
  ))
  use Nil <- result.try(git.preserve(cfg, repo, s, base, commit))
  Ok(#(queue.Candidate(repo.branch, base, commit, members), plan))
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
      use oid <- result.try(
        git.command(s, ["rev-parse", "--verify", base <> ":gantry.json"]),
      )
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
          ],
          fn(i) { i },
        ),
      )
    let recipe = blobs.digest(<<identity:utf8>>)
    Ok(queue.Task(action, source, recipe, repo.pool, repo.image))
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
