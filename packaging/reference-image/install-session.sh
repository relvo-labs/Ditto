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

# `--development` installs the same session on a development machine or VM.
# It skips the reference-machine preflight, so nothing measured there can enter
# an exit review; the session itself is identical.
if [[ "${1:-}" == --development ]]; then
  echo 'development install: reference-machine preflight skipped' >&2
else
  bash "$here/preflight.sh"
fi
cargo build --locked --release -p ditto-core

sed "s|@DITTO_WORKSPACE@|$workspace|g" \
  "$here/session/ditto-g0-session" >"$temporary/ditto-g0-session"
sed 's|@DITTO_SESSION_EXEC@|/usr/local/libexec/ditto-g0-session|g' \
  "$here/session/ditto-g0.desktop" >"$temporary/ditto-g0.desktop"

sudo install -D -m 0755 "$temporary/ditto-g0-session" /usr/local/libexec/ditto-g0-session
sudo install -D -m 0644 "$temporary/ditto-g0.desktop" /usr/share/wayland-sessions/ditto-g0.desktop
# A GDM restart otherwise leaves the Ditto session open and blocks the next
# login for the same user; see session/ditto-g0-end-sessions.
sudo install -D -m 0755 "$here/session/ditto-g0-end-sessions" /usr/local/libexec/ditto-g0-end-sessions
sudo install -D -m 0755 "$here/session/ditto-g0-relogin" /usr/local/libexec/ditto-g0-relogin
sudo install -D -m 0644 "$here/session/gdm-ditto-g0.conf" /etc/systemd/system/gdm.service.d/ditto-g0.conf
sudo systemctl daemon-reload

echo 'installed display-manager session: Ditto G0 (Wayfire)'
echo "workspace: $workspace"
echo 'select it once at the login manager, then run tests/g0/input-method/manual-session.sh from foot'
