#!/usr/bin/env bash
# EX1-10 / G1-QA-05 cold-login series (plan/03/06 §7). Each run measures the
# desktop a real display-manager login through "Ditto (Wayfire)" started, one
# login per run, three runs per state.
#
#   cold-login.sh prepare <state>
#       Select the state the *next* login starts in (measure-conditions.json,
#       read by packaging/reference-image/session/ditto-session), then log out
#       and in again from the login screen (or run series.sh, which does it).
#   cold-login.sh sample <state>
#       Once per fresh login, before anything else is opened. Checks that the
#       running session really is in that state, starts the frozen reference
#       applications (Firefox, foot, Kate; excluded), warms up 300 s, samples
#       600 s every 5 s and appends the run to that state's series.
#       desktop_full_plus10 samples A, enables the ten D-34 plugins with one
#       ChangeSet, warms up 300 s again, samples B, and removes them.
#   cold-login.sh report <state>
#       The report from the last three runs of that state, each from its own
#       login. desktop_full_plus10 gives the B report and the A/B report.
#   cold-login.sh reset
#       Remove measure-conditions.json: the next login is a normal one.
#   cold-login.sh login-id | ready <state> | count <state>
#       For series.sh: the current login, whether it can be sampled, and how
#       many runs from distinct logins the state's series holds.
#
# States: rescue_no_node, desktop_full_no_agent, desktop_full_plus10,
# desktop_full_no_avatar, and G2's desktop_full_agent_warm (the Agent and its
# Codex backend started, no turn) and desktop_full_agent_active (model turns
# running back to back; needs the subscription signed in). An Agent state
# keeps the Agent from its normal five-minute release with a
# measurement-only hold: `agent.runtime.ensure` every 60 s through the relay,
# the same call the chat makes when it opens. Production has no such hold.
#
# DITTO_FORMAT_CHECK=1 runs the same flow on a development machine: no
# reference-machine preflight, separate series, reports that say they are not
# EX1-10 evidence, and only then may DITTO_WARMUP_SECONDS,
# DITTO_SAMPLE_SECONDS, DITTO_SAMPLE_INTERVAL_MS or DITTO_MAX_LOGIN_AGE_SECONDS
# be loosened (principle 5). DITTO_MEASURE_FIXTURE=1 (format check only)
# points the script at the headless fixture of dry-run.sh instead of a login.
#
# Layers are attributed by cgroup: every active `ditto-*` scope or service is
# classified (Wayfire, Fcitx, Core, the supervisor, and the Shell, hostd, lock
# client and rescue interface Core launched); one that cannot be classified
# stops the run rather than being left out. The verification relay (a Node
# program, only in --verification-relay installs) is sampled as its own layer
# and kept out of the desktop total.
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../../.." && pwd)"
artifacts="${DITTO_ARTIFACTS:-$workspace/artifacts/g1}"
binaries="${DITTO_BINARIES:-$workspace/target/release}"
format_check="${DITTO_FORMAT_CHECK:-}"
fixture="${DITTO_MEASURE_FIXTURE:-}"
conditions_file="${DITTO_MEASURE_CONDITIONS:-${XDG_STATE_HOME:-$HOME/.local/state}/ditto/measure-conditions.json}"
warmup="${DITTO_WARMUP_SECONDS:-300}"
duration="${DITTO_SAMPLE_SECONDS:-600}"
interval_ms="${DITTO_SAMPLE_INTERVAL_MS:-5000}"
max_login_age="${DITTO_MAX_LOGIN_AGE_SECONDS:-600}"
apps="${DITTO_MEASURE_APPS:-browser terminal editor}"
prefix=ditto

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DITTO_G1_RELAY="${DITTO_G1_RELAY:-$XDG_RUNTIME_DIR/ditto/verify-relay.sock}"

if [[ -z "$format_check" ]]; then
  # The procedure's conditions are not adjustable on the reference machine.
  if (( warmup < 300 || duration < 600 || interval_ms > 5000 || max_login_age > 600 )) || [[ "$apps" != 'browser terminal editor' ]]; then
    echo 'warm-up 300 s, sampling 600 s every <=5 s, logins <=600 s old and all three reference applications are fixed;' >&2
    echo 'shorter runs are only for DITTO_FORMAT_CHECK=1' >&2
    exit 2
  fi
  [[ -z "$fixture" ]] || { echo 'DITTO_MEASURE_FIXTURE needs DITTO_FORMAT_CHECK=1' >&2; exit 2; }
fi
if [[ -n "$fixture" ]]; then
  prefix="${DITTO_MEASURE_UNIT_PREFIX:?the fixture names its unit prefix}"
fi
fc="${format_check:+-format-check}"
series_file() { echo "$artifacts/cold-login-series$fc-$1.jsonl"; }
ledger="$artifacts/cold-login-logins$fc.txt"

valid_state() {
  case "$1" in rescue_no_node|desktop_full_no_agent|desktop_full_plus10|desktop_full_no_avatar|desktop_full_agent_warm|desktop_full_agent_active) return 0 ;; esac
  echo "unknown state '$1'; expected rescue_no_node, desktop_full_no_agent, desktop_full_plus10, desktop_full_no_avatar, desktop_full_agent_warm or desktop_full_agent_active" >&2
  return 2
}

