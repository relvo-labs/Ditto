#!/usr/bin/env bash
# EX1-05: rescue mode without Node. With hostd and the Agent stand-in stopped,
# `ditto-core --mode rescue`:
#   ① reference applications can be focused, moved and asked to close
#   ② the change history can be read
#   ③ the protected last known good revision can be restored
#   ④ Cordis-dependent capabilities are unavailable with reason rescue_mode,
#     and the Shell says so in product language
#   ⑤ the process list holds no Node process
#   ⑥ back in normal mode hostd rebuilds its services and tasks are intact
#
# This runner uses the headless fixture with Core in development mode, so
# its results are development evidence; ④'s Shell text and ⑥ need the session
# and hostd. The process list is saved whole, and the Node check is made on
# the processes Ditto started (Core's descendants and the ditto-* units):
# a developer's own editor or CLI running on Node is not Ditto's.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

WINDOW_PIDS=()
trap stop_all EXIT INT TERM

g1_begin rescue-no-node "EX1-05"
g1_preflight
evidence_dir="$ARTIFACTS/rescue-no-node-$RUN_ID.d"
mkdir -p "$evidence_dir"
g1_note "raw readbacks and the process list: $evidence_dir"

start_compositor
export DITTO_DEV_TOKEN="${DITTO_DEV_TOKEN:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
"$BINARIES/ditto-core" serve --compositor "$DITTO_COMPOSITOR" --mode rescue --development \
  >"$RUNTIME_DIR/core.log" 2>&1 &
CORE_PID=$!
for _ in $(seq 1 100); do
  [[ -S "$DITTO_RUNTIME_DIR/core.sock" ]] && break
  kill -0 "$CORE_PID" 2>/dev/null || break
  sleep 0.1
done
if [[ ! -S "$DITTO_RUNTIME_DIR/core.sock" ]]; then
  cp "$RUNTIME_DIR/core.log" "$evidence_dir/core.log" 2>/dev/null || true
  if grep -q 'usage:' "$RUNTIME_DIR/core.log" 2>/dev/null; then
    check rescue-mode-starts not_implemented "ditto-core does not accept --mode rescue"
  else
    check rescue-mode-starts fail "ditto-core --mode rescue did not bind its socket (core.log saved)"
  fi
  g1_finish
fi
check rescue-mode-starts pass "ditto-core --mode rescue is serving"

"$BINARIES/dittoctl" --json probe capabilities >"$evidence_dir/capabilities.json" 2>/dev/null || true
listing="$(g1_capabilities)"

# ① native window operations through Core, read back.
start_window ditto-g1-rescue-app
window="$(window_id_for ditto-g1-rescue-app)"
results=()
for request in "--focus" "--move 120 140" "--close"; do
  # shellcheck disable=SC2086
  record="$("$BINARIES/dittoctl" --json probe window "$window" $request 2>/dev/null || echo '{"ok":false}')"
  echo "$record" >>"$evidence_dir/window-operations.jsonl"
  # The first line is the operation; dittoctl follows it with a get.
  results+=("$(python3 -c 'import json, sys; r = json.loads(sys.argv[1].splitlines()[0]); print("ok" if r.get("ok") and (r.get("readback_verified") or sys.argv[2] == "--close") else "no")' "$record" "${request%% *}")")
done
if [[ "${results[*]}" == "ok ok ok" ]]; then
  check native-window-operations pass "focus, move (read back) and close request succeeded in rescue mode"
else
  check native-window-operations fail "focus/move/close results: ${results[*]} (window-operations.jsonl)"
fi

# ② and ③ go through capability calls.
for pair in "change-history:desktop.changes.list" "restore-last-good:desktop.rescue.restore_last_good"; do
  id="${pair%%:*}" capability="${pair#*:}"
  if ! has_capability "$listing" "$capability"; then
    check "$id" not_implemented "Core does not serve $capability as available in rescue mode"
  elif ! g1_can_call; then
    check "$id" not_implemented "dittoctl has no 'probe call <capability> <json>'"
  else
    params='{}'
    [[ "$id" == change-history ]] && params='{"limit":20}'
    record="$(g1_call "$capability" "$params" 2>/dev/null || echo '{"ok":false}')"
    echo "$record" >"$evidence_dir/$id.json"
    if python3 -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1]).get("ok") else 1)' "$record"; then
      # ③ also needs head == last_known_good read back from the store; the
      # call succeeding is not that readback.
      if [[ "$id" == restore-last-good ]]; then
        check "$id" not_implemented "the call succeeded; the head == last_known_good readback is not written yet" "$record"
      else
        check "$id" pass "$capability answered in rescue mode" "$record"
      fi
    else
      check "$id" fail "$capability failed in rescue mode" "$record"
    fi
  fi
