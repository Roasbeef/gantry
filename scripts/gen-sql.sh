#!/usr/bin/env bash
# Generate the worker journal bindings against a fresh copy of its schema.
set -euo pipefail
cd "$(dirname "$0")/../packages/server"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
command -v sqlite3 >/dev/null || {
  echo 'gen-sql: the SQLite CLI is required to load and read the journal schema' >&2
  exit 1
}

# Parrot 2.3.0 expects a different archive digest. Provision the exact sqlc
# version it uses, verified against the upstream v1.31.1 release asset.
if [[ ! -x build/.parrot/sqlc && $(uname -s) == Linux ]]; then
  case "$(uname -m)" in
    x86_64) platform=amd64; sha=497ae4fcdfa64c5b0c311ffe4c2bd991e43991e82e5367792ed78bc2dca27354 ;;
    aarch64) platform=arm64; sha=b7cae247740d0c51a1e657479e5b2d21e6fef428f596682a01bc55bf4ab8a23d ;;
    *) echo 'gen-sql: unsupported sqlc host architecture' >&2; exit 1 ;;
  esac
  curl --fail --location --silent --show-error \
    "https://downloads.sqlc.dev/sqlc_1.31.1_linux_$platform.tar.gz" -o "$tmp/sqlc.tar.gz"
  printf '%s  %s\n' "$sha" "$tmp/sqlc.tar.gz" | sha256sum -c
  tar -xzf "$tmp/sqlc.tar.gz" -C "$tmp" sqlc
  install -D -m 0755 "$tmp/sqlc" build/.parrot/sqlc
fi

sqlite3 "$tmp/custody.sqlite3" < priv/worker-schema.sql
gleam run -m parrot -- --sqlite "$tmp/custody.sqlite3"