variant_of() {
  case "$1" in
    rescue_no_node) echo rescue-no-node ;;
    desktop_full_no_avatar) echo avatar-off ;;
    *) echo standard ;;
  esac
}

relay_call() {
  python3 "$workspace/tests/g1/lib/gui.py" relay "$1" "${2:-{\}}"
}

relay_up() {
  [[ -S "$DITTO_G1_RELAY" ]] && relay_call desktop.capabilities.list '{}' 2>/dev/null | grep -q '"result"'
}

# The D-34 set: "<package> <version> <host> <place>" per line, five QML,
# five Cordis. <place> is where the entry goes: the QML ones join the
# `ui.status_item` area their manifest declares (several entries side by
# side), the Cordis ones fill no slot ("-").
d34_packages() {
  local manifest
  for manifest in "$workspace"/packages/plugin-fixtures/qml/*/manifest.json "$workspace"/packages/plugin-fixtures/cordis/*/manifest.json; do
    jq -r '"\(.id) \(.version) \(.host_kind) \(if .host_kind == "qml" then (.slots[0] // "-") else "-" end)"' "$manifest"
  done
}

# Entry ids of the D-34 set in the active Profile, one per line.
d34_entries() {
  local ids
  ids="$(d34_packages | awk '{print $1}' | jq -Rsc 'split("\n") | map(select(length > 0))')"
  relay_call desktop.profiles.get '{}' |
    jq -r --argjson ids "$ids" '.result.document.entries[] | select(.package as $p | $ids | index($p)) | .entry_id'
}

# Remove the D-34 entries with one ChangeSet. Prints the change's state.
d34_remove() {
  local entries head
  mapfile -t entries < <(d34_entries)
  (( ${#entries[@]} )) || { echo none; return 0; }
  head="$(relay_call desktop.profiles.get '{}' | jq -r .result.profile.head_revision)"
  relay_call desktop.changes.propose "$(jq -cn --arg base "$head" '{base_revision: $base, ops: ($ARGS.positional | map({op: "remove_entry", entry_id: .}))}' --args "${entries[@]}")" |
    jq -r '.result.state // ("error: " + (.error.name // "unknown"))'
}

# ---- the login ------------------------------------------------------------

layer_of() {
  local unit="$1"
  case "${unit#"$prefix"-}" in
    wayfire.scope) echo compositor ;;
    core.service|core.scope) echo core ;;
    quickshell.scope|shell.scope) echo shell ;;
    hostd.scope) echo hostd ;;
    supervisor.service|supervisor.scope) echo supervisor ;;
    lock.scope) echo lock ;;
    fcitx.scope) echo input-method ;;
    rescue-shell.scope|rescue.service) echo rescue-ui ;;
    dittoctl.scope) echo verification-relay ;;
    agent.scope|agent-backend.scope) echo agent ;;
    job-*.scope) echo worker ;;
    ref-*.scope) echo excluded ;;
    *) echo unknown ;;
  esac
}

unit_cgroup_dir() {
  local group
  group="$(systemctl --user show -p ControlGroup --value "$1" 2>/dev/null || true)"
  [[ -n "$group" && -d "/sys/fs/cgroup$group" ]] && echo "/sys/fs/cgroup$group"
}

# Every PID in a unit's cgroup tree.
unit_pids() {
  local directory
  directory="$(unit_cgroup_dir "$1")" || return 0
  find "$directory" -name cgroup.procs -exec cat {} + 2>/dev/null | sort -n
}

unit_main_pid() {
  local pid
  pid="$(systemctl --user show -p MainPID --value "$1" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then echo "$pid"; else unit_pids "$1" | head -1; fi
}

# Active Ditto units as "<unit> <layer>" lines.
ditto_units() {
  local unit
  systemctl --user list-units --plain --no-legend --state=active --type=scope,service "$prefix-*" 2>/dev/null |
    awk '{print $1}' | sort | while read -r unit; do
      [[ -n "$unit" ]] && echo "$unit $(layer_of "$unit")"
    done
}

# The login this desktop belongs to: "<boot id>:<logind session>" (session
# numbers repeat after a reboot), or the fixture's own id.
login_id() {
  if [[ -n "$fixture" ]]; then
    echo "${DITTO_MEASURE_LOGIN_ID:?}"
    return
  fi
  local pid session
  pid="$(unit_main_pid "$prefix-wayfire.scope")"
  [[ -n "$pid" ]] || return 1
  session="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^XDG_SESSION_ID=//p')"
  [[ -n "$session" ]] || return 1
  echo "$(cat /proc/sys/kernel/random/boot_id):$session"
}

login_age() {
  if [[ -n "$fixture" ]]; then
    echo $(( $(date +%s) - ${DITTO_MEASURE_LOGIN_EPOCH:?} ))
    return
  fi
  local session login_usec now_usec
  session="${1##*:}"
  login_usec="$(loginctl show-session "$session" -p TimestampMonotonic --value)"
  now_usec="$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)"
  echo $(( (now_usec - login_usec) / 1000000 ))
}

