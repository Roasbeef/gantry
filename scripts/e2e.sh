#!/usr/bin/env bash
# Three local voters, one independent worker, real Docker and a bare Git remote.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root/packages/server"
tmp=$(mktemp -d)
declare -a pids=()
cleanup() {
  local status=$?
  trap - EXIT
  for pid in "${pids[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
  if (( status != 0 )); then
    for log in "$tmp"/*.log; do
      [[ -f $log ]] && { echo "$log" >&2; tail -40 "$log" >&2; }
    done
    echo "Retained test directory $tmp" >&2
  else
    rm -rf "$tmp"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export GANTRY_TOKEN="agent-$(openssl rand -hex 24)"
export GANTRY_WORKER_TOKEN="worker-$(openssl rand -hex 24)"
export GANTRY_SUBMIT_TOKEN="submit-$(openssl rand -hex 24)"
cookie=$(openssl rand -hex 20)
node="gantry_e2e_$$"
base_port=${GANTRY_E2E_PORT:-18080}
endpoints=()
for i in 1 2 3; do endpoints+=("http://127.0.0.1:$((base_port+i-1))"); done
image=alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
echo "Worker image $image"
remote="$tmp/remote.git"
source_dir="$tmp/source"
git init -q --bare --initial-branch=main "$remote"
git init -q --initial-branch=main "$source_dir"
g() { git -C "$source_dir" "$@"; }
g config user.email gantry@example.invalid
g config user.name Gantry
cp "$root/scripts/fixtures/e2e/gantry.json" "$source_dir/"
echo 'stable first' > "$source_dir/source.txt"
echo left > "$source_dir/left.txt"
echo right > "$source_dir/right.txt"
g add .
g commit -qm base
base=$(g rev-parse HEAD)
g push -q "$remote" HEAD:refs/heads/main
echo 'stable second' > "$source_dir/source.txt"
g commit -qam normalization
changed=$(g rev-parse HEAD)
g push -q "$remote" HEAD:refs/heads/normalize-change
for pr in 12 13; do
  g checkout -q --detach "$base"
  if [[ $pr == 12 ]]; then file=left; else file=right; fi
  echo "pull-$pr" > "$source_dir/$file.txt"
  g commit -qam "Change $file"
  g push -q "$remote" "HEAD:refs/pull/$pr/head"
done
start() {
  local log=$1
  shift
  setsid "$@" >"$tmp/$log.log" 2>&1 &
  pids+=("$!")
}
wait_for() {
  local description=$1
  shift
  local deadline=$((SECONDS+120))
  until "$@"; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for $description" >&2
      return 1
    fi
    sleep 0.3
  done
}
get() { curl -fsS --connect-timeout 1 --max-time 5 -H "Authorization: Bearer $GANTRY_TOKEN" "$1"; }
healthy() { get "$1/health" >/dev/null 2>&1; }
controller=(gleam run)
worker=(gleam run -m gantry/worker)
cli="$root/scripts/gantry"
if [[ -n ${GANTRY_RELEASE_BIN:-} ]]; then
  controller=("$GANTRY_RELEASE_BIN/gantryd")
  worker=("$GANTRY_RELEASE_BIN/gantry-worker")
  cli="$GANTRY_RELEASE_BIN/gantry"
else
  gleam build
fi
for i in 1 2 3; do
  seed=""
  if (( i > 1 )); then seed="${node}1@127.0.0.1"; fi
  cat > "$tmp/node$i.toml" <<TOML
data_dir = "$tmp/data$i"
blob_dir = "$tmp/blobs"
port = $((base_port+i-1))
seed = "$seed"

[[repository]]
name = "fixture/project"
local_remote = "$remote"
branch = "main"
target = "check"
pool = "default"
image = "$image"
TOML
  start "node$i" env GANTRY_CONFIG="$tmp/node$i.toml" ERL_FLAGS="+S 2:2 -name ${node}$i@127.0.0.1 -setcookie $cookie" "${controller[@]}"
  wait_for "voter $i" healthy "${endpoints[i-1]}"
done
post() {
  curl -fsS --max-time 60 -H "Authorization: Bearer $2" -H 'Content-Type: application/json' --data "$3" "$1" > "$tmp/post.json"
}
poll_status() {
  curl -sS --connect-timeout 1 --max-time 8 -o "$tmp/poll.json" -w '%{http_code}' \
    -H "Authorization: Bearer $GANTRY_WORKER_TOKEN" -H 'Content-Type: application/json' \
    --data '{"worker":"probe","pool":"default"}' "$1/v1/claims"
}
empty_poll() { [[ $(poll_status "$1") == 204 ]]; }
run() {
  post "$1/v1/runs" "$GANTRY_TOKEN" "$(jq -nc --arg id "$2" --arg rev "$3" '{id:$id,repo:"fixture/project",target:"check",revision:$rev}')"
}
worker_urls=$(IFS=,; echo "${endpoints[*]}")
worker_environment=(
  'ERL_FLAGS=+S 2:2' "GANTRY_ENDPOINT=$worker_urls" GANTRY_POOL=default
  GANTRY_WORKER_ID=worker-one "GANTRY_WORKER_DIR=$tmp/journal" "GANTRY_WORKER_GUARD=$tmp"
)
start_worker() {
  start "$1" env "${worker_environment[@]}" "${worker[@]}"
}
stop_worker() {
  local signal=$1 index
  kill "-$signal" -- "-$worker_pid"
  wait "$worker_pid" 2>/dev/null || true
  for index in "${!pids[@]}"; do
    if [[ ${pids[index]} == "$worker_pid" ]]; then unset "pids[$index]"; fi
  done
}
empty_poll "${endpoints[1]}"
empty_poll "${endpoints[1]}"
run "${endpoints[0]}" initial "$base"
post "${endpoints[1]}/v1/claims" "$GANTRY_WORKER_TOKEN" '{"worker":"worker-one","pool":"default"}'
original_serial=$(jq -er 'select(.run == "initial" and .task.action.name == "normalize") | .lease.serial' "$tmp/post.json")
start_worker worker
worker_pid=${pids[3]}
matches() {
  get "$1/v1/runs/$2" > "$tmp/current.json" || return 1
  if jq -e "$3" "$tmp/current.json" >/dev/null; then return 0; fi
  if jq -e '.phase == "failed" or .phase == "blocked"' "$tmp/current.json" >/dev/null; then
    cat "$tmp/current.json" >&2
    exit 1
  fi
  return 1
}
wait_for 'active producer with waiting consumer' matches "${endpoints[1]}" initial '
  [.work[] | {(.task.action.name):.step.kind}] | add == {normalize:"active",collect:"pending"}'
[[ $(jq -er '.work[] | select(.task.action.name == "normalize") | .step.lease.serial' "$tmp/current.json") == "$original_serial" ]]
for voter in 1 2; do
  post "${endpoints[voter]}/v1/claims" "$GANTRY_WORKER_TOKEN" '{"worker":"worker-one","pool":"default"}'
  jq -e --argjson serial "$original_serial" '
    .run == "initial" and .task.action.name == "normalize" and .lease.serial == $serial
  ' "$tmp/post.json" >/dev/null
done
kill -KILL -- "-${pids[0]}"
wait "${pids[0]}" 2>/dev/null || true
unset 'pids[0]'
wait_for 'surviving quorum to complete initial run' matches "${endpoints[1]}" initial '
  .phase == "passed" and all(.work[]; .step.kind == "passed")'
run "${endpoints[2]}" cutoff "$changed"
wait_for 'unchanged normalized bytes to reuse consumer' matches "${endpoints[1]}" cutoff '
  .phase == "passed" and ([.work[] | {(.task.action.name):.step.kind}] | add == {normalize:"passed",collect:"reused"})'
post "${endpoints[2]}/v1/submits" "$GANTRY_SUBMIT_TOKEN" '{"id":"group","repo":"fixture/project","pulls":[12,13]}'
wait_for 'tested group to land' matches "${endpoints[1]}" group '.phase == "landed"'
candidate=$(jq -er '.submission.candidate.commit' "$tmp/current.json")
[[ $(git -C "$remote" rev-parse refs/heads/main) == "$candidate" ]]
[[ $(jq -er '.submission.candidate.base' "$tmp/current.json") == "$base" ]]
for rev in "$base" refs/pull/12/head refs/pull/13/head; do
  git -C "$remote" merge-base --is-ancestor "$rev" "$candidate"
done
digest=$(jq -er '.work[] | select(.task.action.name == "collect") | .step.proof.files[] | select(.path=="report.txt") | .digest' "$tmp/current.json")
get "${endpoints[2]}/v1/blobs/$digest" > "$tmp/report"
printf '%s\n' stable pull-12 pull-13 > "$tmp/expected-report"
cmp "$tmp/expected-report" "$tmp/report"
# Race an independent fast-forward against a candidate whose checks are pending.
g fetch -q "$remote" refs/heads/main
g checkout -q --detach "$candidate"
echo 'new race' > "$source_dir/source.txt"
g commit -qam 'Require a fresh producer execution'
g push -q "$remote" HEAD:refs/pull/14/head
post "${endpoints[1]}/v1/submits" "$GANTRY_SUBMIT_TOKEN" '{"id":"race","repo":"fixture/project","pulls":[14]}'
wait_for 'race candidate to start testing' matches "${endpoints[2]}" race '
  .submission.kind == "queued" and any(.work[]; .step.kind == "active")'
g checkout -q --detach "$candidate"
echo concurrent > "$source_dir/concurrent.txt"
g add concurrent.txt
g commit -qm 'Advance protected branch while candidate is testing'
winner=$(g rev-parse HEAD)
g push -q "$remote" HEAD:refs/heads/main
wait_for 'stale base to block landing' matches "${endpoints[2]}" race '.phase == "blocked"'
[[ $(git -C "$remote" rev-parse refs/heads/main) == "$winner" ]]
echo "Passed stale-base protection at $winner"
echo "Passed DAG, seed loss during active lease, early cutoff, grouped landing and artifact byte checks ($candidate)"

# Check an agent-only failure through the normal CLI and read its persisted log.
export GANTRY_URL="${endpoints[1]}"
"$cli" plan agent-plan fixture/project "$candidate" check > "$tmp/agent-plan.json"
jq -e '[.actions[].name] == ["normalize", "collect"]' "$tmp/agent-plan.json" >/dev/null
code=$(curl -sS -o "$tmp/unauthorized.json" -w '%{http_code}' \
  -H "Authorization: Bearer $GANTRY_TOKEN" --data '{"id":"denied","repo":"fixture/project","pulls":[14]}' \
  "$GANTRY_URL/v1/submits")
[[ $code == 401 ]]
cat > "$tmp/diagnostic.json" <<'JSON'
{"name":"diagnostic","argv":["sh","-ec","echo fixture-error >&2; exit 23"],"inputs":[],"outputs":[]}
JSON
for i in 1 2; do
  "$cli" run adhoc-failure fixture/project "$candidate" check "$tmp/diagnostic.json" > "$tmp/adhoc.json"
  jq -e '.id == "adhoc-failure"' "$tmp/adhoc.json" >/dev/null
done
if "$cli" watch adhoc-failure > "$tmp/adhoc-watch.jsonl"; then
  echo 'An ad hoc action with exit 23 unexpectedly succeeded' >&2
  exit 1
fi
failed_log=$(jq -ser 'last | select(.phase == "failed") | .work[0].step | select(.reason | contains("23")) | .log' "$tmp/adhoc-watch.jsonl")
"$cli" blob "$failed_log" > "$tmp/adhoc-result.log"
grep -Fx 'fixture-error' "$tmp/adhoc-result.log"
echo 'Passed agent plan, ad hoc admission replay, failure diagnostics, and submit authorization'

# Kill the executor after Docker has acknowledged its start. The restarted
# slot must clean up the original resources and publish a single rejection.
cat > "$tmp/interrupted.json" <<'JSON'
{"name":"interrupted","argv":["sleep","60"],"inputs":[],"outputs":[],"timeout":90}
JSON
"$cli" run worker-crash fixture/project "$candidate" check "$tmp/interrupted.json" > "$tmp/crash.json"
wait_for 'interruption fixture lease' matches "$GANTRY_URL" worker-crash '
  .work[0].step.kind == "active"'
serial=$(jq -er '.work[0].step.lease.serial' "$tmp/current.json")
name=$(jq -cn --arg dir "$tmp/journal" --argjson serial "$serial" \
  '[$dir,"worker-one","worker-crash","interrupted",$serial]' | tr -d '\n' | sha256sum | cut -d ' ' -f 1)
container_running() { [[ $(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null) == running ]]; }
wait_for 'interruption fixture container' container_running "gantry-$name"
stop_worker KILL
start_worker worker-restarted
worker_pid=${pids[-1]}
wait_for 'interruption receipt' matches "$GANTRY_URL" worker-crash '
  .phase == "failed" and .work[0].step.reason == "worker interrupted before recording outcome"'
containers=$(docker container ls -a --format '{{.Names}}')
volumes=$(docker volume ls --format '{{.Name}}')
if grep -Fxq -e "gantry-$name" -e "gantry-$name-collector" <<< "$containers" ||
   grep -Fxq "gantry-$name" <<< "$volumes" ||
   [[ -e "$tmp/journal/gantry-$name.staging" ]]; then
  echo "Interrupted attempt left resources behind: gantry-$name" >&2
  exit 1
fi
echo 'Passed worker restart, interrupted attempt fencing, and Docker resource cleanup'

# Lose a committed result reply, then recover the same receipt from SQLite.
stop_worker TERM
proxy_port=$((base_port + 4))
proxy_endpoint=http://127.0.0.1:$proxy_port
start result-proxy node "$root/scripts/fixtures/e2e/drop-result-reply.mjs" \
  "$proxy_port" "${endpoints[1]}" "$tmp"
wait_for 'result fault proxy' healthy "$proxy_endpoint"
worker_environment[1]="GANTRY_ENDPOINT=$proxy_endpoint"
start_worker worker-result-proxy
worker_pid=${pids[-1]}
cat > "$tmp/lost-ack.json" <<'JSON'
{"name":"lost-ack","argv":["sh","-ec","echo committed"],"inputs":[],"outputs":[]}
JSON
"$cli" run lost-ack fixture/project "$candidate" check "$tmp/lost-ack.json" > "$tmp/lost-ack-run.json"
wait_for 'committed result with withheld reply' test -s "$tmp/committed-receipt.json"
stop_worker KILL
start_worker worker-result-replay
worker_pid=${pids[-1]}
wait_for 'worker custody acknowledged after replay' test -f "$tmp/poll-after-replay"
cmp "$tmp/committed-receipt.json" "$tmp/replayed-receipt.json"
wait_for 'completed run after result replay' matches "$GANTRY_URL" lost-ack '.phase == "passed"'
echo 'Passed worker restart after losing an already committed result reply'

# A managed slot keeps its custody witness outside the journal directory.
stop_worker TERM
test -f "$tmp/worker-established"
mv "$tmp/journal" "$tmp/journal-recovery"
code=0
timeout 8 env "${worker_environment[@]}" "${worker[@]}" >"$tmp/missing-journal.log" 2>&1 || code=$?
[[ $code == 1 && ! -e "$tmp/journal/custody.sqlite3" ]]
grep -F 'managed worker journal is missing' "$tmp/missing-journal.log"
: > "$tmp/journal/custody.sqlite3"
code=0
timeout 8 env "${worker_environment[@]}" "${worker[@]}" >"$tmp/empty-journal.log" 2>&1 || code=$?
[[ $code == 1 && ! -s "$tmp/journal/custody.sqlite3" ]]
grep -F 'managed worker journal has no readable identity' "$tmp/empty-journal.log"

# A quiescent queue still needs a majority to return an empty poll.
wait_for 'empty poll from the surviving quorum' empty_poll "${endpoints[2]}"
ready_status() {
  curl -sS --max-time 8 -o "$tmp/ready.json" -w '%{http_code}' "$1/ready"
}
worker_ready_status() {
  curl -sS --max-time 8 -H "Authorization: Bearer $2" \
    -o "$tmp/worker-ready.json" -w '%{http_code}' "$1/v1/worker/ready"
}
[[ $(ready_status "${endpoints[2]}") == 200 ]]
jq -e '.status == "ready"' "$tmp/ready.json" >/dev/null
[[ $(worker_ready_status "${endpoints[2]}" "$GANTRY_TOKEN") == 401 ]]
[[ $(worker_ready_status "${endpoints[2]}" "$GANTRY_WORKER_TOKEN") == 200 ]]
jq -e '.status == "ready"' "$tmp/worker-ready.json" >/dev/null
kill -KILL -- "-${pids[1]}"
wait "${pids[1]}" 2>/dev/null || true
unset 'pids[1]'
[[ $(poll_status "${endpoints[2]}") == 503 ]]
jq -e '.error | startswith("queue ")' "$tmp/poll.json" >/dev/null
[[ $(ready_status "${endpoints[2]}") == 503 ]]
jq -e '.error | startswith("queue ")' "$tmp/ready.json" >/dev/null
[[ $(worker_ready_status "${endpoints[2]}" "$GANTRY_WORKER_TOKEN") == 503 ]]
start node2-restarted env GANTRY_CONFIG="$tmp/node2.toml" \
  ERL_FLAGS="+S 2:2 -name ${node}2@127.0.0.1 -setcookie $cookie" "${controller[@]}"
wait_for 'empty poll after quorum recovery' empty_poll "${endpoints[2]}"
[[ $(ready_status "${endpoints[2]}") == 200 ]]
[[ $(worker_ready_status "${endpoints[2]}" "$GANTRY_WORKER_TOKEN") == 200 ]]
echo 'Passed empty poll and gateway readiness through quorum loss and recovery'

if [[ -n ${GANTRY_RELEASE_BIN:-} ]]; then
  export XDG_STATE_HOME="$tmp/onboarding"
  export GANTRY_LOCAL_PORT=$((base_port + 3))
  "$cli" skill > "$tmp/skill.md"
  cmp "$tmp/skill.md" "$root/skills/gantry/SKILL.md"
  "$cli" init --local > "$tmp/init.json"
  "$cli" init --local > "$tmp/init-repeat.json"
  jq -e '.status == "passed" and .services == "stopped" and (.artifact | length == 64)' \
    "$tmp/init.json" >/dev/null
  cmp "$tmp/init.json" "$tmp/init-repeat.json"
  echo 'Passed packaged agent skill and repeatable local onboarding'
fi
