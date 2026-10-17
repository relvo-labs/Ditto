#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
export PATH="$HOME/.nvm/versions/node/v22.23.2/bin:$HOME/Qt/6.10.2/gcc_64/bin:$HOME/wayfire/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/wayfire/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DITTO_ARTIFACTS="$PWD/artifacts/g3"
source tests/g0/lib/session.sh
mkdir -p "$ARTIFACTS/runtime"
export DITTO_FIXTURE_RUNTIME_PARENT="$ARTIFACTS/runtime"
WINDOW_PIDS=()
trap stop_all EXIT INT TERM
start_compositor
export DITTO_G3_COMPOSITOR_PID="$COMPOSITOR_PID"
node tests/g3/restart/run.mjs
