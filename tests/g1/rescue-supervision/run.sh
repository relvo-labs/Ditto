#!/usr/bin/env bash
# EX1-12 ①②③: supervision and rescue.
#   ① Shell SIGSTOP → an operable rescue UI within 10 s (NFR-08), 30 runs,
#     p95; reference applications and unsaved content survive.
#   ② a crashing plugin is disabled after its threshold, the reason and the
#     re-enable entry are visible, and it is not restarted again.
#   ③ a Core restart storm triggers OnFailure= and the rescue UI works.
#
# Two environments:
#   * a logged-in "Ditto (Wayfire)" session (ditto-session.target active):
#     the real units, the real Shell scope, the real rescue unit. ① and ③ are
#     only decided here, and ③ really kills Core.
#   * anything else: a headless fixture. It can only measure the supervisor's
#     detection against a real Quickshell Shell; the rescue UI half of ① and
#     all of ③ are recorded as environment, never as pass.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g0/lib/reference-apps.sh"

WINDOW_PIDS=()
SHELL_PID=""
SUPERVISOR_PID=""
trap 'kill "$SUPERVISOR_PID" 2>/dev/null || true; kill -CONT "$SHELL_PID" 2>/dev/null || true; kill "$SHELL_PID" 2>/dev/null || true; stop_all' EXIT INT TERM

RUNS="${DITTO_RESCUE_RUNS:-30}"
g1_begin rescue-supervision "EX1-12 ①②③"
g1_preflight

supervisor="$BINARIES/ditto-supervisor"
[[ -x "$supervisor" ]] || { echo "missing $supervisor; cargo build -p ditto-supervisor" >&2; exit 1; }

p95() {
  python3 -c 'import sys, math
values = sorted(float(v) for v in sys.argv[1:])
print(values[max(0, math.ceil(0.95 * len(values)) - 1)] if values else "null")' "$@"
}

