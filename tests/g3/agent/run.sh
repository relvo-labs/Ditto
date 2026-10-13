#!/usr/bin/env bash
# Pinned Codex app-server + a loopback scripted model, isolated test data.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export PATH="$HOME/.nvm/versions/node/v22.23.2/bin:$HOME/Qt/6.10.2/gcc_64/bin:$HOME/wayfire/bin:$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/wayfire/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DITTO_ARTIFACTS="$PWD/artifacts/g3"
source tests/g1/lib/common.sh
source tests/g1/lib/shell-fixture.sh
mkdir -p "$ARTIFACTS/runtime"
export DITTO_FIXTURE_RUNTIME_PARENT="$ARTIFACTS/runtime"
export DITTO_G3_AGENT_OUT="$ARTIFACTS/agent-$(date -u +%Y%m%dT%H%M%SZ).json"
WINDOW_PIDS=() PROVIDER_PID=""
cleanup() { [[ -z "$PROVIDER_PID" ]] || kill "$PROVIDER_PID" 2>/dev/null || true; [[ -z "${RUNTIME_DIR:-}" || ! -f "$RUNTIME_DIR/core.log" ]] || cp "$RUNTIME_DIR/core.log" "${DITTO_G3_AGENT_OUT%.json}.core.log"; shell_fixture_stop; }
trap cleanup EXIT INT TERM
start_compositor
node tests/g3/agent/provider.mjs "${DITTO_G3_AGENT_OUT%.json}.requests.jsonl" >"$RUNTIME_DIR/provider.port" 2>"$RUNTIME_DIR/provider.log" &
PROVIDER_PID=$!
for _ in $(seq 1 50); do [[ -s "$RUNTIME_DIR/provider.port" ]] && break; sleep 0.1; done
port="$(head -n1 "$RUNTIME_DIR/provider.port")"
pin_version="$(jq -r .version tools/codex/pin.json)" pin_sha="$(jq -r .sha256 tools/codex/pin.json)"
codex="$(readlink -f "${DITTO_CODEX_BINARY:-$HOME/.local/bin/codex}" 2>/dev/null || true)"
[[ -f "$codex" && "$(sha256sum "$codex" | cut -d' ' -f1)" == "$pin_sha" ]] || { echo "not_run: pinned Codex binary unavailable" >&2; exit 2; }
export DITTO_TEST_FIXTURE=1
shell_fixture_start --hostd \
 --agent "agent 0.3.0 $(readlink -f "$(command -v node)") $PWD/packages/agent-runtime/dist/ditto-agentd.mjs" \
 --agent-backend "codex-app-server $pin_version $pin_sha $codex" \
 --agent-backend-test-provider "http://127.0.0.1:$port/v1"
node tests/g3/agent/driver.mjs
echo "Evidence: $DITTO_G3_AGENT_OUT"
