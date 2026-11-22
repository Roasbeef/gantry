#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root/packages/core"
gleam build --target erlang
exec escript "$root/scripts/queue-dst.escript" "$@"
