#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
: "${TLA2TOOLS:?Set TLA2TOOLS to the TLA+ v1.7.4 release jar}"
jar=$(realpath "$TLA2TOOLS")
hash=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
printf '%s  %s\n' "$hash" "$jar" | sha256sum -c
states=$(mktemp -d)
trap 'rm -rf "$states"' EXIT
cd "$root/protocol/models/queue"
java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 -metadir "$states" Queue
