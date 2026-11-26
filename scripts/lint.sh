#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root/vendor/loom/lint"
output=$(gleam run -m lint/cli -- "$root/packages/core/src" "$root/packages/core/test" "$root/packages/server/src" "$root/packages/server/test" "$root/packages/dashboard/src" "$root/packages/dashboard/test")
printf '%s\n' "$output"
last=${output##*$'\n'}
[[ $last =~ ^\#\ ([0-9]+)\ ([0-9]+)$ ]] || exit 1
(( BASH_REMATCH[1] == 0 ))
