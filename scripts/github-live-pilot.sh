#!/usr/bin/env bash
set -euo pipefail
base=pilot/gantry-integration-target
repo=Roasbeef/gantry
test "${GITHUB_REPOSITORY:?}" = "$repo"
test "${GITHUB_REF:?}" = refs/heads/pilot/gantry-integration-runner
test "$(gh api "repos/$repo/pulls/6" --jq .base.ref)" = "$base"
test "$(gh api "repos/$repo/pulls/7" --jq .base.ref)" = "$base"
test "$(gh api "repos/$repo/pulls/6" --jq .head.ref)" = pilot/gantry-integration-left
test "$(gh api "repos/$repo/pulls/7" --jq .head.ref)" = pilot/gantry-integration-right
existing=$(git ls-remote origin "refs/heads/$base" | cut -f 1)
test "$existing" = f44eced0120db8def61d5104460f445f454a7b68
pids=()
dir=$(mktemp -d)
gateway="gantry-live-pilot-$GITHUB_RUN_ID"
cleanup() {
  rc=$?
  trap - EXIT
  if ((rc != 0)); then
    for log in "$dir"/*.log; do
      if [[ -f $log ]]; then tail -70 "$log"; fi
    done
  fi
  for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  docker rm -f "$gateway" >/dev/null 2>&1 || true
  rm -rf -- "$dir"
  exit "$rc"
}
trap cleanup EXIT
chmod 700 "$dir"
export GANTRY_CONFIG="$dir/controller.toml"
export GANTRY_TOKEN="$(openssl rand -hex 32)"
export GANTRY_WORKER_TOKEN="$(openssl rand -hex 32)"
export GANTRY_SUBMIT_TOKEN="$(openssl rand -hex 32)"
for token in "$GANTRY_TOKEN" "$GANTRY_WORKER_TOKEN" "$GANTRY_SUBMIT_TOKEN"; do
  echo "::add-mask::$token"
done
image=alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
docker pull "$image"
cat > "$GANTRY_CONFIG" <<EOF
data_dir = "$dir/controller"
blob_dir = "$dir/blobs"
port = 19871
seed = ""

[[repository]]
name = "roasbeef/gantry"
branch = "$base"
target = "check"
pool = "pilot"
image = "$image"
EOF
launcher="$RUNNER_TEMP/gantry/bin"
ERL_FLAGS='+S 2:2 -name gantry_live@127.0.0.1' "$launcher/gantryd" > "$dir/controller.log" 2>&1 &
pids+=("$!")
for _ in {1..30}; do
  if curl -fsS --max-time 2 http://127.0.0.1:19871/ready >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 5 http://127.0.0.1:19871/ready | jq -e '.status=="ready"' >/dev/null
GANTRY_ENDPOINT=http://127.0.0.1:19871 GANTRY_WORKER_ID=github-pilot GANTRY_POOL=pilot \
  GANTRY_WORKER_DIR="$dir/worker" ERL_FLAGS='+S 2:2' "$launcher/gantry-worker" > "$dir/worker.log" 2>&1 &
pids+=("$!")
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj /CN=127.0.0.1 -addext 'subjectAltName=IP:127.0.0.1' \
  -keyout "$dir/key.pem" -out "$dir/cert.pem" > "$dir/tls.log" 2>&1
cat "$dir/cert.pem" "$dir/key.pem" > "$dir/server.pem"
cat > "$dir/proxy.cfg" <<'EOF'
defaults
    mode http
    timeout connect 5s
    timeout client 120s
    timeout server 120s
    retries 0
listen gantry
    bind 127.0.0.1:19872 ssl crt /fixture/server.pem
    server api 127.0.0.1:19871
EOF
docker run --detach --name "$gateway" --network host --user "$(id -u):$(id -g)" \
  -v "$dir:/fixture:ro" haproxy@sha256:7816a9801a6846b912bc37e48529808e2fa87c3c47992441940f68e393ebcfeb \
  haproxy -f /fixture/proxy.cfg >/dev/null
export GANTRY_URL=https://127.0.0.1:19872
export CURL_CA_BUNDLE="$dir/cert.pem"
export PULLS='[6,7]' REPO="$repo" RUN_ID="github-$GITHUB_RUN_ID"
for _ in {1..15}; do
  if curl -fsS --max-time 2 "$GANTRY_URL/ready" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 5 "$GANTRY_URL/ready" | jq -e '.status=="ready"' >/dev/null

# Exercise the documented workflow's actual shell step, including its replay.
sed -n '/^        run: |$/,$p' docs/examples/github-submit.yml | tail -n +2 | sed 's/^          //' > "$dir/submit.sh"
test -s "$dir/submit.sh"
bash "$dir/submit.sh"
bash "$dir/submit.sh"
status=$("$launcher/gantry" status "$RUN_ID")
sha=$(jq -er 'select(.phase == "landed") | .submission.candidate.commit' <<<"$status")
actual=$(git ls-remote origin "refs/heads/$base" | cut -f 1)
test "$actual" = "$sha"
git fetch --quiet origin "refs/heads/$base"
for pull in 6 7; do
  pinned=$(jq -er --argjson pull "$pull" '.submission.candidate.members[] | select(.pull==$pull) | .head' <<<"$status")
  git merge-base --is-ancestor "$pinned" "$sha"
  comments=$(gh api --paginate --slurp "repos/$repo/issues/$pull/comments")
  jq -e --arg sha "$sha" --arg marker "<!-- gantry-run:$RUN_ID -->" \
    'add | map(select(.user.login == "github-actions[bot]" and (.body | startswith($marker) and contains($sha)))) | length == 1' \
    <<<"$comments" >/dev/null
  gh api "repos/$repo/pulls/$pull" --jq '{number,merged,merge_commit_sha}'
done
digest=$(jq -er '.work[0].step.proof.files[] | select(.path=="report.txt") | .digest' <<<"$status")
CURL_CA_BUNDLE="$dir/cert.pem" "$launcher/gantry" blob "$digest" --output raw > "$dir/report.txt"
test "$(sha256sum "$dir/report.txt" | cut -d ' ' -f 1)" = "$digest"
grep -Fx 'both PRs built' "$dir/report.txt"
echo "Verified target $base at exact candidate $sha with one linked comment per PR"
