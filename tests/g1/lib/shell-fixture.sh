#!/usr/bin/env bash
# A headless desktop for the G1 runners that need the real Shell (sourced
# after common.sh). It is the fixture of tests/g1/manual-switch, made
# reusable:
#
#   - Wayfire on a headless output (start_compositor in tests/g0/lib/session.sh),
#     which also starts the fixture's own session bus;
#   - Core in normal mode with the built-in packages, the Shell under Core's
#     supervision (`--shell`: restarted with backoff, as in the login session),
#     optionally hostd, and the read-back relay (tests/g1/lib/relay.mjs)
#     launched by Core as `dittoctl`;
#   - DITTO_SYSTEM=no-logind: the real ditto-system, so the
#     org.freedesktop.Notifications server runs on the fixture's bus, but
#     without logind, so nothing reaches the login session the fixture runs
#     beside. The application-index cache stays inside the fixture.
#
#   shell_fixture_start [--hostd] [extra `ditto-core serve` args...]
#       Sets CORE_PID, QUICKSHELL, NODE; exports DITTO_G1_RELAY. Returns 1 when
#       the fixture did not come up (Core's log is $RUNTIME_DIR/core.log).
#   relay <method> [params-json]       one Core call through the relay
#   shell_line <line>                  one line to the Shell's control socket
#   core_child <pattern>               newest PID under Core whose command
#                                      line contains the pattern
#   fixture_reference_apps             foot and Kate (and Firefox on the
#                                      reference machine)
#   apps_alive                         every reference application still runs
#   shell_fixture_stop                 stop it all, remove the runtime directory
set -euo pipefail

source "$WORKSPACE/tests/g0/lib/reference-apps.sh"
G1_GUI=(python3 "$WORKSPACE/tests/g1/lib/gui.py")

shell_fixture_start() {
  local with_hostd=""
  if [[ "${1:-}" == --hostd ]]; then
    with_hostd=1
    shift
  fi
  compositor_pointer_injection >/dev/null 2>&1 || true
  export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software
  export DITTO_SYSTEM=no-logind XDG_CACHE_HOME="$RUNTIME_DIR/cache"
  unset DITTO_DEV_TOKEN
  QUICKSHELL="$(readlink -f "$(command -v quickshell)")"
  NODE="$(readlink -f "$(command -v node)")"
  export DITTO_G1_RELAY="$RUNTIME_DIR/relay-$$.sock"
  local serve=(serve --compositor "$DITTO_COMPOSITOR"
    --builtin-packages "$WORKSPACE/target/ditto-packages"
    --shell "quickshell 0.2.0 $QUICKSHELL -p $WORKSPACE/shell/shell.qml"
    --launch "dittoctl 0.2.0 $NODE $WORKSPACE/tests/g1/lib/relay.mjs $DITTO_G1_RELAY")
  [[ -n "$with_hostd" ]] && serve+=(--hostd "hostd 0.2.0 $NODE $WORKSPACE/packages/host-runtime/dist/ditto-hostd.mjs")
  "$BINARIES/ditto-core" "${serve[@]}" "$@" >"$RUNTIME_DIR/core.log" 2>&1 &
  CORE_PID=$!
  local ready="" _
  for _ in $(seq 1 300); do
    if grep -aq 'ditto-relay ready' "$RUNTIME_DIR/core.log" && grep -aq '"role":"shell"' "$RUNTIME_DIR/core.log" \
      && [[ -S "$DITTO_RUNTIME_DIR/shell.sock" ]]; then ready=1; break; fi
    kill -0 "$CORE_PID" 2>/dev/null || break
    sleep 0.1
  done
  [[ -n "$ready" ]] || return 1
  [[ -z "$with_hostd" ]] && return 0
  # hostd serves the tasks service once its entries are mounted.
  for _ in $(seq 1 300); do
    relay desktop.capabilities.list '{}' 2>/dev/null | python3 -c '
import json, sys
listing = json.load(sys.stdin).get("result") or {}
wanted = {"desktop.tasks.list", "desktop.notifications.policy.get"}
up = {c["capability_id"] for c in listing.get("capabilities", [])
      if (c.get("availability") or {}).get("kind") == "always" or (c.get("availability") or {}).get("available") is True}
raise SystemExit(0 if wanted <= up else 1)' && return 0
    kill -0 "$CORE_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

relay() {
  "${G1_GUI[@]}" relay "$1" "${2:-{\}}"
}

shell_line() {
  python3 - "$DITTO_RUNTIME_DIR/shell.sock" "$1" <<'PYEOF'
import socket, sys
connection = socket.socket(socket.AF_UNIX)
connection.settimeout(2.0)
connection.connect(sys.argv[1])
connection.sendall(sys.argv[2].encode() + b"\n")
buffer = b""
while b"\n" not in buffer:
    chunk = connection.recv(65536)
    if not chunk:
        break
    buffer += chunk
print(buffer.decode().split("\n", 1)[0])
PYEOF
}

core_child() {
  local pattern="$1" pid newest=""
  for pid in $(pgrep -f -- "$pattern" || true); do
    [[ "$(ps -o ppid= -p "$pid" | tr -d ' ')" == "$CORE_PID" ]] && newest="$pid"
  done
  echo "$newest"
}

fixture_reference_apps() {
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    start_all_reference_apps
  else
    REFERENCE_APP_ROLES=() REFERENCE_APP_IDS=() REFERENCE_APP_PIDS=()
    start_reference_app terminal
    start_reference_app editor
    g1_note "development run: foot and Kate only; Firefox runs on the reference machine"
  fi
}

apps_alive() {
  local pid
  for pid in "${REFERENCE_APP_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null || return 1; done
}

# Stop everything the fixture started and remove its runtime directory
# (sockets, the fixture store, the application logs).
shell_fixture_stop() {
  stop_all
  if [[ -z "${DITTO_REFERENCE_MACHINE:-}" && "${RUNTIME_DIR:-}" == /tmp/ditto-g0.* && -d "$RUNTIME_DIR" ]]; then
    chmod -R u+w -- "$RUNTIME_DIR" 2>/dev/null || true
    rm -rf -- "$RUNTIME_DIR"
  fi
  return 0
}
