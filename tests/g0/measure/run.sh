#!/usr/bin/env bash
# G0-QA-01/EX-05 measurement mechanics: restart the measured services, warm up,
# sample three times, then emit one report with the fingerprint, full process
# list and exclusions. A service restart is not a cold display-manager login;
# the conditions file must keep that distinction visible.
#
# It refuses to run outside the frozen reference machine unless it is told to
# produce a format check, because a number from anywhere else cannot be
# compared with the next one.
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../../.." && pwd)"
artifacts="${DITTO_ARTIFACTS:-$workspace/artifacts/g0}"
binaries="${DITTO_BINARIES:-$workspace/target/debug}"
manifest="${1:-$workspace/tests/g0/measure/manifest.template.json}"
conditions="${2:-$workspace/tests/g0/measure/conditions.template.json}"
warmup="${DITTO_WARMUP_SECONDS:-300}"
duration="${DITTO_SAMPLE_SECONDS:-600}"
interval_ms="${DITTO_SAMPLE_INTERVAL_MS:-5000}"
session="$workspace/tests/g0/measure/session.sh"

if [[ -z "${DITTO_REFERENCE_MACHINE:-}" && -z "${DITTO_FORMAT_CHECK:-}" ]]; then
  cat >&2 <<'MESSAGE'
This flow produces the numbers EX-05 is approved from, so it runs on the frozen
reference machine: set DITTO_REFERENCE_MACHINE=1 there.
To check the tool's output format somewhere else, set DITTO_FORMAT_CHECK=1; the
report is then written with a development label and must not enter a review.
MESSAGE
  exit 2
fi

if [[ -n "${DITTO_FORMAT_CHECK:-}" ]]; then
  warmup="${DITTO_WARMUP_SECONDS:-2}"
  duration="${DITTO_SAMPLE_SECONDS:-10}"
  interval_ms="${DITTO_SAMPLE_INTERVAL_MS:-1000}"
  manifest="${1:-$workspace/tests/g0/measure/manifest.format-check.json}"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  # A unit that exists, so the sampler's own path is exercised rather than
  # skipped: process discovery goes through cgroups, never process names.
  systemctl --user stop ditto-format-check.service >/dev/null 2>&1 || true
  systemd-run --user --quiet --unit=ditto-format-check.service sleep 600
  trap 'systemctl --user stop ditto-format-check.service >/dev/null 2>&1 || true' EXIT
fi

if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
  # ditto-measure talks to the user manager to resolve unit cgroups. The
  # measured services themselves receive their private Wayland runtime from
  # session.sh; the sampler must keep the real user-manager runtime here.
  export XDG_RUNTIME_DIR="${DITTO_SYSTEMD_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
fi

for path in "$manifest" "$conditions"; do
  [[ -f "$path" ]] || {
    echo "missing $path: the reference machine supplies its own manifest and conditions; copy the templates next to them and fill in the real values" >&2
    exit 2
  }
done

run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$workspace" rev-parse --short=3 HEAD 2>/dev/null || echo 000)"
mkdir -p "$artifacts"
count=$(( duration * 1000 / interval_ms ))
prepare_manifest() {
  local repeat="$1" destination="$2"
  python3 - "$manifest" "$destination" "$run_id-run$repeat" "$workspace" <<'PYEOF'
import json, subprocess, sys

source, destination, run_id, workspace = sys.argv[1:5]
manifest = json.load(open(source, encoding="utf-8"))
manifest["run_id"] = run_id

def value(argv, fallback):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout.strip() or fallback
    except Exception:
        return fallback

fingerprint = manifest["fingerprint"]
fingerprint["kernel"] = value(["uname", "-r"], fingerprint["kernel"])
fingerprint["rust"] = value(["rustc", "--version"], fingerprint["rust"])
fingerprint["node"] = value(["node", "--version"], fingerprint["node"])
fingerprint["qt"] = value(["qmake6", "-query", "QT_VERSION"], fingerprint["qt"])
fingerprint["quickshell"] = value(["quickshell", "--version"], fingerprint["quickshell"])
fingerprint["compositor"] = value(["wayfire", "--version"], fingerprint["compositor"])
fingerprint["ditto_commit"] = value(["git", "-C", workspace, "rev-parse", "HEAD"], fingerprint["ditto_commit"])
json.dump(manifest, open(destination, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF
}


runs=()
cleanup_measurement_session() {
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    bash "$session" stop >/dev/null 2>&1 || true
  fi
}
trap cleanup_measurement_session EXIT INT TERM
for repeat in 1 2 3; do
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    bash "$session" start
  fi
  echo "run $repeat/3: warming up for ${warmup}s"
  sleep "$warmup"
  output="$artifacts/measure-$run_id-run$repeat.jsonl"
  prepared="$artifacts/measure-manifest-$run_id-run$repeat.json"
  # Each repeat carries its own run id; the report refuses to average a run
  # with itself.
  prepare_manifest "$repeat" "$prepared"
  echo "run $repeat/3: sampling ${count} points every ${interval_ms} ms"
  "$binaries/ditto-measure" sample "$prepared" "$count" "$interval_ms" "$output"
  runs+=("$output")
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    bash "$session" stop
  fi
done

report="$artifacts/resource-report-$run_id.md"
"$binaries/ditto-measure" report "$conditions" "${runs[0]}" "${runs[1]}" "${runs[2]}" "$report"
echo "report -> $report"
if [[ -n "${DITTO_FORMAT_CHECK:-}" ]]; then
  echo 'format check only: these numbers are not EX-05 evidence'
fi
