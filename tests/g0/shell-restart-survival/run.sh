#!/usr/bin/env bash
# EX-03: replacing the shell must not cost the user any work. Twenty restarts,
# ten of them a kill with no chance to clean up; every reference application
# keeps its PID and the unsaved buffer keeps its content.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/lib/reference-apps.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

WINDOW_PIDS=()
BUFFER_PID=""
SHELL_PID=""
trap 'kill "$BUFFER_PID" "$SHELL_PID" 2>/dev/null || true; stop_all' EXIT INT TERM

RUN_ID="$(run_id)"
OUTPUT="$ARTIFACTS/shell-restart-$RUN_ID.json"
mkdir -p "$ARTIFACTS"

start_compositor
start_core
export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software

buffer_socket="$RUNTIME_DIR/ditto-unsaved-$$.sock"
python3 "$HERE/unsaved-buffer.py" "$buffer_socket" "未儲存的內容 $(date -u +%s)" >"$RUNTIME_DIR/buffer.log" 2>&1 &
BUFFER_PID=$!
for _ in $(seq 1 100); do [[ -S "$buffer_socket" ]] && break; sleep 0.1; done
[[ -S "$buffer_socket" ]] || { cat "$RUNTIME_DIR/buffer.log"; echo 'the unsaved buffer did not start' >&2; exit 1; }

read_buffer() {
  python3 -c "
import socket, sys
connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.connect(sys.argv[1])
print(connection.makefile().readline().strip())
" "$buffer_socket"
}
initial_hash="$(read_buffer)"

if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
  for command in firefox kate qdbus wl-paste; do
    command -v "$command" >/dev/null || { echo "reference application dependency missing: $command" >&2; exit 1; }
  done
  start_all_reference_apps
  unsaved_content="未儲存的內容 $(date -u +%s)"
  kate_open_unsaved "$unsaved_content"
  initial_hash="$(printf %s "$unsaved_content" | sha256sum | awk '{print $1}')"
  current_hash="$(kate_unsaved_hash)"
  [[ "$current_hash" == "$initial_hash" ]] || {
    echo 'could not read back the initial unsaved Kate buffer' >&2
    exit 1
  }
  initial_pids=("${REFERENCE_APP_PIDS[@]}")
  editor_label='Kate 23.08.5 unsaved buffer, read back through clipboard'
else
  start_window ditto-restart-1
  start_window ditto-restart-2
  initial_pids=("${WINDOW_PIDS[@]}" "$BUFFER_PID")
  editor_label='stand-in holding unsaved content in memory; development evidence only'
fi

start_shell() {
  quickshell --no-color -p "$WORKSPACE/shell/shell.qml" >>"$RUNTIME_DIR/shell.log" 2>&1 &
  SHELL_PID=$!
  local started=0
  for _ in $(seq 1 200); do
    if grep -aq 'ditto-shell started' "$RUNTIME_DIR/shell.log"; then started=1; break; fi
    sleep 0.05
  done
  [[ "$started" -eq 1 ]] || { tail -20 "$RUNTIME_DIR/shell.log"; echo 'the shell did not start' >&2; exit 1; }
}

results="[]"
: >"$RUNTIME_DIR/shell.log"
start_shell
for cycle in $(seq 1 20); do
  : >"$RUNTIME_DIR/shell.log"
  started_at="$(date +%s%3N)"
  if (( cycle % 2 == 0 )); then
    signal=KILL
  else
    signal=TERM
  fi
  kill "-$signal" "$SHELL_PID" 2>/dev/null || true
  wait "$SHELL_PID" 2>/dev/null || true
  start_shell
  finished_at="$(date +%s%3N)"

  alive=true
  for pid in "${initial_pids[@]}"; do
    kill -0 "$pid" 2>/dev/null || alive=false
  done
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    current_hash="$(kate_unsaved_hash)"
  else
    current_hash="$(read_buffer)"
  fi
  windows="$("$BINARIES/dittoctl" --json probe windows | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["windows"]))')"
  results="$(python3 -c "
import json, sys
entries = json.loads(sys.argv[1])
entries.append({
    'cycle': int(sys.argv[2]), 'signal': sys.argv[3],
    'applications_alive': sys.argv[4] == 'true',
    'buffer_unchanged': sys.argv[5] == sys.argv[6],
    'windows_listed': int(sys.argv[7]),
    'restart_ms': int(sys.argv[8]) - int(sys.argv[9]),
})
print(json.dumps(entries))
" "$results" "$cycle" "$signal" "$alive" "$current_hash" "$initial_hash" "$windows" "$finished_at" "$started_at")"
  [[ "$alive" == true ]] || { echo "cycle $cycle: an application was lost" >&2; break; }
  [[ "$current_hash" == "$initial_hash" ]] || { echo "cycle $cycle: unsaved content changed" >&2; break; }
done

python3 - "$OUTPUT" "$RUN_ID" "$(environment_label)" "$editor_label" "$results" <<'PYEOF'
import json, sys

output, run_id, environment, editor, results = sys.argv[1:6]
cycles = json.loads(results)
record = {
    "run_id": run_id,
    "environment": environment,
    "editor": editor,
    "cycles": cycles,
    "applications_survived": all(cycle["applications_alive"] for cycle in cycles),
    "unsaved_content_preserved": all(cycle["buffer_unchanged"] for cycle in cycles),
    "restart_ms_median": sorted(cycle["restart_ms"] for cycle in cycles)[len(cycles) // 2] if cycles else None,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=False, indent=2)
print(f'{len(cycles)} cycles, applications survived: {record["applications_survived"]}, '
      f'unsaved content preserved: {record["unsaved_content_preserved"]}, '
      f'median restart {record["restart_ms_median"]} ms -> {output}')
raise SystemExit(0 if len(cycles) == 20 and record["applications_survived"]
                 and record["unsaved_content_preserved"] else 1)
PYEOF
if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
  echo 'reference-machine evidence: Firefox, foot and Kate survived; Kate unsaved content was read back every cycle'
else
  echo 'development evidence only; EX-03 is decided on the reference machine with the frozen application set'
fi