# Layers a state cannot be measured without. Fcitx is part of every login;
# the headless fixture has none.
required_layers() {
  local layers=(compositor core supervisor)
  [[ -n "$fixture" ]] || layers+=(input-method)
  if [[ "$1" == rescue_no_node ]]; then layers+=(shell-or-rescue-ui); else layers+=(shell hostd verification-relay); fi
  # `ready` is asked before the Agent is started; sample requires it after.
  [[ "$1" == desktop_full_agent_* && -n "${agent_started:-}" ]] && layers+=(agent)
  echo "${layers[*]}"
}

# Node processes in Ditto's units, "<unit> <pid> <exe>" per line. Core's
# launched clients are in units of their own, and anything Core started
# without one is in Core's.
node_processes() {
  local unit layer pid exe
  while read -r unit layer; do
    [[ "$layer" == excluded ]] && continue
    for pid in $(unit_pids "$unit"); do
      exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
      [[ "${exe##*/}" == node* ]] && echo "$unit $pid $exe"
    done
  done < <(ditto_units)
  return 0
}

# Is the session ready to be sampled in this state? Prints why not.
session_ready() {
  local state="$1" units layer missing=()
  units="$(ditto_units)"
  [[ -n "$units" ]] || { echo 'no Ditto units are running'; return 1; }
  if grep -q ' unknown$' <<<"$units"; then
    echo "unclassified Ditto units: $(awk '$2 == "unknown" {print $1}' <<<"$units" | xargs)"
    return 1
  fi
  for layer in $(required_layers "$state"); do
    if [[ "$layer" == shell-or-rescue-ui ]]; then
      grep -qE ' (shell|rescue-ui)$' <<<"$units" || missing+=("shell or rescue-ui")
    else
      grep -q " $layer\$" <<<"$units" || missing+=("$layer")
    fi
  done
  (( ${#missing[@]} == 0 )) || { echo "missing layers: ${missing[*]}"; return 1; }
  # Outside the Agent states the Agent must not be running at all.
  if [[ "$state" != desktop_full_agent_* ]] && grep -qE ' (agent|worker)$' <<<"$units"; then
    echo "an Agent or worker is running: $(awk '$2 == "agent" || $2 == "worker" {print $1}' <<<"$units" | xargs)"
    return 1
  fi
  if [[ "$state" != rescue_no_node ]]; then
    relay_up || { echo "the verification relay does not answer at $DITTO_G1_RELAY"; return 1; }
    [[ "$(relay_call desktop.plugins.diagnostics '{}' | jq -r '.result.host.state // empty')" == running ]] ||
      { echo 'hostd is not running yet'; return 1; }
  fi
  return 0
}

# ---- prepare / reset ----------------------------------------------------------

prepare() {
  valid_state "$1"
  local state="$1" variant
  variant="$(variant_of "$state")"
  if [[ -z "$fixture" ]]; then
    # The installed units must be the ones that know the rescue variant and
    # the D-34 built-ins; an older install would start Node in rescue mode.
    grep -q 'DITTO_CORE_MODE_ARGS' /etc/systemd/user/ditto-core.service 2>/dev/null ||
      { echo 'the installed ditto-core.service predates the measurement variants; rerun install-session.sh --verification-relay' >&2; exit 1; }
    local dropin=/etc/systemd/user/ditto-core.service.d/verification-relay.conf
    if [[ "$state" == rescue_no_node ]]; then
      if [[ -f "$dropin" ]] && ! grep -q 'DITTO_VERIFY_RELAY_OPTION' "$dropin"; then
        echo "$dropin starts the relay unconditionally (Node in rescue mode); rerun install-session.sh --verification-relay" >&2
        exit 1
      fi
    else
      grep -q 'DITTO_VERIFY_RELAY_OPTION' "$dropin" 2>/dev/null ||
        { echo "$state reads hostd and enables plugins through the verification relay; install with install-session.sh --verification-relay" >&2; exit 1; }
    fi
  fi
  # A run must start without the D-34 plugins in the Profile. They are removed
  # here, in the login that is about to end, never in the measured one.
  if relay_up; then
    local removed
    removed="$(d34_remove)"
    [[ "$removed" == none || "$removed" == committed ]] ||
      { echo "could not remove the D-34 plugins from the Profile: $removed" >&2; exit 1; }
    [[ "$removed" == committed ]] && echo 'removed the D-34 plugins from the Profile (left over from an earlier run)'
  else
    echo 'note: no verification relay now; sample checks the Profile for D-34 plugins and refuses if any are there' >&2
  fi
  mkdir -p "$(dirname "$conditions_file")"
  jq -n --arg variant "$variant" --arg state "$state" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{desktop_variant: $variant, measurement_state: $state, prepared_at: $at}' >"$conditions_file"
  echo "the next Ditto login starts in state '$state' (desktop_variant $variant); log out and log in from the login screen"
}

reset_conditions() {
  rm -f -- "$conditions_file"
  echo 'measure-conditions.json removed: the next login is a normal one'
}

# ---- sample ---------------------------------------------------------------

app_units=()
stop_apps() {
  (( ${#app_units[@]} )) && systemctl --user stop "${app_units[@]}" >/dev/null 2>&1 || true
}

start_app() {
  local role="$1" unit app_id
  case "$role" in
    browser) unit="$prefix-ref-browser" app_id=firefox_firefox ;;
    terminal) unit="$prefix-ref-terminal" app_id=ditto-ref-terminal ;;
    editor) unit="$prefix-ref-editor" app_id=org.kde.kate ;;
    *) echo "unknown reference application $role" >&2; return 2 ;;
  esac
  app_units+=("$unit.scope")
  systemctl --user stop "$unit.scope" >/dev/null 2>&1 || true
  case "$role" in
    browser)
      local firefox_profile="$HOME/snap/firefox/common/ditto-g0-reference-profile"
      mkdir -p "$firefox_profile"
      # The fixed starting state of the other reference fixtures.
      rm -f -- "$firefox_profile/xulstore.json"
      systemd-run --user --scope --quiet --collect --unit="$unit" -- env MOZ_ENABLE_WAYLAND=1 MOZ_DISABLE_WAYLAND_PROXY=1 \
        firefox --no-remote --profile "$firefox_profile" about:blank >/dev/null 2>&1 &
      ;;
    terminal)
      systemd-run --user --scope --quiet --collect --unit="$unit" -- foot --app-id=ditto-ref-terminal sh -c 'sleep infinity' >/dev/null 2>&1 &
      ;;
    editor)
      systemd-run --user --scope --quiet --collect --unit="$unit" -- env QT_QPA_PLATFORM=wayland QT_IM_MODULE=fcitx QT_IM_MODULES=fcitx \
        kate --new >/dev/null 2>&1 &
      ;;
  esac
  compositor_wait_for_window "$app_id" || { echo "$app_id did not map in the login session" >&2; return 1; }
  if [[ "$role" == editor ]]; then
    local kate
    kate="$(qdbus | awk '/org\.kde\.kate-[0-9]+/{print $1; exit}')"
    [[ -n "$kate" && "$(qdbus "$kate" /MainApplication org.kde.Kate.Application.openInput \
      'Ditto G1 cold-login fixture: unsaved buffer' UTF-8)" == true ]] ||
      { echo 'could not open the fixed Kate content' >&2; return 1; }
  fi
  compositor_focus_window "$app_id"
}