# The main Shell's processes, from its scope only. An empty ControlGroup (the
# unit is not loaded) must never become /sys/fs/cgroup/cgroup.procs.
shell_scope_pids() {
  local scope group
  for scope in ditto-quickshell.scope ditto-shell.scope; do
    group="$(systemctl --user show -p ControlGroup --value "$scope" 2>/dev/null || true)"
    if [[ "$group" == /*.scope && -r "/sys/fs/cgroup$group/cgroup.procs" ]]; then
      cat "/sys/fs/cgroup$group/cgroup.procs"
      return 0
    fi
  done
}

# ②: the crashes_host fault fixture takes hostd down 1.5 s after each enable.
# Core counts hostd deaths that follow an enable (hosts.rs, limit 2 within
# 30 s of the enable) and disables the entry through a Supervisor ChangeSet.
# Read back: the entry is supervisor_disabled with its reason, the plugin
# list (plugin center and dittoctl read the same capability) shows it, and
# afterwards hostd keeps one PID for 20 s: nothing restarts the entry.
plugin_crash_disabled() {
  local work profile head ops entry state hostd_pids evidence deadline
  work="$(g1_evidence_dir)"
  # The fixture is a verification built-in (install-session.sh
  # --verification-relay): G1 enables built-in packages only.
  if ! g1_call desktop.plugins.get '{"package_id":"ditto.fixture.fault_crashes_host"}' | grep -q '"result"'; then
    check plugin-crash-disabled environment "the crashes_host fixture is not a built-in of this session (install with --verification-relay)"
    return
  fi
  profile="$(g1_call desktop.profiles.get '{}')"
  head="$(jq -r .result.profile.head_revision <<<"$profile")"
  ops='[{"op":"add_entry","entry":{"package":"ditto.fixture.fault_crashes_host","version":"1.0.0","host":"cordis"}}]'
  g1_call desktop.changes.propose "$(jq -cn --arg base "$head" --argjson ops "$ops" '{base_revision: $base, ops: $ops}')" >"$work/enable.json"
  deadline=$(( $(date +%s) + 90 ))
  state=""
  while (( $(date +%s) < deadline )); do
    entry="$(g1_call desktop.plugins.list '{}' | jq -c '[.result.entries[] | select(.package == "ditto.fixture.fault_crashes_host")][0]')"
    state="$(jq -r '.state.kind // .state // empty' <<<"$entry" 2>/dev/null || true)"
    [[ "$state" == supervisor_disabled ]] && break
    sleep 1
  done
  hostd_pids=()
  for _ in $(seq 1 20); do
    hostd_pids+=("$(scope_pids ditto-hostd.scope | head -1)")
    sleep 1
  done
  evidence="$(jq -cn --argjson entry "${entry:-null}" --arg pids "${hostd_pids[*]}" --slurpfile enable "$work/enable.json" \
    '{entry: $entry, enable: $enable[0], hostd_pid_each_second_after: ($pids | split(" "))}')"
  if [[ "$state" != supervisor_disabled ]]; then
    check plugin-crash-disabled fail "the crashing entry was not disabled by supervision within 90 s (state: ${state:-none})" "$evidence"
  elif [[ "$(printf '%s\n' "${hostd_pids[@]}" | sort -u | wc -l)" != 1 || -z "${hostd_pids[0]}" ]]; then
    check plugin-crash-disabled fail "disabled, but hostd was restarted again afterwards (or is not running)" "$evidence"
  else
    check plugin-crash-disabled pass "disabled by supervision ($(jq -r '.state.reason // empty' <<<"$entry")), listed with its reason for the plugin center and dittoctl, and hostd kept one PID for 20 s" "$evidence"
  fi
  # Leave the session as it was: the entry out of the Profile.
  profile="$(g1_call desktop.profiles.get '{}')"
  entry_id="$(jq -r '[.result.document.entries[] | select(.package == "ditto.fixture.fault_crashes_host") | .entry_id][0] // empty' <<<"$profile")"
  if [[ -n "$entry_id" ]]; then
    g1_call desktop.changes.propose "$(jq -cn --arg base "$(jq -r .result.profile.head_revision <<<"$profile")" --arg id "$entry_id" \
      '{base_revision: $base, ops: [{op: "remove_entry", entry_id: $id}]}')" >/dev/null || true
  fi
}

if in_ditto_session; then
  g1_note "environment: logged-in Ditto session; the real units are exercised"
  RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ditto-g1-rescue.XXXXXX")"
  # Applications whose survival ① checks: foot and Kate with an unsaved
  # buffer (Firefox joins on the reference machine).
  REFERENCE_APP_ROLES=() REFERENCE_APP_IDS=() REFERENCE_APP_PIDS=()
  apps_ready=""
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    start_all_reference_apps && apps_ready=1
  else
    start_reference_app terminal && start_reference_app editor && apps_ready=1
  fi
  kate_before=""
  if [[ -n "$apps_ready" ]] && kate_open_unsaved "Ditto EX1-12 未儲存 $RUN_ID"; then
    sleep 1
    kate_before="$(kate_unsaved_hash || true)"
  fi
  listing="$(g1_capabilities)"

  # ① needs: the supervisor unit, a Shell that answers ping, and a rescue UI
  # that announces itself. The rescue UI must print `ditto-rescue ready` once
  # its surface is mapped and takes input (tests/g1/README.md).
  missing="$(missing_capabilities "$listing" desktop.rescue.status)"
  if ! systemctl --user is-active --quiet ditto-supervisor.service; then
    check shell-sigstop-rescue fail "ditto-supervisor.service is not active in this session"
  elif ! "$supervisor" --once >/dev/null 2>&1; then
    check shell-sigstop-rescue not_implemented "the Shell does not answer 'ping <n>' on shell.sock (crates/ditto-supervisor/README.md)"
  elif [[ -n "$missing" ]]; then
    check shell-sigstop-rescue not_implemented "Core does not serve: $missing"
  elif [[ ! -f "$WORKSPACE/shell/rescue/shell.qml" ]]; then
    check shell-sigstop-rescue not_implemented "no rescue UI at shell/rescue/shell.qml"
  else
    durations=()
    failures=0
    for run in $(seq 1 "$RUNS"); do
      mapfile -t shell_pids < <(shell_scope_pids)
      [[ ${#shell_pids[@]} -gt 0 ]] || { failures=$((failures + 1)); echo "run $run: no Shell scope" >&2; continue; }
      since="$(date '+%Y-%m-%d %H:%M:%S')"
      started="$(date +%s%3N)"
      kill -STOP "${shell_pids[@]}"
      ready=""
      for _ in $(seq 1 300); do
        # Core launches the rescue UI while it runs (its output is in Core's
        # journal); the unit is only used when Core itself is down.
        if journalctl --user -u ditto-rescue.service -u ditto-core.service --since "$since" -o cat 2>/dev/null | grep -q 'ditto-rescue ready'; then
          ready="$(date +%s%3N)"
          break
        fi
        sleep 0.05
      done
      if [[ -z "$ready" ]]; then
        failures=$((failures + 1))
        echo "run $run: no operable rescue UI within 15 s" >&2
      else
        durations+=("$(( ready - started ))")
      fi
      # Back to the normal Shell the way the rescue UI's 「回到一般桌面」 does.
      resumed="$(g1_call desktop.rescue.resume_shell '{}' 2>/dev/null || true)"
      if ! jq -e '.result.shell_connected == true' <<<"$resumed" >/dev/null 2>&1; then
        echo "run $run: the normal Shell did not come back: $resumed" >&2
      fi
      sleep 3
    done
    worst="$(p95 "${durations[@]}")"
    evidence="$(python3 -c 'import json, sys; print(json.dumps({"runs": int(sys.argv[1]), "durations_ms": [int(v) for v in sys.argv[3:]], "failures": int(sys.argv[2])}))' "$RUNS" "$failures" "${durations[@]}")"
    if (( failures == 0 )) && python3 -c "import sys; sys.exit(0 if float('$worst') <= 10000 else 1)"; then
      check shell-sigstop-rescue pass "p95 ${worst} ms over $RUNS runs (NFR-08: 10 s)" "$evidence"
    else
      check shell-sigstop-rescue fail "p95 ${worst} ms, $failures runs without a rescue UI" "$evidence"
    fi
    # Survival across all runs, by the EX-03 method: the same PIDs, and
    # Kate's unsaved buffer hash read back from Kate itself.
    alive=1
    for pid in "${REFERENCE_APP_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null || alive=""; done
    kate_after="$(kate_unsaved_hash 2>/dev/null || true)"
    survival="$(jq -cn --arg apps "${REFERENCE_APP_IDS[*]}" --arg before "$kate_before" --arg after "$kate_after" --arg alive "${alive:-0}" \
      '{apps: ($apps | split(" ")), all_alive: ($alive == "1"), kate_unsaved_sha256: {before: $before, after: $after}}')"
    if [[ -z "$apps_ready" || -z "$kate_before" ]]; then
      check shell-sigstop-apps-survive environment "the reference applications or Kate's buffer could not be set up in this session" "$survival"
    elif [[ -n "$alive" && "$kate_before" == "$kate_after" ]]; then
      check shell-sigstop-apps-survive pass "after $RUNS runs every reference application is alive and Kate's unsaved buffer hash is unchanged" "$survival"
    else
      check shell-sigstop-apps-survive fail "a reference application ended or Kate's unsaved buffer changed" "$survival"
    fi
  fi

  # ② needs a crashing fixture plugin and the plugin center's disable record.
  missing="$(missing_capabilities "$listing" desktop.plugins.list desktop.plugins.diagnostics desktop.changes.propose)"
  if [[ -n "$missing" ]]; then
    check plugin-crash-disabled not_implemented "Core does not serve: $missing"
  elif ! g1_can_call; then
    check plugin-crash-disabled environment "no verification relay in this session (install-session.sh --verification-relay)"
  else
    plugin_crash_disabled
  fi

  # ③ kills Core until systemd stops restarting it, then waits for the rescue
  # unit. Only with DITTO_ALLOW_CORE_STORM=1: it interrupts the session.
  if [[ -z "${DITTO_ALLOW_CORE_STORM:-}" ]]; then
    check core-storm-onfailure operator "set DITTO_ALLOW_CORE_STORM=1 to kill Core in this session"
  elif ! systemctl --user is-active --quiet ditto-core.service; then
    check core-storm-onfailure fail "ditto-core.service is not active before the storm"
  else
    # The rescue restores the protected last-known-good revision, which a
    # revision becomes after 60 s without instability; ① and ② just caused
    # some. Wait for one, as a user's desktop would have.
    protected=""
    for _ in $(seq 1 240); do
      protected="$(g1_call desktop.rescue.status '{}' | jq -r '.result.last_known_good // empty' 2>/dev/null || true)"
      [[ -n "$protected" ]] && break
      sleep 1
    done
    g1_note "③ protected revision before the storm: ${protected:-none after 240 s}"
    kills=0
    for _ in $(seq 1 8); do
      state="$(systemctl --user show -p ActiveState --value ditto-core.service)"
      [[ "$state" == failed ]] && break
      pid="$(systemctl --user show -p MainPID --value ditto-core.service)"
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        kill -KILL "$pid" && kills=$((kills + 1))
      fi
      # RestartSec=1; wait for the next MainPID or the failed state.
      for _ in $(seq 1 100); do
        new="$(systemctl --user show -p MainPID --value ditto-core.service)"
        state="$(systemctl --user show -p ActiveState --value ditto-core.service)"
        [[ "$state" == failed || ( "$new" != "$pid" && "$new" != 0 && "$state" == active ) ]] && break
        sleep 0.1
      done
    done
    storm_journal="$(g1_evidence_dir)/core-storm-journal.txt"
    systemctl --user show ditto-core.service -p NRestarts -p StartLimitBurst -p StartLimitIntervalUSec -p Result -p ActiveState >"$storm_journal" 2>&1 || true
    journalctl --user -u ditto-core.service -u ditto-rescue.service --since "-5min" -o short-monotonic 2>/dev/null | grep -v 'ditto-rpc\|lease_registered' | tail -120 >>"$storm_journal" || true
    rescue_active=false
    for _ in $(seq 1 100); do
      systemctl --user is-active --quiet ditto-rescue.service && { rescue_active=true; break; }
      sleep 0.1
    done
    request="$(cat "$DITTO_RUNTIME_DIR/rescue-request.json" 2>/dev/null || echo null)"
    evidence="$(python3 -c 'import json, sys; print(json.dumps({"kills": int(sys.argv[1]), "core_state": sys.argv[2], "rescue_active": sys.argv[3] == "true", "rescue_request": json.loads(sys.argv[4])}))' "$kills" "$state" "$rescue_active" "$request")"
    if [[ "$state" == failed && "$rescue_active" == true ]]; then
      # What the rescue UI's 「恢復最近可用的組合」 runs: the offline restore
      # while Core is down, then Core again, which must mount that revision.
      rescue_ready=false
      for _ in $(seq 1 200); do
        journalctl --user -u ditto-rescue.service -o cat 2>/dev/null | grep -q 'ditto-rescue ready' && { rescue_ready=true; break; }
        sleep 0.1
      done
      restored="$("$BINARIES/dittoctl" --json --offline rescue restore-last-good 2>&1 || true)"
      printf '%s\n' "$restored" >"$(g1_evidence_dir)/offline-restore.txt"
      revision="$(jq -r '.revision // .result.revision // empty' <<<"$restored" 2>/dev/null || true)"
      systemctl --user stop ditto-rescue.service >/dev/null 2>&1 || true
      systemctl --user reset-failed ditto-core.service >/dev/null 2>&1 || true
      systemctl --user start ditto-core.service >/dev/null 2>&1 || true
      head=""
      for _ in $(seq 1 150); do
        if systemctl --user is-active --quiet ditto-core.service && g1_can_call; then
          head="$(g1_call desktop.profiles.get '{}' | jq -r '.result.profile.head_revision // empty')"
          [[ -n "$head" ]] && break
        fi
        sleep 0.2
      done
      evidence="$(jq -c --arg ready "$rescue_ready" --argjson restored "$(jq -c . <<<"$restored" 2>/dev/null || echo null)" --arg raw "$restored" \
        --arg head "$head" --arg protected "$protected" \
        '. + {rescue_ui_ready: ($ready == "true"), protected_before_storm: $protected, offline_restore: $restored, offline_restore_output: $raw, head_after_core_restart: $head}' <<<"$evidence")"
      if [[ "$rescue_ready" == true && -n "$revision" && "$head" == "$revision" ]]; then
        check core-storm-onfailure pass "after $kills kills OnFailure= started an operable rescue UI; the offline restore set $revision and the restarted Core mounted it" "$evidence"
      else
        check core-storm-onfailure fail "rescue UI ready=$rescue_ready, restored revision '${revision:-none}', head after Core restart '${head:-none}'" "$evidence"
      fi
    else
      check core-storm-onfailure fail "after $kills kills Core is '$state' and the rescue unit active=$rescue_active" "$evidence"
    fi
    systemctl --user reset-failed ditto-core.service >/dev/null 2>&1 || true
    systemctl --user is-active --quiet ditto-core.service || systemctl --user start ditto-core.service >/dev/null 2>&1 || true
  fi
else
  g1_note "environment: headless fixture; ① is measured only up to the supervisor killing the Shell, ② and ③ need the session"
  start_compositor
  export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software
  mkdir -p "$DITTO_RUNTIME_DIR"
  command -v quickshell >/dev/null || { check shell-sigstop-detect environment "quickshell is not on PATH"; g1_finish; }
  : >"$RUNTIME_DIR/shell.log"
  quickshell --no-color -p "$WORKSPACE/shell/shell.qml" >>"$RUNTIME_DIR/shell.log" 2>&1 &
  SHELL_PID=$!
  for _ in $(seq 1 200); do grep -aq 'ditto-shell started' "$RUNTIME_DIR/shell.log" && break; sleep 0.05; done
  if ! "$supervisor" --once >/dev/null 2>&1; then
    check shell-sigstop-detect not_implemented "the Shell does not answer 'ping <n>' on shell.sock (crates/ditto-supervisor/README.md)"
  else
    durations=()
    not_killed=0
    for run in $(seq 1 "${DITTO_DETECT_RUNS:-5}"); do
      if [[ "$run" -gt 1 ]]; then
        quickshell --no-color -p "$WORKSPACE/shell/shell.qml" >>"$RUNTIME_DIR/shell.log" 2>&1 &
        SHELL_PID=$!
        for _ in $(seq 1 200); do "$supervisor" --once >/dev/null 2>&1 && break; sleep 0.05; done
      fi
      echo "$SHELL_PID" >"$DITTO_RUNTIME_DIR/shell.pid"
      "$supervisor" --no-rescue --shell-scope ditto-g1-fixture-none.scope >>"$RUNTIME_DIR/supervisor.log" 2>&1 &
      SUPERVISOR_PID=$!
      sleep 2.5
      started="$(date +%s%3N)"
      kill -STOP "$SHELL_PID"
      while kill -0 "$SHELL_PID" 2>/dev/null && [[ "$(awk '{print $3}' "/proc/$SHELL_PID/stat" 2>/dev/null)" != Z ]]; do
        (( $(date +%s%3N) - started > 15000 )) && break
        sleep 0.05
      done
      if kill -0 "$SHELL_PID" 2>/dev/null && [[ "$(awk '{print $3}' "/proc/$SHELL_PID/stat" 2>/dev/null)" != Z ]]; then
        not_killed=$((not_killed + 1))
        kill -KILL "$SHELL_PID" 2>/dev/null || true
      fi
      wait "$SHELL_PID" 2>/dev/null || true
      durations+=("$(( $(date +%s%3N) - started ))")
      kill "$SUPERVISOR_PID" 2>/dev/null || true
      wait "$SUPERVISOR_PID" 2>/dev/null || true
    done
    evidence="$(python3 -c 'import json, sys; print(json.dumps({"sigstop_to_kill_ms": [int(v) for v in sys.argv[1:]]}))' "${durations[@]}")"
    if (( not_killed == 0 )); then
      check shell-sigstop-detect pass "supervisor killed the stopped Shell in every run; p95 $(p95 "${durations[@]}") ms (detection only, no rescue UI)" "$evidence"
    else
      check shell-sigstop-detect fail "$not_killed runs: the stopped Shell was still alive after 15 s" "$evidence"
    fi
  fi
  check shell-sigstop-rescue environment "the rescue UI half of ① needs a logged-in Ditto session"
  check plugin-crash-disabled environment "② needs a logged-in Ditto session with hostd"
  check core-storm-onfailure environment "③ needs ditto-core.service under the user manager"
fi

g1_finish
