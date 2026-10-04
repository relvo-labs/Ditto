#!/usr/bin/env bash
# EX1-07: Cordis services outlive every client.
# With the tasks and notification-policy services enabled:
#   ① SIGKILL the Agent stand-in → a tasks file change still reaches the
#     QML panel within 2 s; the notification policy still suppresses by its
#     rules;
#   ② SIGKILL the Shell → the restarted Shell gets the latest tasks state from
#     its snapshot, and policy decisions made meanwhile are recorded;
#   ③ hostd's PID is the same through ① and ②.
#
# The fixture is a headless desktop (tests/g1/lib/shell-fixture.sh): Wayfire
# with its own session bus, Core in normal mode with the real Shell under its
# supervision, hostd, the Agent stand-in and the read-back relay. Core's
# ditto-system owns org.freedesktop.Notifications on the fixture's bus
# (DITTO_SYSTEM=no-logind), so notifications sent there are decided by the
# notification-policy service in hostd. The rule under test is focus mode
# with an empty allow-list: every non-critical notification is silenced, a
# critical one is shown (the control that shows the policy decides, rather
# than silencing everything).
#
# What is read, and from where:
#   - what the QML tasks panel holds: the Shell's `tasks` control line (the
#     mounted ui.tasks_panel provider's own model);
#   - the service, notifications and decisions: Core, through the relay
#     (desktop.tasks.list, desktop.notifications.list,
#     desktop.notifications.policy_status), never the Shell;
#   - the 2 s of ①: client monotonic clock from the file write to the first
#     20 ms poll in which the panel shows the line (no Core stamp exists for
#     what a panel shows).
# Evidence goes to artifacts/g1/cordis-independent-<run_id>.{json,d/}.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
SESSION=(python3 "$HERE/session.py")
WINDOW_PIDS=()
trap shell_fixture_stop EXIT INT TERM

g1_begin cordis-independent "EX1-07 ①②③"
g1_preflight
evidence="$(g1_evidence_dir)"
all_checks=(standin-killed notification-policy shell-killed hostd-pid-stable)

