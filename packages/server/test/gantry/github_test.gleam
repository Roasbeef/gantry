import gantry/config
import gantry/github.{
  Behind, Blocked, Clean, Closed, Denied, Draft, Merged, Open, Pending,
  Permitted, Ready, Undetermined,
}
import gleam/string

const rest_body =
  "{\"state\":\"open\",\"draft\":false,\"mergeable_state\":\"clean\",\"head\":{\"sha\":\"aaaa\"},\"base\":{\"ref\":\"main\",\"repo\":{\"default_branch\":\"main\"}}}"

const graphql_body =
  "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\"},\"pullRequest\":{\"headRefOid\":\"aaaa\",\"baseRefName\":\"main\",\"state\":\"OPEN\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\"}}}}"

pub fn rest_and_graphql_decode_to_the_same_pull_test() {
  let assert Ok(rest) = github.parse_rest(rest_body)
  let assert Ok(graphql) = github.parse_graphql(graphql_body)
  assert rest == graphql
  assert rest.state == Open
  assert rest.readiness == Ready
  assert rest.mergeability == Clean
}

pub fn unknown_wire_values_fail_to_decode_test() {
  let weird_state = "\"state\":\"open\""
  let assert Error(Nil) =
    github.parse_rest(
      rest_body
      |> replace(weird_state, "\"state\":\"frozen\""),
    )
  let assert Error(Nil) =
    github.parse_graphql(
      graphql_body
      |> replace("CLEAN", "SPARKLY"),
    )
}

pub fn rest_without_a_merge_state_is_undetermined_test() {
  let body = replace(rest_body, "\"mergeable_state\":\"clean\",", "")
  let assert Ok(pull) = github.parse_rest(body)
  assert pull.mergeability == Undetermined
}

pub fn graphql_merged_state_decodes_test() {
  let assert Ok(pull) =
    github.parse_graphql(replace(graphql_body, "\"OPEN\"", "\"MERGED\""))
  assert pull.state == Merged
}

fn current() -> github.Pull {
  let assert Ok(pull) = github.parse_graphql(graphql_body)
  pull
}

pub fn a_current_clean_pull_is_permitted_test() {
  assert github.landing_verdict(current(), "main", "aaaa", config.DefaultBranch)
    == Permitted
}

pub fn a_settled_policy_failure_is_a_denial_test() {
  let denied = fn(pull) {
    case github.landing_verdict(pull, "main", "aaaa", config.DefaultBranch) {
      Denied(_) -> True
      Permitted | Pending -> False
    }
  }
  assert denied(github.Pull(..current(), state: Closed))
  assert denied(github.Pull(..current(), state: Merged))
  assert denied(github.Pull(..current(), head: "bbbb"))
  assert denied(github.Pull(..current(), base: "release"))
  assert denied(github.Pull(..current(), readiness: Draft))
  assert denied(github.Pull(..current(), mergeability: Blocked))
  assert denied(github.Pull(..current(), mergeability: Behind))
}

pub fn an_uncomputed_merge_state_stays_pending_test() {
  let pull = github.Pull(..current(), mergeability: Undetermined)
  assert github.landing_verdict(pull, "main", "aaaa", config.DefaultBranch)
    == Pending
}

pub fn narrowed_branch_policy_denies_only_the_default_target_test() {
  let pull = github.Pull(..current(), default_branch: "trunk")
  let default =
    github.landing_verdict(pull, "main", "aaaa", config.DefaultBranch)
  assert default
    == Denied("registered branch is no longer the repository default")
  assert github.landing_verdict(pull, "main", "aaaa", config.RegisteredBranch)
    == Permitted
}

fn replace(text: String, from: String, to: String) -> String {
  string.replace(text, from, to)
}
