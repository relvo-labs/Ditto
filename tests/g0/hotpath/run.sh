#!/usr/bin/env bash
# EX-04 harness: the four-phase interaction script, frame intervals and the
# request count per phase. The pass criteria are decided on the reference
# machine; software rendering here can only show the harness works and that the
# hot path issues no requests.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"

WINDOW_PIDS=()
SHELL_PID=""
trap 'kill "$SHELL_PID" 2>/dev/null || true; stop_all' EXIT INT TERM

RUN_ID="$(run_id)"
FRAMES="$ARTIFACTS/frametime-$RUN_ID.jsonl"
COUNTS="$ARTIFACTS/hotpath-rpc-count-$RUN_ID.json"
PHASE_SECONDS="${DITTO_PHASE_SECONDS:-10}"
mkdir -p "$ARTIFACTS"

start_compositor
start_core
export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software DITTO_FRAME_PROBE=1

quickshell --no-color -p "$WORKSPACE/shell/shell.qml" >"$RUNTIME_DIR/shell.log" 2>&1 &
SHELL_PID=$!
for _ in $(seq 1 200); do grep -aq 'desktop.events.subscribe' "$RUNTIME_DIR/shell.log" && break; sleep 0.05; done
grep -aq 'ditto-shell started' "$RUNTIME_DIR/shell.log" || { tail -20 "$RUNTIME_DIR/shell.log"; echo 'the shell did not start' >&2; exit 1; }
start_window ditto-hotpath

phase() {
  local name="$1"
  echo "phase $name $(date +%s%3N)" >>"$RUNTIME_DIR/phases.log"
}

# 1: the character alone, with nothing happening.
phase idle
sleep "$PHASE_SECONDS"

# 2: the pointer crossing the character, which is what drives the gaze.
phase pointer
end=$((SECONDS + PHASE_SECONDS))
while (( SECONDS < end )); do
  for x in 1100 1140 1180 1140; do
    compositor_move_cursor "$x" 560 || true
    sleep 0.1
  done
done

# 3: dragging a window: the position updates belong to the compositor.
phase drag
compositor_make_floating ditto-hotpath
end=$((SECONDS + PHASE_SECONDS))
while (( SECONDS < end )); do
  for offset in 0 40 80 40; do
    compositor_move_window ditto-hotpath $((200 + offset)) 200
    sleep 0.25
  done
done

# 4: five explicit workspace switches through the shell's own command path.
phase commands
for workspace in 2 3 1 2 1; do
  bash "$WORKSPACE/shell/tools/recall.sh" "workspace $workspace"
  sleep 0.8
done
phase end

python3 - "$RUNTIME_DIR/shell.log" "$RUNTIME_DIR/phases.log" "$FRAMES" "$COUNTS" "$RUN_ID" "$(environment_label)" <<'PYEOF'
import json, re, sys

shell_log, phase_log, frames_path, counts_path, run_id, environment = sys.argv[1:7]
phases = []
for line in open(phase_log, encoding="utf-8"):
    name, at = line.split()[1:3]
    phases.append((name, int(at)))

def phase_at(timestamp: int) -> str:
    current = "before"
    for name, at in phases:
        if timestamp >= at:
            current = name
    return current

frame_pattern = re.compile(r"ditto-frame (\d+) (\d+)")
rpc_pattern = re.compile(r"ditto-rpc (\d+) (\S+)")
per_phase: dict[str, dict] = {}
with open(frames_path, "w", encoding="utf-8") as out:
    for line in open(shell_log, encoding="utf-8", errors="replace"):
        frame = frame_pattern.search(line)
        if frame:
            at, interval = int(frame.group(1)), int(frame.group(2))
            name = phase_at(at)
            entry = per_phase.setdefault(name, {"frames": [], "requests": []})
            entry["frames"].append(interval)
            out.write(json.dumps({"run_id": run_id, "ts_ms": at, "phase": name,
                                  "interval_ms": interval, "environment": environment}) + "\n")
            continue
        request = rpc_pattern.search(line)
        if request:
            at, method = int(request.group(1)), request.group(2)
            name = phase_at(at)
            per_phase.setdefault(name, {"frames": [], "requests": []})["requests"].append(method)

report = {"run_id": run_id, "environment": environment, "phases": {}}
for name, entry in per_phase.items():
    intervals = sorted(entry["frames"])
    report["phases"][name] = {
        "frames": len(intervals),
        "p95_ms": intervals[int(len(intervals) * 0.95) - 1] if intervals else None,
        "share_within_16_7ms": round(sum(1 for value in intervals if value <= 17) / len(intervals), 4) if intervals else None,
        "requests": entry["requests"],
    }
with open(counts_path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, ensure_ascii=False, indent=2)

animation_phases = ["idle", "pointer", "drag"]
offending = {name: report["phases"][name]["requests"]
             for name in animation_phases
             if report["phases"].get(name, {}).get("requests")}
for name, values in report["phases"].items():
    print(f'{name:10} frames={values["frames"]:5} p95={values["p95_ms"]} '
          f'within-16.7ms={values["share_within_16_7ms"]} requests={len(values["requests"])}')
print(f"frames -> {frames_path}")
print(f"counts -> {counts_path}")
if offending:
    print(f"hot path issued requests: {offending}")
    raise SystemExit(1)
commands = report["phases"].get("commands", {}).get("requests", [])
print(f"explicit commands issued {len(commands)} requests: {sorted(set(commands))}")
if len(commands) != 5:
    print("five explicit commands must produce five requests, one each")
    raise SystemExit(1)
print("hot path clean: no requests during idle, pointer or drag phases")
print("frame times from software rendering are not NFR-05 evidence; EX-04 is measured on the reference machine")
PYEOF
