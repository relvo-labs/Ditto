#!/usr/bin/env bash
# EX-07: identity comes from the launcher, never from what the caller says.
# One positive and three negatives; every refusal must be an explicit error and
# not a quiet downgrade to anonymous service.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

WINDOW_PIDS=()
trap stop_all EXIT INT TERM

start_compositor

# Launcher mode: no shared token exists. Each client is bound to the PID the
# launcher spawned before the token reaches it.
"$BINARIES/ditto-core" serve --compositor "${DITTO_COMPOSITOR:-wayfire}" \
  --launch "dittoctl 0.1.0 $BINARIES/dittoctl probe capabilities" \
  --launch "token-client 0.1.0 /usr/bin/bash $HERE/token-client.sh" \
  >"$RUNTIME_DIR/core.log" 2>&1 &
CORE_PID=$!
for _ in $(seq 1 100); do
  [[ -S "$RUNTIME_DIR/ditto/core.sock" ]] && break
  sleep 0.1
done
[[ -S "$RUNTIME_DIR/ditto/core.sock" ]] || { cat "$RUNTIME_DIR/core.log"; echo 'Core socket did not appear' >&2; exit 1; }
export DITTO_CORE_SOCKET="$RUNTIME_DIR/ditto/core.sock"

for _ in $(seq 1 150); do
  grep -q 'desktop.capabilities.list: ok' "$RUNTIME_DIR/core.log" && break
  sleep 0.1
done
grep -q 'desktop.capabilities.list: ok' "$RUNTIME_DIR/core.log" || {
  cat "$RUNTIME_DIR/core.log"
  echo 'positive failed: a client started by the launcher was not served' >&2
  exit 1
}
echo 'positive: the client the launcher started was served'

for _ in $(seq 1 150); do
  grep -q 'LAUNCHED_TOKEN' "$RUNTIME_DIR/core.log" && break
  sleep 0.1
done
valid_token="$(sed -n 's/^LAUNCHED_TOKEN //p' "$RUNTIME_DIR/core.log" | head -1)"
[[ -n "$valid_token" ]] || { cat "$RUNTIME_DIR/core.log"; echo 'no token was handed to the second client' >&2; exit 1; }

check_refused() {
  local label="$1" kind="$2" token="$3"
  python3 - "$DITTO_CORE_SOCKET" "$kind" "$token" "$label" <<'PYEOF'
import json, socket, sys

path, kind, token, label = sys.argv[1:5]
connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.connect(path)
connection.sendall(json.dumps({
    "jsonrpc": "2.0", "id": "h", "method": "core.handshake",
    "params": {"protocol_version": "0.1.0",
               "client": {"kind": kind, "version": "0.1.0"},
               "auth": {"token": token}},
}).encode() + b"\n")
reply = json.loads(connection.makefile().readline())
if reply.get("result") is not None:
    raise SystemExit(f"{label} failed: the connection was served")
if reply.get("error", {}).get("name") != "identity_rejected":
    raise SystemExit(f"{label} failed: refusal was {reply}")
print(label)
PYEOF
}

check_refused 'negative 1: a valid token used by a process the launcher did not start is refused' dittoctl "$valid_token"
check_refused 'negative 2: a connection with no launcher binding is refused' dittoctl "0000000000000000"
check_refused 'negative 3: a self-declared client kind is refused' privileged-plugin "$valid_token"

echo 'EX-07 negatives refused here in the development container; the exit review repeats them on the reference machine'
