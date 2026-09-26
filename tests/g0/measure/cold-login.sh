#!/usr/bin/env bash
# EX-05 cold-login series. run.sh restarts measurement services, which is not a
# display-manager login; this script measures the desktop that a real login
# through "Ditto G0 (Wayfire)" started, one login per run.
#
#   cold-login.sh prepare standard|avatar-off|reduced-motion
#       Select the desktop state the *next* login starts in, then log out and
#       log in again from the login screen.
#   cold-login.sh sample
#       Run once per fresh login, before anything else is opened. Starts the
#       frozen reference applications, warms up for 300 s, samples 600 s every
#       5 s, and appends the run to that state's series.
#   cold-login.sh report standard|avatar-off|reduced-motion
#       Build the report from the last three runs of that state, each from a
#       different login.
#
# DITTO_FORMAT_CHECK=1 runs the same flow on a development machine or VM: no
# reference-machine preflight, a separate series, and a report that says it is
# not EX-05 evidence.
#
# Layers are attributed by cgroup: the session script runs Wayfire, Core,
# Quickshell and Fcitx in their own user scopes. A login whose compositor fell
# back into the logind session scope is refused rather than measured.
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../../.." && pwd)"
artifacts="${DITTO_ARTIFACTS:-$workspace/artifacts/g0}"
binaries="${DITTO_BINARIES:-$workspace/target/release}"
variant_file="${XDG_CONFIG_HOME:-$HOME/.config}/ditto-g0/measure-variant"
warmup="${DITTO_WARMUP_SECONDS:-300}"
duration="${DITTO_SAMPLE_SECONDS:-600}"
interval_ms="${DITTO_SAMPLE_INTERVAL_MS:-5000}"
# A login that has been in use for longer than this is no longer cold.
max_login_age="${DITTO_MAX_LOGIN_AGE_SECONDS:-600}"
scopes=(ditto-g0-wayfire.scope ditto-g0-core.scope ditto-g0-quickshell.scope ditto-g0-fcitx.scope)
app_scopes=(ditto-ref-browser.scope ditto-ref-terminal.scope ditto-ref-editor.scope)

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

valid_variant() {
  case "$1" in standard|avatar-off|reduced-motion) return 0 ;; esac
  echo "unknown state '$1'; expected standard, avatar-off or reduced-motion" >&2
  return 2
}

format_check="${DITTO_FORMAT_CHECK:-}"
series_file() { echo "$artifacts/cold-login-series${format_check:+-format-check}-$1.jsonl"; }

scope_main_pid() {
  systemctl --user show -p MainPID --value "$1" 2>/dev/null | grep -E '^[1-9][0-9]*$' ||
    head -1 "/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value "$1")/cgroup.procs" 2>/dev/null
}

prepare() {
  valid_variant "$1"
  mkdir -p "$(dirname "$variant_file")"
  if [[ "$1" == standard ]]; then rm -f -- "$variant_file"; else printf '%s\n' "$1" >"$variant_file"; fi
  echo "the next Ditto G0 login starts in state '$1'; log out and log in from the login screen"
}

stop_apps() {
  systemctl --user stop "${app_scopes[@]}" >/dev/null 2>&1 || true
}

start_app() {
  local unit="$1" app_id="$2"
  shift 2
  systemd-run --user --scope --quiet --collect --unit="$unit" -- "$@" >/dev/null 2>&1 &
  compositor_wait_for_window "$app_id" || { echo "$app_id did not map in the login session" >&2; return 1; }
}

