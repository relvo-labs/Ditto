#!/usr/bin/env bash
# EX1-10 orchestration on a machine whose login manager logs the user in
# automatically into "Ditto (Wayfire)" (GDM AutomaticLogin). For every run
# still missing, per state:
#
#   cold-login.sh prepare <state>          (in the login about to end)
#   sudo -n /usr/local/libexec/ditto-relogin
#   wait for a new login whose session is ready for the state
#   cold-login.sh sample <state>
#
# until the state's series holds three runs from three logins, then
# `cold-login.sh report <state>`. It is resumable: the series files are the
# record of what is done, so running it again continues where it stopped
# (an interrupted run's login is spent and never sampled again). Progress is
# appended to artifacts/g1/cold-login-progress[-format-check].log. At the end
# the measurement conditions are removed and, unless
# DITTO_SERIES_FINAL_RELOGIN=0, one more relogin leaves a normal desktop.
#
#   series.sh <state>...
#
# Run it outside the Ditto login it restarts: over SSH in tmux, or as a
# transient user service whose name does not start with `ditto-` (every
# active ditto-* unit must be a layer the sampler can classify):
#
#   systemd-run --user --unit=ex1-10-series --same-dir --collect \
#     bash tests/g1/measure/series.sh rescue_no_node desktop_full_no_agent ...
#
# DITTO_COLD_LOGIN and DITTO_RELOGIN_CMD replace the two commands (the
# self-test, test-series.sh, uses stubs). DITTO_LOGIN_TIMEOUT_SECONDS (240)
# bounds the wait for a login; DITTO_SERIES_MAX_FAILURES (3) bounds failed
# attempts per state before it stops.
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../../.." && pwd)"
artifacts="${DITTO_ARTIFACTS:-$workspace/artifacts/g1}"
cold_login="${DITTO_COLD_LOGIN:-$workspace/tests/g1/measure/cold-login.sh}"
read -ra relogin_cmd <<<"${DITTO_RELOGIN_CMD:-sudo -n /usr/local/libexec/ditto-relogin}"
login_timeout="${DITTO_LOGIN_TIMEOUT_SECONDS:-240}"
max_failures="${DITTO_SERIES_MAX_FAILURES:-3}"
final_relogin="${DITTO_SERIES_FINAL_RELOGIN:-1}"
progress="$artifacts/cold-login-progress${DITTO_FORMAT_CHECK:+-format-check}.log"
runs_per_state=3

(( $# )) || { sed -n '2,30p' "$0" >&2; exit 2; }
if [[ "${XDG_SESSION_DESKTOP:-}" == ditto && -n "${WAYLAND_DISPLAY:-}" ]]; then
  echo 'this shell belongs to the Ditto login that series.sh restarts; run it over SSH or as a user service' >&2
  exit 2
fi
mkdir -p "$artifacts"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$progress" >&2; }
cold() { bash "$cold_login" "$@"; }

relogged=""
relogin() {
  log "relogin: ${relogin_cmd[*]}"
  "${relogin_cmd[@]}"
  relogged=1
}

# Wait for a login other than $1 that is ready for state $2.
wait_for_login() {
  local old="$1" state="$2" deadline current why=""
  deadline=$(( $(date +%s) + login_timeout ))
  while (( $(date +%s) < deadline )); do
    current="$(cold login-id 2>/dev/null || true)"
    if [[ -n "$current" && "$current" != "$old" ]]; then
      why="$(cold ready "$state" 2>&1)" && { log "login $current is ready for $state"; return 0; }
    fi
    sleep 2
  done
  log "no new login ready for $state within ${login_timeout}s (last login '${current:-none}': ${why:-not started})"
  return 1
}

finish() {
  local status=$?
  trap - EXIT
  cold reset >/dev/null 2>&1 && log 'measure-conditions.json removed'
  if [[ -n "$relogged" && "$final_relogin" == 1 ]]; then
    log 'final relogin: back to a normal desktop'
    "${relogin_cmd[@]}" || log 'final relogin failed; log in again by hand'
  fi
  log "series.sh exits $status"
  exit "$status"
}
trap finish EXIT

for state in "$@"; do
  cold count "$state" >/dev/null
done
log "series.sh $* (resuming from the series files)"
for state in "$@"; do
  failures=0
  while (( $(cold count "$state") < runs_per_state )); do
    run=$(( $(cold count "$state") + 1 ))
    log "$state: run $run/$runs_per_state: prepare"
    cold prepare "$state" 2>&1 | tee -a "$progress" >&2
    old="$(cold login-id 2>/dev/null || true)"
    relogin
    if wait_for_login "$old" "$state"; then
      log "$state: run $run/$runs_per_state: sampling"
      if cold sample "$state" 2>&1 | tee -a "$progress" >&2; then
        log "$state: run $run/$runs_per_state recorded"
        continue
      fi
      log "$state: run $run/$runs_per_state failed (see above); its login is not sampled again"
    fi
    failures=$(( failures + 1 ))
    if (( failures >= max_failures )); then
      log "$state: $failures failed attempts; stopping. Fix the cause and run series.sh again to resume"
      exit 1
    fi
  done
  log "$state: $runs_per_state runs recorded; report"
  cold report "$state" 2>&1 | tee -a "$progress" >&2
done
log "all states done: $*"