missing=()
for tool in quickshell node gdbus dbus-daemon; do command -v "$tool" >/dev/null || missing+=("$tool"); done
[[ -f "$WORKSPACE/packages/host-runtime/dist/ditto-hostd.mjs" ]] || missing+=("packages/host-runtime/dist/ditto-hostd.mjs (pnpm -r build)")
[[ -f "$WORKSPACE/target/ditto-packages/ditto.svc.tasks-1.0.0.dittopkg" ]] || missing+=("target/ditto-packages (scripts/build-builtin-packages.sh)")
if (( ${#missing[@]} > 0 )); then
  for id in "${all_checks[@]}"; do check "$id" environment "missing: ${missing[*]}"; done
  g1_finish
fi

start_compositor
if [[ -z "${DBUS_PID:-}" ]]; then
  for id in "${all_checks[@]}"; do check "$id" fail "the fixture's own session bus did not start"; done
  g1_finish
fi
NODE="$(readlink -f "$(command -v node)")"
work="$RUNTIME_DIR/cordis-work"
mkdir -p "$work"
save_log() { cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true; }
if ! shell_fixture_start --hostd \
  --launch "agent 0.2.0 $NODE $WORKSPACE/tests/g1/fixtures/agent-standin/standin.mjs hold"; then
  save_log
  for id in "${all_checks[@]}"; do check "$id" fail "the desktop fixture did not come up (Core, Shell, hostd, relay); log in $evidence/core.log"; done
  g1_finish
fi

if ! "${SESSION[@]}" setup "$work" >"$evidence/setup.json" 2>&1 || [[ "$(jq -r .ok "$evidence/setup.json" 2>/dev/null)" != true ]]; then
  save_log
  for id in "${all_checks[@]}"; do check "$id" fail "fixture setup: $(head -c 400 "$evidence/setup.json")"; done
  g1_finish
fi
todo="$(jq -r .todo "$evidence/setup.json")"
grep -aq 'system.component_unavailable.*notifications' "$RUNTIME_DIR/core.log" \
  && g1_note "Core logged the notification server unavailable: $(grep -a 'system.component_unavailable' "$RUNTIME_DIR/core.log" | head -1)"

standin="$(core_child agent-standin/standin.mjs)"
hostd_before="$(core_child ditto-hostd.mjs)"
shell_before="$(core_child shell/shell.qml)"
if [[ -z "$standin" || -z "$hostd_before" || -z "$shell_before" ]]; then
  save_log
  for id in "${all_checks[@]}"; do check "$id" fail "could not find the stand-in ($standin), hostd ($hostd_before) or the Shell ($shell_before) under Core"; done
  g1_finish
fi

# The rule is in force before anything is killed (the baseline ① compares to).
"${SESSION[@]}" notify g1-before normal "EX1-07 基準" >"$evidence/notify-before.json"

# ---- ① the Agent stand-in ----------------------------------------------------------
kill -KILL "$standin"
for _ in $(seq 1 50); do kill -0 "$standin" 2>/dev/null || break; sleep 0.1; done
standin_gone=true
kill -0 "$standin" 2>/dev/null && standin_gone=false
"${SESSION[@]}" tasks-to-panel "$todo" "g1 外部新增 $RUN_ID" >"$evidence/tasks-after-standin.json"
"${SESSION[@]}" notify g1-focus normal "EX1-07 一般" >"$evidence/notify-normal.json"
"${SESSION[@]}" notify g1-focus critical "EX1-07 緊急" >"$evidence/notify-critical.json"
hostd_mid="$(core_child ditto-hostd.mjs)"

verdict="$(python3 - "$evidence" "$standin_gone" <<'PYEOF'
import json, os, sys
evidence, gone = sys.argv[1], sys.argv[2] == "true"
load = lambda name: json.load(open(os.path.join(evidence, name)))
tasks = load("tasks-after-standin.json")
problems = []
if not gone:
    problems.append("the stand-in survived SIGKILL")
if tasks.get("panel_ms") is None:
    problems.append("the QML panel did not show the new line within 5 s")
elif tasks["panel_ms"] > 2000:
    problems.append(f"the QML panel showed it after {tasks['panel_ms']} ms (> 2000)")
if tasks.get("service_listed_ms") is None:
    problems.append("desktop.tasks.list does not list the new line")
print(json.dumps({"status": "fail" if problems else "pass", "detail": "; ".join(problems) or
    f"the QML tasks panel showed the external line {tasks['panel_ms']} ms after the write (desktop.tasks.list {tasks['service_listed_ms']} ms; 20 ms polls)"}, ensure_ascii=False))

def judged(name, decision, rule):
    record = load(name)
    if not record.get("ok"):
        return f"{name}: {record.get('error')}"
    item, policy = record.get("item"), record["policy"]
    if not record.get("server_owned"):
        return "Core does not own org.freedesktop.Notifications on the fixture bus"
    if item is None:
        return f"notification {record['id']} is not in desktop.notifications.list"
    if item["policy_unavailable"]:
        return f"notification {record['id']} was decided without the policy (shown as a fallback)"
    if item["decision"] != decision:
        return f"{record['app_name']} {record['urgency']}: decision {item['decision']}, expected {decision}"
    recent = policy.get("recent_for_app") or {}
    if recent.get("decision") != decision or recent.get("rule") != rule:
        return f"{record['app_name']}: the policy's record says {recent.get('decision')} by {recent.get('rule')}, expected {decision} by {rule}"
    return None
notes = [judged("notify-before.json", "silence", "focus"), judged("notify-normal.json", "silence", "focus"),
         judged("notify-critical.json", "show", "critical")]
notes = [note for note in notes if note]
print(json.dumps({"status": "fail" if notes else "pass", "detail": "; ".join(notes) or
    "after the stand-in's SIGKILL, focus mode still silences a normal notification and shows a critical one; both decisions are in the policy's record, none was a fallback"}, ensure_ascii=False))
PYEOF
)"
standin_verdict="$(sed -n 1p <<<"$verdict")"
policy_verdict="$(sed -n 2p <<<"$verdict")"
check standin-killed "$(jq -r .status <<<"$standin_verdict")" "① after SIGKILL of the Agent stand-in (pid $standin): $(jq -r .detail <<<"$standin_verdict")" \
  "$(jq -c --arg d "$evidence" '{tasks: ($d + "/tasks-after-standin.json")}' <<<'{}')"
check notification-policy "$(jq -r .status <<<"$policy_verdict")" "① $(jq -r .detail <<<"$policy_verdict")" \
  "$(jq -c --arg d "$evidence" '{before: ($d + "/notify-before.json"), normal: ($d + "/notify-normal.json"), critical: ($d + "/notify-critical.json")}' <<<'{}')"

# ---- ② the Shell -------------------------------------------------------------------
kill -KILL "$shell_before"
for _ in $(seq 1 50); do kill -0 "$shell_before" 2>/dev/null || break; sleep 0.05; done
# While no Shell is connected: the tasks file changes and a notification is
# decided. Core restarts the Shell after a 1 s backoff; absence is read back
# (socket refused and Core reports no Shell) right before and after.
"${SESSION[@]}" shell-absent >"$evidence/absent-before.json"
"${SESSION[@]}" append "$todo" "g1 Shell 不在時新增 $RUN_ID" >/dev/null
"${SESSION[@]}" notify g1-absent normal "EX1-07 Shell 不在" >"$evidence/notify-absent.json"
"${SESSION[@]}" shell-absent >"$evidence/absent-after.json"
restarted=""
for _ in $(seq 1 300); do
  candidate="$(core_child shell/shell.qml)"
  if [[ -n "$candidate" && "$candidate" != "$shell_before" ]] \
    && "${SESSION[@]}" panel 2>/dev/null | jq -e '.mounted == true and .loaded == true' >/dev/null 2>&1; then
    restarted="$candidate"
    break
  fi
  sleep 0.1
done
"${SESSION[@]}" panel >"$evidence/panel-after-restart.json" 2>&1 || true
hostd_after="$(core_child ditto-hostd.mjs)"
save_log

shell_verdict="$(python3 - "$evidence" "$restarted" "$RUN_ID" <<'PYEOF'
import json, os, sys
evidence, restarted, run_id = sys.argv[1], sys.argv[2], sys.argv[3]
load = lambda name: json.load(open(os.path.join(evidence, name)))
problems = []
if not (load("absent-before.json").get("absent") and load("absent-after.json").get("absent")):
    problems.append(f"the Shell was not absent around the change and the notification ({load('absent-before.json')}, {load('absent-after.json')})")
if not restarted:
    problems.append("Core did not restart a Shell with a mounted, loaded tasks panel within 30 s")
panel = load("panel-after-restart.json")
marker = f"g1 Shell 不在時新增 {run_id}"
if not any(marker in item for item in panel.get("open") or []):
    problems.append(f"the restarted Shell's tasks panel does not show the line added while it was gone ({panel})")
absent = load("notify-absent.json")
item = absent.get("item") or {}
recent = (absent.get("policy") or {}).get("recent_for_app") or {}
if not absent.get("ok") or item.get("decision") != "silence" or item.get("policy_unavailable") or recent.get("rule") != "focus":
    problems.append(f"the decision made while the Shell was gone is not recorded as silence by focus ({item}, {recent})")
print(json.dumps({"status": "fail" if problems else "pass", "detail": "; ".join(problems) or
    f"restarted Shell (pid {restarted}) shows the line added in its absence from its snapshot; the notification sent meanwhile is recorded silenced by focus mode"}, ensure_ascii=False))
PYEOF
)"
check shell-killed "$(jq -r .status <<<"$shell_verdict")" "② after SIGKILL of the Shell (pid $shell_before): $(jq -r .detail <<<"$shell_verdict")" \
  "$(jq -c --arg d "$evidence" '{absent: [($d + "/absent-before.json"), ($d + "/absent-after.json")], notification: ($d + "/notify-absent.json"), panel: ($d + "/panel-after-restart.json")}' <<<'{}')"

if [[ -n "$hostd_after" && "$hostd_before" == "$hostd_mid" && "$hostd_mid" == "$hostd_after" ]]; then
  check hostd-pid-stable pass "③ hostd PID $hostd_before before, after ① and after ②" "{\"before\": $hostd_before, \"after_standin\": $hostd_mid, \"after_shell\": $hostd_after}"
else
  check hostd-pid-stable fail "③ hostd PID changed: $hostd_before → ${hostd_mid:-gone} → ${hostd_after:-gone}"
fi
g1_finish