sample() {
  if [[ -n "$format_check" ]]; then
    echo 'format check: reference-machine preflight skipped; this run is not EX-05 evidence' >&2
  else
    bash "$workspace/packaging/reference-image/preflight.sh"
  fi
  local unit
  for unit in "${scopes[@]}"; do
    systemctl --user is-active --quiet "$unit" || {
      echo "$unit is not running: this is not a login started by the current session script" >&2
      echo 'reinstall with packaging/reference-image/install-session.sh and log in again' >&2
      exit 1
    }
  done

  local wayfire_pid session_id login_usec now_usec login_age variant shell_pid shell_env
  wayfire_pid="$(scope_main_pid ditto-g0-wayfire.scope)"
  session_id="$(tr '\0' '\n' <"/proc/$wayfire_pid/environ" | sed -n 's/^XDG_SESSION_ID=//p')"
  [[ -n "$session_id" ]] || { echo 'could not read the login session of the compositor' >&2; exit 1; }
  login_usec="$(loginctl show-session "$session_id" -p TimestampMonotonic --value)"
  now_usec="$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)"
  login_age=$(( (now_usec - login_usec) / 1000000 ))
  if (( login_age > max_login_age )); then
    echo "login $session_id started ${login_age}s ago; a cold-login run must start within ${max_login_age}s of logging in" >&2
    exit 1
  fi

  variant="$(cat "$variant_file" 2>/dev/null || echo standard)"
  valid_variant "$variant"
  shell_pid="$(scope_main_pid ditto-g0-quickshell.scope)"
  shell_env="$(tr '\0' '\n' <"/proc/$shell_pid/environ")"
  case "$variant" in
    standard) ! grep -qE '^DITTO_AVATAR=off$|^DITTO_REDUCED_MOTION=1$' <<<"$shell_env" ;;
    avatar-off) grep -qx 'DITTO_AVATAR=off' <<<"$shell_env" ;;
    reduced-motion) grep -qx 'DITTO_REDUCED_MOTION=1' <<<"$shell_env" ;;
  esac || { echo "the running Shell is not in state '$variant'; log in again after prepare" >&2; exit 1; }

  local series
  series="$(series_file "$variant")"
  if [[ -f "$series" ]] && jq -e --arg s "$session_id" 'select(.session_id == $s)' "$series" >/dev/null 2>&1; then
    echo "login $session_id already has a run in this series; each run needs its own login" >&2
    exit 1
  fi

  # The measured desktop is the login session's own compositor.
  WAYLAND_DISPLAY="$(tr '\0' '\n' <"/proc/$wayfire_pid/environ" | sed -n 's/^WAYLAND_DISPLAY=//p')"
  [[ -n "$WAYLAND_DISPLAY" ]] || WAYLAND_DISPLAY="$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p')"
  export WAYLAND_DISPLAY WAYFIRE_SOCKET="$XDG_RUNTIME_DIR/ditto-wayfire-ipc.sock" DITTO_COMPOSITOR=wayfire
  unset DISPLAY
  # shellcheck source=/dev/null
  source "$workspace/tools/compositor-probe/functional/compositor.sh"

  mkdir -p "$artifacts"
  local run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$workspace" rev-parse --short=4 HEAD)-$variant"
  trap stop_apps EXIT INT TERM

  # Warm-up: the frozen reference applications with fixed content, as in the
  # other reference fixtures. They are user-opened applications and excluded.
  local firefox_profile="$HOME/snap/firefox/common/ditto-g0-reference-profile"
  mkdir -p "$firefox_profile"
  start_app ditto-ref-browser firefox_firefox env MOZ_ENABLE_WAYLAND=1 MOZ_DISABLE_WAYLAND_PROXY=1 \
    firefox --no-remote --profile "$firefox_profile" about:blank
  start_app ditto-ref-terminal ditto-ref-terminal foot --app-id=ditto-ref-terminal sh -c 'sleep infinity'
  start_app ditto-ref-editor org.kde.kate env QT_QPA_PLATFORM=wayland QT_IM_MODULE=fcitx QT_IM_MODULES=fcitx kate --new
  local kate
  kate="$(qdbus | awk '/org\.kde\.kate-[0-9]+/{print $1; exit}')"
  [[ -n "$kate" && "$(qdbus "$kate" /MainApplication org.kde.Kate.Application.openInput \
    'Ditto G0 cold-login fixture: unsaved buffer' UTF-8)" == true ]] ||
    { echo 'could not open the fixed Kate content' >&2; exit 1; }
  compositor_focus_window firefox_firefox
  compositor_focus_window ditto-ref-terminal
  compositor_focus_window org.kde.kate

  echo "login $session_id (${login_age}s old), state $variant: warming up for ${warmup}s"
  sleep "$warmup"

  local manifest="$artifacts/measure-manifest-$run_id.json" output="$artifacts/measure-$run_id.jsonl"
  python3 - "$manifest" "$run_id" "$workspace" "$session_id" <<'PYEOF'
import json, subprocess, sys

destination, run_id, workspace, session_id = sys.argv[1:5]

def value(argv):
    return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout.strip()