fingerprint_node() {
  local hostd pid
  hostd="$(awk -v u="$prefix-hostd.scope" '$1 == u' <<<"$1")"
  if [[ -n "$hostd" ]]; then
    pid="$(unit_main_pid "$prefix-hostd.scope")"
    "$(readlink "/proc/$pid/exe")" --version
  else
    node --version
  fi
}

# write_manifest <path> <run_id> <manifest state> <login> <units> <with heap>
write_manifest() {
  local path="$1" run_id="$2" state="$3" login="$4" units="$5" heap="$6" node_version
  node_version="$(fingerprint_node "$units")"
  python3 - "$path" "$run_id" "$state" "$login" "$workspace" "$units" "$heap" "$DITTO_G1_RELAY" "$node_version" "$prefix" <<'PYEOF'
import json, subprocess, sys

destination, run_id, state, login, workspace, units, heap, relay, node, prefix = sys.argv[1:11]

def value(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout.strip()
    except OSError:
        return ""

included, excluded = [], []
for line in units.splitlines():
    unit, layer = line.split()
    if layer == "excluded":
        excluded.append({"unit": unit, "reason": "reference application the user opened (plan/03/06 §7.4)"})
    else:
        included.append({"name": unit, "layer": layer, "scope": "user"})
excluded.sort(key=lambda item: item["unit"])
# The same names in every run: the report compares exclusion lists. The login
# itself is recorded per run.
excluded += [
    {"unit": "session-<login>.scope", "reason": "display manager login plumbing (gdm-session-worker, gdm-wayland-session, the session entry script)"},
    {"unit": "user and system units not named " + prefix + "-*", "reason": "existing OS services (D-Bus, portals, PipeWire, GDM); none of them is started by Ditto (plan/03/06 §7.4)"},
]
manifest = {
    "run_id": run_id,
    "state": state,
    "login_id": login,
    "fingerprint": {
        "kernel": value(["uname", "-r"]),
        "compositor": value(["wayfire", "--version"]),
        "qt": value(["qmake6", "-query", "QT_VERSION"]),
        "quickshell": value(["quickshell", "--version"]),
        "rust": value(["rustc", "--version"]),
        "node": node,
        "ditto_commit": value(["git", "-C", workspace, "rev-parse", "HEAD"]),
        "ditto_uncommitted_paths": str(len(value(["git", "-C", workspace, "status", "--porcelain"]).splitlines())),
    },
    "units": included,
    "excluded": excluded,
}
if heap == "1":
    hostd = [unit["name"] for unit in included if unit["layer"] == "hostd"]
    manifest["node_memory"] = {"unit": hostd[0], "relay_socket": relay}
json.dump(manifest, open(destination, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF
}

# measure <manifest state> <run_id> <login> -> sets MEASURED_SAMPLES/MEASURED_MANIFEST
measure() {
  local state="$1" run_id="$2" login="$3" units heap=1 unit
  units="$(ditto_units)"
  [[ "$state" == rescue_no_node ]] && heap=0
  MEASURED_MANIFEST="$artifacts/measure-manifest-$run_id.json"
  MEASURED_SAMPLES="$artifacts/measure-$run_id.jsonl"
  write_manifest "$MEASURED_MANIFEST" "$run_id" "$state" "$login" "$units" "$heap"
  local -A main_before=()
  while read -r unit _; do main_before[$unit]="$(unit_main_pid "$unit")"; done <<<"$units"
  local count=$(( duration * 1000 / interval_ms + 1 ))
  echo "$state: sampling $count points every ${interval_ms} ms"
  "$binaries/ditto-measure" sample "$MEASURED_MANIFEST" "$count" "$interval_ms" "$MEASURED_SAMPLES"
  # The desktop that was sampled must be the one that was described: no Ditto
  # unit appeared or left, and no main process was replaced.
  local after
  after="$(ditto_units)"
  [[ "$after" == "$units" ]] || {
    echo "the Ditto units changed while sampling; the run is not recorded" >&2
    diff <(echo "$units") <(echo "$after") >&2 || true
    exit 1
  }
  while read -r unit _; do
    [[ "$(unit_main_pid "$unit")" == "${main_before[$unit]}" ]] ||
      { echo "$unit restarted while sampling; the run is not recorded" >&2; exit 1; }
  done <<<"$units"
}

# ---- the Agent states ---------------------------------------------------------

hold_pid=""
load_pid=""
agent_turns_file=""
# Start the Agent and its confined backend the way the chat does, and wait
# until Core reports it ready and isolated. Prints the runtime status.
agent_up() {
  local status deadline=$(( $(date +%s) + 90 ))
  relay_call agent.runtime.ensure '{}' >/dev/null
  while :; do
    status="$(relay_call agent.runtime.get '{}')"
    [[ "$(jq -r .result.phase <<<"$status")" == ready ]] && break
    [[ "$(jq -r .result.phase <<<"$status")" == failed ]] && { echo "the Agent failed to start: $(jq -c .result <<<"$status")" >&2; return 1; }
    (( $(date +%s) < deadline )) || { echo 'the Agent did not become ready in 90 s' >&2; return 1; }
    sleep 1
  done
  [[ "$(jq -r .result.isolation_verified <<<"$status")" == true ]] ||
    { echo 'the Agent backend is not confined; Agent states are measured only with the real boundary' >&2; return 1; }
  jq -c .result <<<"$status"
}
# measurement-only hold: what opening the chat does, once a minute.
agent_hold() {
  ( while sleep 60; do relay_call agent.runtime.ensure '{}' >/dev/null 2>&1 || true; done ) &
  hold_pid=$!
}
# Model turns back to back in one conversation, without tools, until killed.
agent_load() {
  agent_turns_file="$artifacts/agent-active-turns-$1.jsonl"
  local session
  session="$(relay_call agent.sessions.create "{\"title\":\"measurement $1\",\"idempotency_key\":\"measure-$1\"}" | jq -r .result.session_id)"
  [[ -n "$session" && "$session" != null ]] || { echo 'could not create the measurement conversation' >&2; return 1; }
  (
    local n=0 turn state
    while :; do
      n=$(( n + 1 ))
      turn="$(relay_call agent.turns.submit "$(jq -cn --arg s "$session" --arg k "measure-$1-$n" \
        '{session_id: $s, client_message_id: $k, text: "請用大約三百字介紹在 Ditto 桌面上可以怎麼調整外觀與布局。不要呼叫任何工具，也不要修改任何設定。", contexts: []}')" | jq -r .result.turn_id)"
      while :; do
        state="$(relay_call agent.turns.get "{\"turn_id\":\"$turn\"}" | jq -r .result.state)"
        case "$state" in succeeded|failed|cancelled|unknown|partial) break ;; esac
        sleep 1
      done
      jq -cn --arg turn "$turn" --arg state "$state" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{turn_id: $turn, state: $state, ended_at: $at}' >>"$agent_turns_file"
    done
  ) &
  load_pid=$!
}

plus10_enabled=""
cleanup_sample() {
  [[ -n "$hold_pid" ]] && kill "$hold_pid" 2>/dev/null
  [[ -n "$load_pid" ]] && kill "$load_pid" 2>/dev/null
  stop_apps
  if [[ -n "$plus10_enabled" ]]; then
    echo "removing the D-34 plugins: $(d34_remove 2>/dev/null || echo failed)" >&2
  fi
}

sample() {
  valid_state "$1"
  local state="$1"
  if [[ -n "$format_check" ]]; then
    echo 'format check: reference-machine preflight skipped; this run is not EX1-10 evidence' >&2
  else
    bash "$workspace/packaging/reference-image/preflight.sh"
  fi
  local prepared
  prepared="$(jq -r '.measurement_state // empty' "$conditions_file" 2>/dev/null || true)"
  [[ "$prepared" == "$state" ]] || {
    echo "this login was prepared for '${prepared:-nothing}', not '$state'; run prepare $state and log in again" >&2
    exit 1
  }
  local why agent_status=""
  if [[ "$state" == desktop_full_agent_* ]]; then
    relay_up || { echo "the verification relay does not answer at $DITTO_G1_RELAY" >&2; exit 1; }
    if [[ "$state" == desktop_full_agent_active ]]; then
      [[ "$(relay_call agent.providers.status '{"provider":"codex-app-server"}' | jq -r .result.authenticated)" == true ]] || {
        echo 'desktop_full_agent_active runs real model turns: sign in to the subscription first (AI 設定)' >&2
        exit 2
      }
    fi
    agent_status="$(agent_up)" || exit 1
    agent_started=1
  fi
  why="$(session_ready "$state")" || { echo "not a session in state $state: $why" >&2; exit 1; }

  local login age
  login="$(login_id)" || { echo 'could not read the login session of the compositor' >&2; exit 1; }
  age="$(login_age "$login")"
  if (( age > max_login_age )); then
    echo "login $login started ${age}s ago; a cold-login run must start within ${max_login_age}s of logging in" >&2
    exit 1
  fi
  mkdir -p "$artifacts"
  if [[ -f "$ledger" ]] && grep -q "^$login " "$ledger"; then
    echo "login $login was already used for a run ($(grep "^$login " "$ledger" | head -1)); each run needs its own login" >&2
    exit 1
  fi

  # The session must really be in the state, not just have been asked to be.
  local core_pid shell_unit shell_env node_list
  core_pid="$(unit_main_pid "$(ditto_units | awk '$2 == "core" {print $1; exit}')")"
  if tr '\0' ' ' <"/proc/$core_pid/cmdline" | grep -q -- '--mode rescue'; then core_mode=rescue; else core_mode=normal; fi
  if [[ "$state" == rescue_no_node ]]; then
    [[ "$core_mode" == rescue ]] || { echo 'Core is not in rescue mode; check the installed units and measure-conditions.json' >&2; exit 1; }
  else
    [[ "$core_mode" == normal ]] || { echo "Core is in rescue mode, not $state" >&2; exit 1; }
  fi
  node_list="$(node_processes)"
  if [[ "$state" == rescue_no_node && -n "$node_list" ]]; then
    echo "rescue_no_node, but Ditto runs Node processes:" >&2
    echo "$node_list" >&2
    exit 1
  fi
  shell_unit="$(ditto_units | awk '$2 == "shell" {print $1; exit}')"
  if [[ "$state" != rescue_no_node ]]; then
    shell_env="$(tr '\0' '\n' <"/proc/$(unit_main_pid "$shell_unit")/environ")"
    case "$state" in
      desktop_full_no_avatar) grep -qx 'DITTO_AVATAR=off' <<<"$shell_env" ;;
      *) ! grep -qE '^DITTO_AVATAR=off$' <<<"$shell_env" ;;
    esac || { echo "the running Shell is not in state $state (DITTO_AVATAR); log in again after prepare" >&2; exit 1; }
    grep -qx 'DITTO_REDUCED_MOTION=1' <<<"$shell_env" && { echo 'the Shell runs with reduced motion, which no G1 state uses' >&2; exit 1; }
    local leftovers
    leftovers="$(d34_entries)"
    [[ -z "$leftovers" ]] || { echo "the Profile still holds D-34 plugins ($(echo "$leftovers" | xargs)); run prepare and log in again" >&2; exit 1; }
    if [[ "$state" == desktop_full_plus10 ]]; then
      local package missing=()
      while read -r package _; do
        relay_call desktop.plugins.get "{\"package_id\":\"$package\"}" | grep -q '"result"' || missing+=("$package")
      done < <(d34_packages)
      (( ${#missing[@]} == 0 )) || { echo "not built-ins of this session: ${missing[*]} (install with --verification-relay)" >&2; exit 1; }
    fi
  fi

  local run_id
  run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$workspace" rev-parse --short=4 HEAD)-$state"
  # The login is spent from here on, whatever happens to the run.
  echo "$login $state $run_id" >>"$ledger"

  # The measured desktop is the login session's own compositor.
  if [[ -z "$fixture" ]]; then
    local wayfire_pid
    wayfire_pid="$(unit_main_pid "$prefix-wayfire.scope")"
    WAYLAND_DISPLAY="$(tr '\0' '\n' <"/proc/$wayfire_pid/environ" | sed -n 's/^WAYLAND_DISPLAY=//p')"
    [[ -n "$WAYLAND_DISPLAY" ]] || WAYLAND_DISPLAY="$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p')"
    export WAYLAND_DISPLAY WAYFIRE_SOCKET="$XDG_RUNTIME_DIR/ditto-wayfire-ipc.sock"
  fi
  export DITTO_COMPOSITOR=wayfire
  unset DISPLAY
  # shellcheck source=../../../tools/compositor-probe/functional/compositor.sh
  source "$workspace/tools/compositor-probe/functional/compositor.sh"

  trap cleanup_sample EXIT INT TERM
  local role
  for role in $apps; do start_app "$role"; done

  if [[ "$state" == desktop_full_agent_* ]]; then
    agent_hold
    [[ "$state" == desktop_full_agent_active ]] && agent_load "$run_id"
  fi
  echo "login $login (${age}s old), state $state: warming up for ${warmup}s"
  sleep "$warmup"
  local record
  if [[ "$state" != desktop_full_plus10 ]]; then
    measure "$state" "$run_id" "$login"
    record="$(jq -cn --arg samples "$MEASURED_SAMPLES" --arg manifest "$MEASURED_MANIFEST" '{samples: $samples, manifest: $manifest}')"
  else
    measure desktop_full_plus10_a "$run_id-a" "$login"
    local samples_a="$MEASURED_SAMPLES" manifest_a="$MEASURED_MANIFEST"
    # One ChangeSet enables the ten (plan/03/06 §7.3).
    local mounted_before head ops change state_after evidence="$artifacts/plus10-enable-$run_id.json"
    mounted_before="$(relay_call desktop.plugins.diagnostics '{}' | jq -r '.result.core.shell_mounted_providers')"
    head="$(relay_call desktop.profiles.get '{}' | jq -r .result.profile.head_revision)"
    ops="$(d34_packages | jq -Rsc 'split("\n") | map(select(length > 0) | split(" ")
      | {op: "add_entry", entry: {package: .[0], version: .[1], host: .[2]}} + (if .[3] != "-" then {slot: .[3]} else {} end))')"
    plus10_enabled=1
    change="$(relay_call desktop.changes.propose "$(jq -cn --arg base "$head" --argjson ops "$ops" '{base_revision: $base, ops: $ops}')")"
    state_after="$(jq -r '.result.state // ("error: " + (.error.name // "unknown"))' <<<"$change")"
    [[ "$state_after" == committed ]] || { echo "enabling the D-34 set ended $state_after; the run is not recorded" >&2; echo "$change" >"$evidence"; exit 1; }
    # Read back what really loaded: Cordis fibers active, and each QML status
    # item mounted and visible in the `ui.status_item` area as the Shell
    # reported it (desktop.panels.list lists one row per member).
    local cordis_ids qml_ids cordis_active=0 qml_mounted=0 diagnostics panels deadline=$(( $(date +%s) + 60 ))
    cordis_ids="$(d34_packages | awk '$3 == "cordis" {print $1}' | jq -Rsc 'split("\n") | map(select(length > 0))')"
    qml_ids="$(d34_packages | awk '$3 == "qml" {print $1}' | jq -Rsc 'split("\n") | map(select(length > 0))')"
    while :; do
      diagnostics="$(relay_call desktop.plugins.diagnostics '{}')"
      panels="$(relay_call desktop.panels.list '{}')"
      cordis_active="$(jq --argjson ids "$cordis_ids" '[.result.entries[] | select((.package as $p | $ids | index($p)) and .fiber_state == "active")] | length' <<<"$diagnostics")"
      qml_mounted="$(jq --argjson ids "$qml_ids" '[.result.panels[] | select(.slot == "ui.status_item" and (.package as $p | $ids | index($p))
        and .mounted and .visible and .mounted_entry == .bound_entry)] | length' <<<"$panels")"
      (( cordis_active == 5 && qml_mounted == 5 )) && break
      (( $(date +%s) < deadline )) || break
      sleep 1
    done
    jq -n --argjson change "$change" --argjson diagnostics "$diagnostics" --argjson panels "$panels" --argjson before "$mounted_before" \
      '{change: $change, shell_mounted_before: $before, diagnostics_after: $diagnostics, panels_after: $panels}' >"$evidence"
    local note=""
    (( qml_mounted == 5 )) || note="the Shell shows $qml_mounted of the five QML status items (desktop.panels.list, ui.status_item)"
    (( cordis_active == 5 )) || note="${note:+$note; }$cordis_active of the five Cordis plugins are active"
    echo "D-34 set enabled ($(jq -r .result.change_id <<<"$change")): Cordis active $cordis_active/5, QML mounted $qml_mounted/5${note:+; $note}"
    echo "warming up for ${warmup}s after enabling"
    sleep "$warmup"
    measure desktop_full_plus10_b "$run_id-b" "$login"
    local removed
    removed="$(d34_remove)"
    plus10_enabled=""
    [[ "$removed" == committed ]] || echo "warning: removing the D-34 set ended $removed; prepare removes it before the next run" >&2
    record="$(jq -cn --arg a "$samples_a" --arg ma "$manifest_a" --arg b "$MEASURED_SAMPLES" --arg mb "$MEASURED_MANIFEST" \
      --argjson cordis "$cordis_active" --argjson qml "$qml_mounted" --arg note "$note" --arg evidence "$evidence" \
      '{samples_a: $a, manifest_a: $ma, samples_b: $b, manifest_b: $mb, warmup_b_seconds: '"$warmup"',
        plus10_loaded: {cordis_active: $cordis, qml_mounted: $qml, note: $note}, enable_evidence: $evidence}')"
  fi

  local series
  series="$(series_file "$state")"
  jq -cn --arg run "$run_id" --arg login "$login" --argjson age "$age" --argjson warmup "$warmup" \
    --arg state "$state" --arg mode "$core_mode" --arg nodes "$node_list" --argjson record "$record" \
    --arg units "$(ditto_units)" --arg agent "$agent_status" --arg turns "$agent_turns_file" --argjson duration "$duration" --argjson interval "$interval_ms" --arg apps "$apps" \
    '{run_id: $run, login_id: $login, login_age_seconds: $age, warmup_seconds: $warmup, sample_seconds: $duration,
      interval_ms: $interval, state: $state, core_mode: $mode, reference_apps: ($apps | split(" ")),
      node_processes: ($nodes | split("\n") | map(select(length > 0))),
      agent: (if ($agent | length) > 0 then {runtime: ($agent | fromjson), hold: "measurement-only: agent.runtime.ensure every 60 s", turns_log: $turns} else null end),
      ditto_units: ($units | split("\n") | map(select(length > 0)))} + $record' >>"$series"
  echo "run $run_id recorded in $series ($(wc -l <"$series") so far)"
}

