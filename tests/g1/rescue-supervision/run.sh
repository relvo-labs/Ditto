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
  for scope in ditto-shell.scope ditto-quickshell.scope; do
    group="$(systemctl --user show -p ControlGroup --value "$scope" 2>/dev/null || true)"
    if [[ "$group" == /*.scope && -r "/sys/fs/cgroup$group/cgroup.procs" ]]; then
      cat "/sys/fs/cgroup$group/cgroup.procs"
      return 0
    fi
  done
}

if systemctl --user is-active --quiet ditto-session.target 2>/dev/null; then
  g1_note "environment: logged-in Ditto session; the real units are exercised"
  export DITTO_RUNTIME_DIR="${DITTO_RUNTIME_DIR:-$XDG_RUNTIME_DIR/ditto}"
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
  elif ! "$BINARIES/dittoctl" rescue restart shell --help >/dev/null 2>&1; then
    # Each run ends with the main Shell back; without a restart path the
    # second run would start from the rescue UI.
    check shell-sigstop-rescue not_implemented "dittoctl rescue restart shell is not available, so a run cannot restore the main Shell"
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
        if journalctl --user -u ditto-rescue.service --since "$since" -o cat 2>/dev/null | grep -q 'ditto-rescue ready'; then
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
      systemctl --user stop ditto-rescue.service >/dev/null 2>&1 || true
      "$BINARIES/dittoctl" rescue restart shell >/dev/null 2>&1 || true
      sleep 3
    done
    worst="$(p95 "${durations[@]}")"
    evidence="$(python3 -c 'import json, sys; print(json.dumps({"runs": int(sys.argv[1]), "durations_ms": [int(v) for v in sys.argv[3:]], "failures": int(sys.argv[2])}))' "$RUNS" "$failures" "${durations[@]}")"
    if (( failures == 0 )) && python3 -c "import sys; sys.exit(0 if float('$worst') <= 10000 else 1)"; then
      check shell-sigstop-rescue pass "p95 ${worst} ms over $RUNS runs (NFR-08: 10 s)" "$evidence"
    else
      check shell-sigstop-rescue fail "p95 ${worst} ms, $failures runs without a rescue UI" "$evidence"
    fi
    # Survival of reference applications and unsaved content across these
    # runs reuses the EX-03 method (tests/g0/shell-restart-survival); it is not
    # wired in yet, so the criterion is not claimed.
    check shell-sigstop-apps-survive not_implemented "application and unsaved-content survival is not checked by this runner yet"
  fi

  # ② needs a crashing fixture plugin and the plugin center's disable record.
  missing="$(missing_capabilities "$listing" desktop.plugins.list desktop.plugins.diagnostics desktop.changes.propose)"
  if [[ -n "$missing" ]]; then
    check plugin-crash-disabled not_implemented "Core does not serve: $missing"
  elif [[ ! -d "$WORKSPACE/tests/g1/fixtures/crashing-plugin" ]]; then
    check plugin-crash-disabled not_implemented "no crashing fixture plugin at tests/g1/fixtures/crashing-plugin"
  else
    check plugin-crash-disabled not_implemented "install → crash loop → disabled-state readback is not written yet"
  fi

  # ③ kills Core until systemd stops restarting it, then waits for the rescue
  # unit. Only with DITTO_ALLOW_CORE_STORM=1: it interrupts the session.
  if [[ -z "${DITTO_ALLOW_CORE_STORM:-}" ]]; then
    check core-storm-onfailure operator "set DITTO_ALLOW_CORE_STORM=1 to kill Core in this session"
  elif ! systemctl --user is-active --quiet ditto-core.service; then
    check core-storm-onfailure fail "ditto-core.service is not active before the storm"
  else
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
    rescue_active=false
    for _ in $(seq 1 100); do
      systemctl --user is-active --quiet ditto-rescue.service && { rescue_active=true; break; }
      sleep 0.1
    done
    request="$(cat "$DITTO_RUNTIME_DIR/rescue-request.json" 2>/dev/null || echo null)"
    evidence="$(python3 -c 'import json, sys; print(json.dumps({"kills": int(sys.argv[1]), "core_state": sys.argv[2], "rescue_active": sys.argv[3] == "true", "rescue_request": json.loads(sys.argv[4])}))' "$kills" "$state" "$rescue_active" "$request")"
    if [[ "$state" == failed && "$rescue_active" == true ]]; then
      if "$BINARIES/dittoctl" --offline rescue restore-last-good --help >/dev/null 2>&1; then
        check core-storm-onfailure not_implemented "OnFailure= reached the rescue unit; the offline restore is not exercised yet" "$evidence"
      else
        check core-storm-onfailure not_implemented "OnFailure= reached the rescue unit, but dittoctl --offline rescue does not exist, so the rescue UI cannot restore" "$evidence"
      fi
    else
      check core-storm-onfailure fail "after $kills kills Core is '$state' and the rescue unit active=$rescue_active" "$evidence"
    fi
    systemctl --user reset-failed ditto-core.service >/dev/null 2>&1 || true
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
