#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
export PATH="$HOME/.nvm/versions/node/v22.23.2/bin:$HOME/.local/bin:$PATH"
export DITTO_ARTIFACTS="$PWD/artifacts/g3"
source tests/g1/lib/common.sh
source tests/g1/lib/shell-fixture.sh
mkdir -p "$ARTIFACTS/runtime"
export DITTO_FIXTURE_RUNTIME_PARENT="$ARTIFACTS/runtime"
WINDOW_PIDS=()
cleanup() { [[ -z "${RUNTIME_DIR:-}" || ! -f "$RUNTIME_DIR/core.log" ]] || cp "$RUNTIME_DIR/core.log" "${DITTO_G3_DESKTOP_OUT:-$ARTIFACTS/desktop-startup}.core.log"; shell_fixture_stop; }
trap cleanup EXIT INT TERM
start_compositor
shell_fixture_start --hostd
start_window ditto-g3-survival
export DITTO_G3_APP_PID="${WINDOW_PIDS[-1]}"
export DITTO_G3_DESKTOP_OUT="$ARTIFACTS/desktop-$(date -u +%Y%m%dT%H%M%SZ).json"
node tests/g3/desktop/driver.mjs || { cp "$RUNTIME_DIR/core.log" "${DITTO_G3_DESKTOP_OUT%.json}.core.log"; exit 1; }
cp "$RUNTIME_DIR/core.log" "${DITTO_G3_DESKTOP_OUT%.json}.core.log"
echo "Evidence: $DITTO_G3_DESKTOP_OUT"
