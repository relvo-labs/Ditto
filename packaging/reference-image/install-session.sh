#!/usr/bin/env bash
# Build and install the display-manager entry for the current checked-out G0
# reference tree. Source-built Qt, Quickshell and Wayfire must already match
# source-builds.lock; preflight verifies them before installation.
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../.." && pwd)"
here="$workspace/packaging/reference-image"
temporary="$(mktemp -d /tmp/ditto-g0-session-install.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT

for command in cargo sed sudo install; do
  command -v "$command" >/dev/null || { echo "missing installer dependency: $command" >&2; exit 1; }
done

bash "$here/preflight.sh"
cargo build --locked --release -p ditto-core

sed "s|@DITTO_WORKSPACE@|$workspace|g" \
  "$here/session/ditto-g0-session" >"$temporary/ditto-g0-session"
sed 's|@DITTO_SESSION_EXEC@|/usr/local/libexec/ditto-g0-session|g' \
  "$here/session/ditto-g0.desktop" >"$temporary/ditto-g0.desktop"

sudo install -D -m 0755 "$temporary/ditto-g0-session" /usr/local/libexec/ditto-g0-session
sudo install -D -m 0644 "$temporary/ditto-g0.desktop" /usr/share/wayland-sessions/ditto-g0.desktop

echo 'installed display-manager session: Ditto G0 (Wayfire)'
echo "workspace: $workspace"
echo 'select it once at the login manager, then run tests/g0/input-method/manual-session.sh from foot'
