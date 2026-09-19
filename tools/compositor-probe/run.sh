#!/usr/bin/env bash
# One JSON document per compositor. Pass --functional to add the second layer,
# which needs a live session with a compositor the probe can drive.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: tools/compositor-probe/run.sh <compositor-label> [--functional]" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
label="$1"
shift

if [[ "${1:-}" == "--functional" ]]; then
  functional="$(mktemp)"
  trap 'rm -f "$functional"' EXIT
  bash "$script_dir/functional/run.sh" "$label" >"$functional"
  exec python3 "$script_dir/probe.py" --label "$label" --functional "$functional"
fi
exec python3 "$script_dir/probe.py" --label "$label"