# ---- report ---------------------------------------------------------------

report() {
  valid_state "$1"
  local state="$1" series runs
  series="$(series_file "$state")"
  [[ -f "$series" ]] || { echo "no runs recorded for state '$state'" >&2; exit 1; }
  runs="$(jq -sc 'unique_by(.login_id) | sort_by(.run_id) | .[-3:]' "$series")"
  (( $(jq length <<<"$runs") == 3 )) || { echo "state '$state' has $(jq length <<<"$runs") runs from distinct logins; three are required" >&2; exit 1; }
  local conditions="$artifacts/cold-login-conditions$fc-$state.json"
  local machine=ditto-ref-ws-rtx4060-01 physical=true
  [[ -n "$format_check" ]] && machine="development-$(hostname)" && physical=false
  jq -n --arg state "$state" --arg machine "$machine" --argjson physical "$physical" --argjson runs "$runs" \
    --argjson max_age "$max_login_age" '{
    reference_machine_id: $machine,
    physical_reference_machine: $physical,
    cold_login_each_run: true,
    # The shortest warm-up actually used (including B after enabling), not the
    # nominal one.
    warmup_seconds: ($runs | map(.warmup_seconds, (.warmup_b_seconds // .warmup_seconds)) | min),
    fixed_variables: ([
      "one display-manager login through Ditto (Wayfire) per run; logins \($runs | map(.login_id) | join(", "))",
      "seconds from login to the start of the run: \($runs | map(.login_age_seconds | tostring) | join(", ")) (at most \($max_age))",
      "sampling \($runs | map(.sample_seconds | tostring) | unique | join("/")) s every \($runs | map(.interval_ms | tostring) | unique | join("/")) ms after the warm-up",
      "measurement state \($state); Core mode \($runs | map(.core_mode) | unique | join("/"))",
      "Ditto G1 Core, Shell, hostd, ditto-supervisor, Wayfire and Fcitx from packaging/reference-image (install-session.sh --verification-relay), the frozen character asset, 1920x1080 60 Hz scale 1",
      "reference applications \($runs | map(.reference_apps | join("+")) | unique | join(" / ")) (browser = Firefox, terminal = foot, editor = Kate) with the G0 fixture content, started after login in ditto-ref-*.scope and excluded",
      (if ($state | startswith("desktop_full_agent")) then "the Agent controller and its Codex app-server in ditto-confine, started with agent.runtime.ensure after login and kept with the measurement-only hold (agent.runtime.ensure every 60 s)" + (if $state == "desktop_full_agent_active" then "; model turns back to back without tools, logged per run" else "; no turn" end) else "no Agent and no Agent stand-in" end),
      "Node processes in Ditto units at the start of each run: \($runs | map((.node_processes | length) | tostring) | join(", "))"
    ] + (if $state == "desktop_full_plus10" then [
      "A/B in each login: A without the D-34 set, then one ChangeSet enabling its ten packages, a warm-up of \($runs | map(.warmup_b_seconds | tostring) | join(", ")) s, then B; the set is removed afterwards"
    ] else [] end)),
    plus10_loaded: ($runs | map(select(.plus10_loaded) | .plus10_loaded + {login_id}))
  }' >"$conditions"
  local stamp out
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$state" == desktop_full_plus10 ]]; then
    mapfile -t pair < <(jq -r '.[] | .samples_a, .samples_b' <<<"$runs")
    out="$artifacts/resource-report-cold-login$fc-$state-b-$stamp.md"
    "$binaries/ditto-measure" report "$conditions" "${pair[1]}" "${pair[3]}" "${pair[5]}" "$out"
    echo "B report -> $out"
    out="$artifacts/resource-report-cold-login$fc-$state-ab-$stamp.md"
    "$binaries/ditto-measure" report-ab "$conditions" "${pair[@]}" "$out"
    echo "A/B report -> $out"
  else
    mapfile -t samples < <(jq -r '.[].samples' <<<"$runs")
    out="$artifacts/resource-report-cold-login$fc-$state-$stamp.md"
    "$binaries/ditto-measure" report "$conditions" "${samples[@]}" "$out"
    echo "report -> $out"
  fi
}

case "${1:-}" in
  prepare) prepare "${2:?state}" ;;
  sample) sample "${2:?state}" ;;
  report) report "${2:?state}" ;;
  reset) reset_conditions ;;
  login-id) login_id ;;
  count)
    valid_state "${2:?state}"
    if [[ -f "$(series_file "$2")" ]]; then jq -s 'map(.login_id) | unique | length' "$(series_file "$2")"; else echo 0; fi
    ;;
  ready)
    valid_state "${2:?state}"
    why="$(session_ready "$2")" || { echo "$why"; exit 1; }
    ;;
  *) sed -n '2,36p' "$0" >&2; exit 2 ;;
esac
