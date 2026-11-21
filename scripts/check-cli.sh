#!/usr/bin/env bash
set -euo pipefail

cli=$(cd -- "$(dirname -- "$0")" && pwd)/gantry
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export GANTRY_URL=http://127.0.0.1:4737
unset GANTRY_TOKEN GANTRY_SUBMIT_TOKEN GANTRY_WORKER_TOKEN
mkdir "$tmp/bin"

# Exercise the real CLI without a running controller or credentials.
"$cli" --help --json | jq -e '
  .schema_version == 1 and .commands.watch.output == "ndjson"
  and .commands.blob.output == "raw" and (."$defs".build.required | index("revision") != null)
' >/dev/null
"$cli" describe submit --output json | jq -e '
  .command == "submit" and .method == "POST" and .route == "/v1/submits"
  and .request_body["$ref"] == "#/$defs/submit"
' >/dev/null

revision=0123456789abcdef0123456789abcdef01234567
"$cli" plan local fixture/project "$revision" check --dry-run --output json |
  jq -e --arg rev "$revision" '
    .dry_run and .method == "POST" and .url == "http://127.0.0.1:4737/v1/plans"
    and .body == {id:"local",repo:"fixture/project",revision:$rev,target:"check",action:null}
  ' >/dev/null
cat > "$tmp/action.json" <<'JSON'
{"name":"diagnostic","argv":["sh","-ec","echo fixture-ready"],"inputs":[],"outputs":["result.txt"]}
JSON
"$cli" run local fixture/project "$revision" check "$tmp/action.json" --dry-run |
  jq -e '.body.action.outputs == ["result.txt"]' >/dev/null
jq -nc --arg rev "$revision" --slurpfile action "$tmp/action.json" '
  {id:"local",repo:"fixture/project",revision:$rev,target:"check",action:$action[0]}
' | "$cli" run --json - --dry-run |
  jq -e '.url | endswith("/v1/runs")' >/dev/null
"$cli" submit --json '{"id":"group","repo":"fixture/project","pulls":[18,12]}' --dry-run |
  jq -e '.body.pulls == [18,12] and (.url | endswith("/v1/submits"))' >/dev/null

expect_error() {
  local wanted=$1 code=$2 actual=0
  shift 2
  "$cli" "$@" > "$tmp/out" 2> "$tmp/err" || actual=$?
  if [[ $wanted != "$actual" ]]; then
    printf 'Expected exit %s, got %s\n' "$wanted" "$actual" >&2
    cat "$tmp/err" >&2
    return 1
  fi
  jq -e --arg code "$code" '.error.code == $code' "$tmp/err" >/dev/null
  [[ ! -s $tmp/out || $code == run_failed ]]
}

"$cli" plan --dry-run -- -local fixture/project "$revision" -check |
  jq -e '.body.id == "-local" and .body.target == "-check"' >/dev/null
http_status=bad retry_after=old expect_error 2 invalid_input status 'local%2Fnext'
jq -e '(.error | has("http_status") or has("retry_after")) | not' "$tmp/err" >/dev/null
GANTRY_URL=http://localhost:65536 expect_error 2 invalid_input plan local fixture/project "$revision" check --dry-run
expect_error 2 invalid_input status '../local'
expect_error 2 invalid_input status $'local\n'
expect_error 2 invalid_input blob 'short'
expect_error 2 invalid_input run --json '{"id":"one"}' --dry-run
expect_error 2 invalid_input run local --json '{}' --dry-run
expect_error 2 invalid_input plan local fixture/project main check --dry-run
expect_error 2 invalid_input submit --json '{"id":"x","repo":"fixture/project","pulls":[1],"pull":[1]}' --dry-run
expect_error 2 invalid_input submit group fixture/project 12 012 --dry-run
expect_error 3 missing_credentials status local
GANTRY_SUBMIT_TOKEN=fixture-token expect_error 3 missing_credentials blob "$(printf '%064d' 0)"

# Stub only transport so argument handling and response processing remain live.
cat > "$tmp/bin/curl" <<'BASH_CURL'
#!/usr/bin/env bash
set -euo pipefail
while (( $# > 1 )); do
  case $1 in
    -o) response=$2; shift 2 ;;
    -D) headers=$2; shift 2 ;;
    -H) shift 2 ;;
    --data-binary) payload=${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
IFS= read -r auth
[[ $auth == "Authorization: Bearer fixture-token" ]]
code=200
: > "$headers"
case $1 in
  */runs/local|*/runs/-local) printf '{"id":"local","phase":"passed","submission":{"kind":"build"},"work":[]}\n' > "$response" ;;
  */runs/failed) printf '{"id":"failed","phase":"failed","submission":{"kind":"build"},"work":[]}\n' > "$response" ;;
  */runs/missing) code=404; printf '{"error":"unknown run"}' > "$response" ;;
  */runs/conflict) code=409; printf '{"error":"run ID already has different inputs"}' > "$response" ;;
  */runs/denied) code=401; printf '{"error":"authentication required"}' > "$response" ;;
  */runs/limited)
    code=429
    printf 'Retry-After: 3\r\n' > "$headers"
    printf '{"error":"too many requests"}' > "$response"
    ;;
  */runs/deadline) exit 7 ;;
  */plans)
    jq -e '.id == "local" and (.action == null)' "$payload" >/dev/null
    printf '{"revision":"0123456789abcdef0123456789abcdef01234567","actions":[]}\n' > "$response"
    ;;
  */blobs/*) printf 'blob\000bytes\n' > "$response" ;;
  *) exit 1 ;;
esac
printf '%s' "$code"
BASH_CURL
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" GANTRY_TOKEN=fixture-token

"$cli" plan local fixture/project "$revision" check --output json |
  jq -e '.actions == []' >/dev/null
"$cli" status local --fields id,phase,submission.kind,work.task,missing --output json |
  jq -e '. == {id:"local",phase:"passed",submission:{kind:"build"}}' >/dev/null
"$cli" status --fields id -- -local |
  jq -e '. == {id:"local"}' >/dev/null
"$cli" watch local --fields id --output json |
  jq -se '. == [{id:"local"}]' >/dev/null
expect_error 1 run_failed watch failed
jq -se '. == [{id:"failed",phase:"failed",submission:{kind:"build"},work:[]}]' "$tmp/out" >/dev/null
expect_error 3 auth_failed watch denied
expect_error 4 not_found status missing
expect_error 5 rate_limited watch limited
jq -e '.error.http_status == 429 and .error.retry_after == "3"' "$tmp/err" >/dev/null
expect_error 6 conflict status conflict
GANTRY_WATCH_SECONDS=1 expect_error 1 watch_timeout watch deadline
printf 'blob\000bytes\n' > "$tmp/expected-blob"
GANTRY_TOKEN= GANTRY_WORKER_TOKEN=fixture-token "$cli" blob "$(printf '%064d' 0)" --output raw > "$tmp/blob"
cmp "$tmp/expected-blob" "$tmp/blob"
printf '%s\n' 'Passed CLI discovery, local validation, dry runs, request/response handling, watch, and binary output.'