manifest = {
    "run_id": run_id,
    "state": "desktop_full_no_agent_g0_subset",
    "fingerprint": {
        "kernel": value(["uname", "-r"]),
        "compositor": value(["wayfire", "--version"]),
        "qt": value(["qmake6", "-query", "QT_VERSION"]),
        "quickshell": value(["quickshell", "--version"]),
        "rust": value(["rustc", "--version"]),
        "node": value(["node", "--version"]),
        "ditto_commit": value(["git", "-C", workspace, "rev-parse", "HEAD"]),
    },
    "units": [
        {"name": "ditto-g0-wayfire.scope", "layer": "compositor", "scope": "user"},
        {"name": "ditto-g0-core.scope", "layer": "core", "scope": "user"},
        {"name": "ditto-g0-quickshell.scope", "layer": "shell", "scope": "user"},
        {"name": "ditto-g0-fcitx.scope", "layer": "input-method", "scope": "user"},
    ],
    "excluded": [
        {"unit": "ditto-ref-browser.scope", "reason": "reference application the user opened"},
        {"unit": "ditto-ref-terminal.scope", "reason": "reference application the user opened"},
        {"unit": "ditto-ref-editor.scope", "reason": "reference application the user opened"},
        # The same name in every run: the report compares exclusion lists, and
        # the per-login session id is recorded in the series and conditions.
        {"unit": "session-<login>.scope", "reason": "display manager login plumbing (gdm-session-worker, gdm-wayland-session, the session entry script)"},
    ],
}
json.dump(manifest, open(destination, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF
  local count=$(( duration * 1000 / interval_ms ))
  echo "sampling ${count} points every ${interval_ms} ms"
  "$binaries/ditto-measure" sample "$manifest" "$count" "$interval_ms" "$output"

  jq -cn --arg run "$run_id" --arg session "$session_id" --argjson age "$login_age" --argjson warmup "$warmup" \
    --arg output "$output" --arg manifest "$manifest" --arg variant "$variant" \
    '{run_id: $run, session_id: $session, login_age_seconds: $age, warmup_seconds: $warmup, state: $variant, samples: $output, manifest: $manifest}' \
    >>"$series"
  echo "run $run_id recorded in $series ($(wc -l <"$series") so far)"
}

report() {
  valid_variant "$1"
  local series
  series="$(series_file "$1")"
  [[ -f "$series" ]] || { echo "no runs recorded for state '$1'" >&2; exit 1; }
  mapfile -t runs < <(jq -sr 'unique_by(.session_id) | sort_by(.run_id) | .[-3:][] | .samples' "$series")
  (( ${#runs[@]} == 3 )) || { echo "state '$1' has ${#runs[@]} runs from distinct logins; three are required" >&2; exit 1; }
  local conditions="$artifacts/cold-login-conditions-$1.json"
  local machine=ditto-ref-ws-rtx4060-01 physical=true
  [[ -n "$format_check" ]] && machine="development-$(hostname)" && physical=false
  jq -n --arg state "$1" --arg machine "$machine" --argjson physical "$physical" --slurpfile runs <(jq -s 'unique_by(.session_id) | sort_by(.run_id) | .[-3:]' "$series") '{
    reference_machine_id: $machine,
    physical_reference_machine: $physical,
    cold_login_each_run: true,
    # The shortest warm-up actually used, not the procedure'"'"'s nominal value.
    warmup_seconds: ($runs[0] | map(.warmup_seconds // 0) | min),
    fixed_variables: ([
      "one display-manager login through Ditto G0 (Wayfire) per run; runs from logins \($runs[0] | map(.session_id) | join(", "))",
      "seconds from login to the start of the run: \($runs[0] | map(.login_age_seconds | tostring) | join(", "))",
      "desktop state: \($state)",
      "Ditto G0 Core, Shell, Wayfire and frozen character asset at 1920x1080 60 Hz scale 1",
      "Firefox 156.0.1-1, foot 1.16.2 and Kate 23.08.5 with the G0 fixture content",
      "the user systemd manager lingers for the reference runner, so it is not restarted by a login",
      "no Cordis host and no Agent; this is the desktop_full_no_agent_g0_subset state"
    ])
  }' >"$conditions"
  local out="$artifacts/resource-report-cold-login${format_check:+-format-check}-$1-$(date -u +%Y-%m-%dT%H:%M:%SZ).md"
  "$binaries/ditto-measure" report "$conditions" "${runs[@]}" "$out"
  echo "report -> $out"
}

case "${1:-}" in
  prepare) prepare "${2:?state}" ;;
  sample) sample ;;
  report) report "${2:?state}" ;;
  *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac
