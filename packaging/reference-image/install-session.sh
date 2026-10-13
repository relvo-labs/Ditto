#!/usr/bin/env bash
# Build and install the display-manager entry and the systemd user units for
# the current checked-out reference tree. Source-built Qt, Quickshell and
# Wayfire must already match source-builds.lock; preflight verifies them
# before installation.
#
# G1 installs "Ditto (Wayfire)" (/usr/local/libexec/ditto-session) beside an
# existing "Ditto G0 (Wayfire)" entry and does not remove it; README.md lists
# what moved.
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../.." && pwd)"
here="$workspace/packaging/reference-image"
units_source="$workspace/packaging/systemd/user"
libexec=/usr/local/libexec
# System-wide user units: every user manager sees them without anything being
# written to the user's XDG_CONFIG_HOME, which Ditto does not write to.
units_target=/etc/systemd/user
qt_prefix="${DITTO_QT_PREFIX:-$HOME/Qt/6.10.2/gcc_64}"
wayfire_prefix="${DITTO_WAYFIRE_PREFIX:-$HOME/wayfire}"
temporary="$(mktemp -d /tmp/ditto-session-install.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT

for command in cargo sed sudo install jq sha256sum; do
  command -v "$command" >/dev/null || { echo "missing installer dependency: $command" >&2; exit 1; }
done
# The pinned D-Bus proxy and screencast portal are built from source here.
for command in meson ninja pkg-config; do
  command -v "$command" >/dev/null || { echo "missing installer dependency: $command (apt-packages.txt)" >&2; exit 1; }
done
for module in gio-2.0 libpipewire-0.3 wayland-client wayland-protocols gbm libdrm inih libsystemd; do
  pkg-config --exists "$module" || { echo "missing build library: $module (apt-packages.txt)" >&2; exit 1; }
done

# `--development` installs the same session on a development machine or VM.
# It skips the reference-machine preflight, so nothing measured there can enter
# an exit review; the session itself is identical.
#
# `--verification-relay` is for verification runs only: Core uses built-ins
# that add the G1 fault fixtures and the D-34 set of ten simple plugins
# (target/ditto-packages-verification) and also launches
# tests/g1/lib/relay.mjs as `dittoctl` (except in an EX1-10 rescue_no_node
# measurement login, which starts no Node), listening on
# $XDG_RUNTIME_DIR/ditto/verify-relay.sock (0700 directory), so the G1 runners
# can read a logged-in session back through Core. It lets any process of the
# user that reaches that socket act with dittoctl's rights, which a terminal
# `dittoctl` deliberately does not have. Without the flag, an earlier relay
# drop-in is removed.
development=""
verification_relay=""
for argument in "$@"; do
  case "$argument" in
    --development) development=1 ;;
    --verification-relay) verification_relay=1 ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done
if [[ -n "$development" ]]; then
  echo 'development install: reference-machine preflight skipped' >&2
else
  bash "$here/preflight.sh"
fi
# ditto-core's crate also builds ditto-worker (the job pool); ditto-confine
# is the Codex backend's OS boundary; both must sit next to ditto-core.
cargo build --locked --release -p ditto-core -p ditto-supervisor -p dittoctl -p ditto-confine
# The filtering session-bus proxy for the backend's keyring access: the
# pinned build (Ubuntu's 0.1.5 drops zbus clients).
bash "$workspace/tools/dbus-proxy/build.sh" release >/dev/null

# hostd runs on the frozen Node (.nvmrc), named by its canonical path.
node="$(readlink -f "${DITTO_NODE:-$(command -v node || true)}")"
wanted="v$(tr -d '[:space:]' <"$workspace/.nvmrc")"
[[ -x "$node" ]] || { echo "missing Node $wanted (set DITTO_NODE)" >&2; exit 1; }
[[ "$("$node" --version)" == "$wanted" ]] || { echo "Node at $node is $("$node" --version), not $wanted" >&2; exit 1; }
command -v pnpm >/dev/null || { echo "missing installer dependency: pnpm" >&2; exit 1; }
(cd "$workspace" && pnpm install --frozen-lockfile && pnpm --filter @ditto/host-runtime build && pnpm --filter @ditto/agent-runtime build)
# The Codex backend is configured only for the exact pinned binary
# (tools/codex/pin.json); Core verifies the hash again at every launch.
codex="$(readlink -f "${DITTO_CODEX_BINARY:-$HOME/.local/bin/codex}" 2>/dev/null || true)"
pin_version="$(jq -r .version "$workspace/tools/codex/pin.json")"
pin_sha="$(jq -r .sha256 "$workspace/tools/codex/pin.json")"
agent_backend_args=""
if [[ -n "$codex" && -f "$codex" && "$(sha256sum "$codex" | cut -d' ' -f1)" == "$pin_sha" ]]; then
  agent_backend_args="--agent-backend \"codex-app-server $pin_version $pin_sha $codex\""
  echo "Codex backend: $codex (pinned $pin_version)" >&2
else
  echo "Codex backend: the pinned codex $pin_version binary was not found; the session runs without it" >&2
fi
bash "$workspace/scripts/build-builtin-packages.sh" "$workspace/target/ditto-packages" >/dev/null
# hostd's Node/V8 flags have one source; every launch path reads the same file.
hostd_node_flags="$(sed -e 's/#.*//' "$workspace/packages/host-runtime/hostd.node-flags" | xargs)"

substitute() {
  sed -e "s|@DITTO_WORKSPACE@|$workspace|g" \
    -e "s|@DITTO_QT_PREFIX@|$qt_prefix|g" \
    -e "s|@DITTO_WAYFIRE_PREFIX@|$wayfire_prefix|g" \
    -e "s|@DITTO_LIBEXEC@|$libexec|g" \
    -e "s|@DITTO_NODE@|$node|g" \
    -e "s|@DITTO_HOSTD_NODE_FLAGS@|$hostd_node_flags|g" \
    -e "s|@DITTO_AGENT_BACKEND_ARGS@|$agent_backend_args|g" \
    -e "s|@DITTO_SESSION_EXEC@|$libexec/ditto-session|g" "$1" >"$2"
  if grep -q '@DITTO_[A-Z_]*@' "$2"; then
    echo "unsubstituted placeholder in $1" >&2
    exit 1
  fi
}

substitute "$here/session/ditto-session" "$temporary/ditto-session"
substitute "$here/session/ditto.desktop" "$temporary/ditto.desktop"
sudo install -D -m 0755 "$temporary/ditto-session" "$libexec/ditto-session"
sudo install -D -m 0644 "$temporary/ditto.desktop" /usr/share/wayland-sessions/ditto.desktop
# A GDM restart otherwise leaves the Ditto session open and blocks the next
# login for the same user; see session/ditto-end-sessions.
for script in ditto-end-sessions ditto-relogin ditto-logout ditto-rescue-ui; do
  sudo install -D -m 0755 "$here/session/$script" "$libexec/$script"
done
sudo install -D -m 0644 "$here/session/gdm-ditto.conf" /etc/systemd/system/gdm.service.d/ditto.conf
# Screen capture portal for Wayfire (RustDesk, screen sharing); see README.md.
sudo install -D -m 0644 "$here/session/wayfire-portals.conf" /etc/xdg/xdg-desktop-portal/wayfire-portals.conf
sudo install -D -m 0644 "$here/session/xdpw-wayfire.conf" /etc/xdg/xdg-desktop-portal-wlr/Wayfire
# Ubuntu's xdg-desktop-portal-wlr 0.7.1 stalls a reconnecting capture after
# one frame (RustDesk black); the session runs the pinned 0.8.4 build.
bash "$workspace/tools/xdpw/build.sh"
sudo install -D -m 0644 "$here/session/xdpw-service.conf" /etc/systemd/user/xdg-desktop-portal-wlr.service.d/ditto.conf

