#!/usr/bin/env bash
# Opt-in, real subscription validation. Never run from CI or the VM suite.
set -euo pipefail
[[ "${DITTO_G3_ALLOW_REAL_MODEL:-0}" == 1 ]] || { echo 'Real-model validation requires explicit approval; set DITTO_G3_ALLOW_REAL_MODEL=1 only after approval.' >&2; exit 64; }
subscription_store="${DITTO_G3_SUBSCRIPTION_STORE:?Set a private signed-in development-test store}"
secret_bus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
cd "$(dirname "$0")/../../.."
export PATH="$HOME/.nvm/versions/node/v22.23.2/bin:$HOME/Qt/6.10.2/gcc_64/bin:$HOME/wayfire/bin:$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/wayfire/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DITTO_ARTIFACTS="$PWD/artifacts/g3"
source tests/g1/lib/common.sh
source tests/g1/lib/shell-fixture.sh
mkdir -p "$ARTIFACTS/runtime"
export DITTO_FIXTURE_RUNTIME_PARENT="$ARTIFACTS/runtime"
export DITTO_G3_AGENT_OUT="$ARTIFACTS/real-model-$(date -u +%Y%m%dT%H%M%SZ).json"
WINDOW_PIDS=()
cleanup() { [[ -z "${RUNTIME_DIR:-}" || ! -f "$RUNTIME_DIR/core.log" ]] || cp "$RUNTIME_DIR/core.log" "${DITTO_G3_AGENT_OUT%.json}.core.log"; shell_fixture_stop; }
trap cleanup EXIT INT TERM
start_compositor
# Keep the backend's existing CODEX_HOME/keyring reference. Core handles the
# writer lock; no token is exported, copied, logged, or supplied to this runner.
export DITTO_DATA_DIR="$subscription_store" DBUS_SESSION_BUS_ADDRESS="$secret_bus" DITTO_SYSTEM=none
export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software
NODE="$(readlink -f "$(command -v node)")" QUICKSHELL="$(readlink -f "$(command -v quickshell)")"
codex="$(readlink -f "${DITTO_CODEX_BINARY:-$HOME/.local/bin/codex}")"
pin_version="$(jq -r .version tools/codex/pin.json)" pin_sha="$(jq -r .sha256 tools/codex/pin.json)"
export DITTO_G1_RELAY="$RUNTIME_DIR/relay-$$.sock"
"$BINARIES/ditto-core" serve --compositor wayfire --builtin-packages "$PWD/target/ditto-packages" \
 --shell "quickshell 0.3.1 $QUICKSHELL -p $PWD/shell/shell.qml" \
 --hostd "$(g1_hostd_spec "$NODE" "$PWD/packages/host-runtime/dist/ditto-hostd.mjs")" \
 --agent "agent 0.3.0 $NODE $PWD/packages/agent-runtime/dist/ditto-agentd.mjs" \
 --agent-backend "codex-app-server $pin_version $pin_sha $codex" \
 --launch "dittoctl 0.3.0 $NODE $PWD/tests/g1/lib/relay.mjs $DITTO_G1_RELAY" >"$RUNTIME_DIR/core.log" 2>&1 &
CORE_PID=$!
for _ in $(seq 1 300); do
 [[ -S "$DITTO_G1_RELAY" && -S "$DITTO_RUNTIME_DIR/shell.sock" ]] && break
 kill -0 "$CORE_PID" 2>/dev/null || { cat "$RUNTIME_DIR/core.log"; exit 1; }
 sleep 0.1
done
node tests/g3/agent/real-driver.mjs
echo "Evidence: $DITTO_G3_AGENT_OUT"
