#!/usr/bin/env bash
# Run the G1 compositor probes C-15..C-19 against a headless Wayfire started
# for each probe, and keep one JSON document per probe plus the compositor log.
# Usage: tools/compositor-probe/g1/run.sh [c15 c16 c17 c18 c19]
# Everything recorded here is development evidence (headless); none of it is
# a reference-machine exit result.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"

probes=("$@")
[[ ${#probes[@]} -gt 0 ]] || probes=(c15 c16 c17 c18 c19)
RUN_ID="$(run_id)"
mkdir -p "$G1_ARTIFACTS"
status=0

for probe in "${probes[@]}"; do
  script="$(find "$here" -maxdepth 1 -name "$probe-*.py" -print -quit)"
  [[ -n "$script" ]] || { echo "unknown probe $probe" >&2; status=1; continue; }
  output="$G1_ARTIFACTS/$probe-$RUN_ID.json"
  (
    trap g1_stop EXIT
    g1_start_compositor
    cd "$here"
    rc=0
    DITTO_G1_ENVIRONMENT="$(environment_label) headless $WLR_RENDERER" \
      DITTO_G1_PROBE_ARTIFACTS="$G1_ARTIFACTS" DITTO_G1_RUN_ID="$RUN_ID" \
      python3 "$script" >"$output" || rc=$?
    cp -- "$COMPOSITOR_LOG" "$G1_ARTIFACTS/$probe-$RUN_ID.wayfire.log"
    exit "$rc"
  ) || { echo "$probe: probe did not complete (see $output)" >&2; status=1; }
  echo "$probe -> $output"
done
exit "$status"