for unit in "$units_source"/*; do
  name="$(basename "$unit")"
  substitute "$unit" "$temporary/$name"
  sudo install -D -m 0644 "$temporary/$name" "$units_target/$name"
done
relay_dropin="$units_target/ditto-core.service.d/verification-relay.conf"
if [[ -n "$verification_relay" ]]; then
  # Verification built-ins: the product's, plus the fault fixtures the G1
  # session runners enable (G1 enables built-in packages only, and a fixture
  # must never be among the product's).
  verification_packages="$workspace/target/ditto-packages-verification"
  rm -rf -- "$verification_packages"
  install -d "$verification_packages"
  cp "$workspace"/target/ditto-packages/*.dittopkg "$verification_packages/"
  (cd "$workspace" && pnpm --filter @ditto/plugin-fixtures build >/dev/null)
  "$workspace/packages/host-sdk/bin/ditto-plugin" pack "$workspace/packages/plugin-fixtures/faults/crashes_host" \
    --out "$verification_packages/ditto.fixture.fault_crashes_host-1.0.0.dittopkg" --no-handlers >/dev/null
  # The D-34 set (five QML status items, five Cordis settings plugins) for
  # EX1-10's desktop_full_plus10 A/B (tests/g1/measure/cold-login.sh): the
  # same fixed, version-locked packages every run, never the product's.
  node "$workspace/packages/host-sdk/scripts/pack-each.mjs" \
    "$workspace"/packages/plugin-fixtures/qml/* "$workspace"/packages/plugin-fixtures/cordis/* \
    --out "$verification_packages" >/dev/null
  # The drop-in repeats Core's ExecStart with those built-ins and the relay,
  # whose launch is two words from the environment: `--launch` and its spec
  # by default, overridden from session.env by a rescue_no_node measurement
  # login (see session/ditto-session), which must start no Node at all.
  python3 - "$temporary/ditto-core.service" "$node" "$workspace" >"$temporary/verification-relay.conf" <<'PYEOF'
import sys
unit, node, workspace = sys.argv[1:]
lines, collecting = [], False
for line in open(unit, encoding="utf-8"):
    if line.startswith("ExecStart="):
        collecting = True
    if collecting:
        lines.append(line.rstrip("\n").replace(f"{workspace}/target/ditto-packages ", f"{workspace}/target/ditto-packages-verification "))
        if not line.rstrip("\n").endswith("\\"):
            break
lines[-1] += " \\"
lines.append("    $DITTO_VERIFY_RELAY_OPTION ${DITTO_VERIFY_RELAY_SPEC}")
print("# Verification runs only (install-session.sh --verification-relay).")
print("[Service]")
print("Environment=DITTO_VERIFY_RELAY_OPTION=--launch")
print(f'Environment="DITTO_VERIFY_RELAY_SPEC=dittoctl 0.2.0 {node} {workspace}/tests/g1/lib/relay.mjs %t/ditto/verify-relay.sock"')
print("ExecStart=")
print("\n".join(lines))
PYEOF
  sudo install -D -m 0644 "$temporary/verification-relay.conf" "$relay_dropin"
  echo "installed the verification relay drop-in: $relay_dropin" >&2
else
  sudo rm -f -- "$relay_dropin"
fi
sudo systemctl daemon-reload
# The running user manager (if any) reads the new units now; a later login
# would read them anyway.
systemctl --user daemon-reload 2>/dev/null || echo 'no user manager reachable; the units load at the next login' >&2

echo 'installed display-manager session: Ditto (Wayfire)'
echo "installed user units: $(cd "$units_source" && echo *) -> $units_target"
echo "workspace: $workspace"
echo 'select it once at the login manager; journalctl --user -u ditto-core -u ditto-supervisor shows the supervised units'
