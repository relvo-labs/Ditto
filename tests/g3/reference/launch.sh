#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mode="${1:?full|desktop|faults|partial|unavailable}" run="${2:?unique run ID}"
[[ "$mode" =~ ^(full|desktop|faults|partial|unavailable)$ && "$run" =~ ^[a-zA-Z0-9-]+$ ]] || exit 64
[[ "${DITTO_G3_ALLOW_PHYSICAL_LOGIN:-0}" == 1 && "${DITTO_G3_ALLOW_REAL_MODEL:-0}" == 1 ]] || exit 64
: "${DITTO_G3_SUBSCRIPTION_STORE:?existing private signed-in store required}"
export XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
out="$PWD/artifacts/g3/reference-$run"
[[ ! -e "$out" ]] || { echo 'Use a new evidence ID'; exit 1; }
mkdir -m 0700 -p "$out"
systemd-run --user --unit="g3-reference-$run" --service-type=exec \
    -p "WorkingDirectory=$PWD" -p RuntimeMaxSec=35min -p TimeoutStopSec=180s \
    -p "StandardOutput=append:$out/run.log" -p "StandardError=append:$out/run.log" \
    --setenv="DITTO_ARTIFACTS=$out" --setenv="DITTO_BINARIES=${DITTO_BINARIES:-$PWD/target/release}" \
    --setenv="DITTO_G3_REFERENCE_MODE=$mode" --setenv="DITTO_G3_SUBSCRIPTION_STORE=$DITTO_G3_SUBSCRIPTION_STORE" \
    --setenv=DITTO_G3_ALLOW_REAL_MODEL=1 --setenv=DITTO_G3_ALLOW_PHYSICAL_LOGIN=1 \
    /bin/bash "$PWD/tests/g3/reference/seat.sh"
