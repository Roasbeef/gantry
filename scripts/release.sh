#!/usr/bin/env bash
# Assemble a host-native OTP release from Gleam's production shipment.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd -P)"
archive="${1:?usage: scripts/release.sh RELEASE.tar.gz}"
mkdir -p build/release
exec 9>build/release/.lock
flock --exclusive 9
stage="$(mktemp -d "$root/build/release/.assemble.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' packages/server/gleam.toml)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
commit="$(git rev-parse --verify HEAD 2>/dev/null || printf '%s' unknown)"
if [[ "$commit" != unknown && -n "$(git status --porcelain)" ]]; then
  commit="$commit-dirty"
fi
(
  cd packages/server
  gleam export erlang-shipment
)
mkdir -p "$stage/libs"
cp -a packages/server/build/erlang-shipment/. "$stage/libs/"
rm -f "$stage/libs/entrypoint.sh" "$stage/libs/entrypoint.ps1"
rm -rf -- "$stage/libs/gantry/priv"
install -D -m 0644 packages/server/priv/worker-schema.sql "$stage/libs/gantry/priv/worker-schema.sql"
install -D -m 0644 packages/server/priv/gantry-schema.json "$stage/libs/gantry/priv/gantry-schema.json"
install -D -m 0644 skills/gantry/SKILL.md "$stage/libs/gantry/priv/skill/SKILL.md"
cat > "$stage/rebar.config" <<CONFIG
{erl_opts, []}.
{deps, []}.
{project_app_dirs, []}.
{relx, [
  {release, {gantry, "$version"}, [gantry]},
  {lib_dirs, ["libs"]},
  {include_erts, true},
  {include_src, false},
  {dev_mode, false},
  {debug_info, strip}
]}.
CONFIG
(cd "$stage" && rebar3 release)
dist="$stage/_build/default/rel/gantry"
erts=("$dist"/erts-*/bin/erl)
[[ ${#erts[@]} == 1 && -x "${erts[0]}" ]]
erts_dir="${erts[0]#"$dist/"}"
find "$dist/bin" -maxdepth 1 -type f ! -name '*.boot' -delete
rm -f "$dist/releases/$version/vm.args" "$dist/releases/$version/sys.config"
[[ -f "$dist/releases/$version/start.boot" ]]
for launcher in gantryd gantry-worker gantry; do
  case $launcher in
    gantryd) module=gantry ;;
    gantry-worker) module=gantry@worker ;;
    gantry) module=gantry@cli ;;
  esac
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
      'root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)'
    # The CLI reads its arguments after -extra and serves --version itself.
    if [[ $launcher != gantry ]]; then
      printf '%s\n' "if [[ \"\${1:-}\" == --version ]]; then printf '%s\\n' 'Gantry $version ($commit)'; exit 0; fi"
    fi
    printf '%s\n' "exec \"\$root/$erts_dir\" -noshell -boot \"\$root/releases/$version/start\" -s '$module' main -extra \"\$@\""
  } > "$dist/bin/$launcher"
  chmod +x "$dist/bin/$launcher"
done
install -D -m 0644 packages/server/priv/gantry-schema.json "$dist/share/gantry/cli-schema.json"
install -m 0755 scripts/gantry-onboard "$dist/share/gantry/gantry-onboard"
install -D -m 0644 scripts/gantry-onboarding "$dist/share/gantry/gantry-onboarding"
install -D -m 0644 skills/gantry/SKILL.md "$dist/share/gantry/skill/SKILL.md"
printf 'Gantry %s (%s)\n' "$version" "$commit" > "$dist/releases/gantry-version"
chmod -R u+rwX,go+rX "$dist"
tar -C "$(dirname "$dist")" -czf "$stage/gantry.tar.gz" gantry
mv -f -- "$stage/gantry.tar.gz" "$archive"
printf '%s\n' "$archive"
