#!/usr/bin/env bash
# Publish a complete release tree atomically. Running services retain their tree.
set -euo pipefail
archive="${1:?usage: scripts/install.sh RELEASE.tar.gz}"
prefix="${PREFIX:-$HOME/.local}"
mkdir -p "$prefix/bin" "$prefix/lib/gantry/releases"
prefix="$(CDPATH= cd -- "$prefix" && pwd -P)"
lib="$prefix/lib/gantry"
exec 9>"$lib/install.lock"
flock --exclusive 9
staging="$(mktemp -d "$lib/.install.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT

tar -xzf "$archive" -C "$staging"
for launcher in gantry gantryd gantry-worker; do
  [[ -x "$staging/gantry/bin/$launcher" ]]
done
tree="releases/${staging##*.}"
mv -- "$staging/gantry" "$lib/$tree"
ln -s "$tree" "$staging/current"
if [[ -L "$lib/current" ]]; then
  ln -s "$(readlink "$lib/current")" "$staging/previous"
  mv -fT -- "$staging/previous" "$lib/previous"
fi
mv -fT -- "$staging/current" "$lib/current"

for launcher in gantry gantryd gantry-worker; do
  # Resolve the chosen release for each new process. A live VM loads files
  # from its immutable tree even after the next install changes current.
  wrapper="$(mktemp "$prefix/bin/.gantry-launcher.XXXXXXXX")"
  cat > "$wrapper" <<'BOOT'
#!/usr/bin/env bash
set -euo pipefail
bin="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
target="$(CDPATH= cd -- "$bin/../lib/gantry/current" && pwd -P)"
exec "$target/bin/${0##*/}" "$@"
BOOT
  chmod 0755 "$wrapper"
  mv -fT -- "$wrapper" "$prefix/bin/$launcher"
done
printf 'Installed %s under %s\n' "$("$prefix/bin/gantryd" --version)" "$prefix"