done

# ④ every hostd-provided capability is unavailable, and says rescue_mode.
python3 - "$evidence_dir/capabilities.json" >"$evidence_dir/rescue-availability.json" <<'PYEOF'
import json, sys
try:
    record = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    record = {}
capabilities = (record.get("result") or {}).get("capabilities", [])
hostd = [c for c in capabilities if str(c.get("provider", "")).startswith("hostd")
         or (c.get("availability") or {}).get("kind") == "depends_on_provider"]
wrong = [c["capability_id"] for c in hostd
         if (c.get("availability") or {}).get("available") is not False
         or (c.get("availability") or {}).get("reason") != "rescue_mode"]
json.dump({"served": len(capabilities), "hostd_dependent": [c["capability_id"] for c in hostd],
           "not_marked_rescue_mode": wrong}, sys.stdout)
PYEOF
availability="$(cat "$evidence_dir/rescue-availability.json")"
if python3 -c 'import json, sys; d = json.loads(sys.argv[1]); sys.exit(0 if d["hostd_dependent"] and not d["not_marked_rescue_mode"] else 1)' "$availability"; then
  check cordis-unavailable-rescue-mode pass "every hostd-dependent capability is unavailable with reason rescue_mode" "$availability"
elif python3 -c 'import json, sys; sys.exit(0 if not json.loads(sys.argv[1])["hostd_dependent"] else 1)' "$availability"; then
  check cordis-unavailable-rescue-mode not_implemented "the catalog lists no hostd-dependent capability to check" "$availability"
else
  check cordis-unavailable-rescue-mode fail "hostd-dependent capabilities not marked rescue_mode" "$availability"
fi
check shell-says-unavailable environment "the Shell's '待辦與通知策略暫不可用' text needs a logged-in session (manual check list)"

# ⑤ no Node process among what Ditto started.
ps -eo pid,ppid,comm,args --no-headers >"$evidence_dir/processes.txt"
ditto_pids="$(python3 - "$CORE_PID" <<'PYEOF'
import os, sys
core = int(sys.argv[1])
children = {}
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    try:
        stat = open(f"/proc/{entry}/stat").read()
        parent = int(stat.rsplit(")", 1)[1].split()[1])
        cgroup = open(f"/proc/{entry}/cgroup").read()
    except OSError:
        continue
    children.setdefault(parent, []).append(int(entry))
    if "/ditto-" in cgroup and ("app-ditto-" not in cgroup):
        print(entry)
stack = [core]
while stack:
    pid = stack.pop()
    print(pid)
    stack.extend(children.get(pid, []))
PYEOF
)"
node_in_ditto=()
for pid in $(sort -un <<<"$ditto_pids"); do
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
  comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
  [[ "$comm" == node || "$exe" == */node ]] && node_in_ditto+=("$pid")
done
node_total="$(awk '$3 == "node"' "$evidence_dir/processes.txt" | wc -l)"
evidence="$(python3 -c 'import json, sys; print(json.dumps({"ditto_processes": len(sys.argv[2].split()), "node_in_ditto": [int(p) for p in sys.argv[3:]], "node_processes_on_machine": int(sys.argv[1])}))' "$node_total" "$ditto_pids" "${node_in_ditto[@]}")"
if (( ${#node_in_ditto[@]} == 0 )); then
  check no-node-process pass "no Node process among Ditto's processes ($node_total unrelated Node processes on the machine are listed in processes.txt)" "$evidence"
else
  check no-node-process fail "Node processes started by Ditto: ${node_in_ditto[*]}" "$evidence"
fi

# ⑥ needs hostd and the tasks service.
if has_capability "$listing" desktop.tasks.list; then
  check normal-mode-restores-tasks fail "desktop.tasks.list is available in rescue mode, which it must not be"
else
  check normal-mode-restores-tasks not_implemented "restart in normal mode with hostd and compare tasks is not written yet (needs G1-HOST)"
fi

g1_finish
