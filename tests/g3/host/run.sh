#!/usr/bin/env bash
# Exhaustion is performed only after the runner attests real cgroup limits.
# Run in the disposable VM first; this is not reference-machine exit evidence.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
cargo build --locked -p ditto-test-host -p ditto-confine
python3 tests/g3/host/driver.py
