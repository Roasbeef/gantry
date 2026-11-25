//// Resolve trusted manifests against immutable source trees.

import gantry/blobs
import gantry/config
import gantry/git
import gantry/github
import gantry/internal/ffi_host
import gantry_core/graph
import gantry_core/job
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
) -> Result(List(queue.Task), String) {
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
) -> Result(#(queue.Candidate, List(queue.Task)), String) {
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
) -> Result(String, String) {
  use dates <- result.try(
    list.try_map([parent, head], fn(sha) {
      use value <- result.try(
        git.command(s, ["show", "-s", "--format=%ct", sha]),
      )
      int.parse(string.trim(value))
      |> result.replace_error("invalid Git parent timestamp")
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
) -> Result(queue.Member, String) {
  use sha <- result.try(git.fetch(
    s,
    "refs/pull/" <> int.to_string(n) <> "/head",
  ))

  // A local pull ref supplies the pin. GitHub also supplies its targeting policy.
  case repo.provider {
    config.Local(_) -> Ok(queue.Member(n, sha))
    config.GitHub(target) -> {
      let req = job.Request(repo.name, n, sha, job.Submit)
      use pull <- result.try(github.read_pull(cfg.github_token, req))

      // Resolve the GitHub admission branch from the current repository policy.
      let allowed = case target {
        config.DefaultBranch -> pull.default_branch
        config.RegisteredBranch -> repo.branch
      }

      use branch <- result.try(github.validate_pull(pull, req, allowed))

      // Only the operator-selected branch can receive this integration.
      case branch == repo.branch {
        True -> Ok(queue.Member(n, sha))
        False -> Error("unexpected pull target")
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
) -> Result(List(queue.Task), String) {
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
      use manifest <- result.try(
        simplifile.read(s.dir <> "/" <> string.trim(file))
        |> result.replace_error("cannot read build manifest"),
      )
      graph.compile(manifest, target)
      |> result.map(fn(actions) { #(actions, "declared") })
    }
  })

  // Git gives info/attributes the highest priority, including for attributes
  // inherited from nested paths. Fix export and checkout conversions before
  // projecting tree blobs so packaging rules cannot omit or rewrite inputs.
  use Nil <- result.try(
    simplifile.create_directory_all(s.dir <> "/info")
    |> result.replace_error("cannot configure raw Git projection"),
  )
  use Nil <- result.try(
    simplifile.write(
      s.dir <> "/info/attributes",
      "* -export-ignore -export-subst -text -crlf !eol -ident !filter !working-tree-encoding\n",
    )
    |> result.replace_error("cannot protect raw Git projection"),
  )

  list.try_map(actions, fn(action) {
    let path = s.dir <> "/source.tar"

    // The whole-tree projection maps to an empty Git pathspec.
    let paths = case action.inputs {
      ["."] -> []
      other -> other
    }

    // An action with no inputs receives a valid empty archive.
    use _ <- result.try(case action.inputs {
      [] -> {
        use #(status, _) <- result.try(ffi_host.run(
          "tar",
          ["-cf", path, "--files-from", "/dev/null"],
          [],
          10_000,
        ))

        // Require GNU tar to finish writing the empty archive.
        case status {
          0 -> Ok("")
          _ -> Error("cannot create empty input archive")
        }
      }
      _ ->
        git.command(
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
        )
    })

    use info <- result.try(
      simplifile.file_info(path)
      |> result.replace_error("cannot inspect Git archive"),
    )

    // Check the protocol transfer bound before allocating the archive in memory.
    use Nil <- result.try(case info.size <= blobs.limit {
      True -> Ok(Nil)
      False -> Error("source archive exceeds worker transfer limit")
    })

    use bytes <- result.try(
      simplifile.read_bits(path)
      |> result.replace_error("cannot read Git archive"),
    )
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
