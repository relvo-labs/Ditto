#!/usr/bin/env bash
# The unattended form of manual-session.sh, for the development VM (D-25).
# It runs inside a real display-manager login of "Ditto G0 (Wayfire)" — the
# session's own Wayfire, Fcitx and session bus — and types with a kernel
# keyboard (uinput-keyboard.py) instead of a person:
#
#   QML probe, foot and Kate: Ctrl+Space to pinyin, nihaox, Backspace, Space
#   to take the first candidate; then the three-way clipboard.
#
# Every text result is read back from the application itself. Candidate
# placement is recorded as a screenshot per application and left for review;
# the script does not turn pixels into a verdict.
#
# This is development evidence. EX-08 still needs a physical keyboard, a
# person, and a recording (plan/02/01, D-25).
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../../.." && pwd)"
artifacts="${DITTO_ARTIFACTS:-$workspace/artifacts/g0}"
here="$workspace/tests/g0/input-method"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
work="$(mktemp -d "$XDG_RUNTIME_DIR/ditto-im-auto.XXXXXX")"
units=()

# Every application runs in its own user scope: Kate and wl-copy fork, and a
# forked child that keeps this script's output open would hold the caller's
# SSH session forever. Stopping the scope ends all of it.
start_app() {
  local unit="ditto-im-$1"
  shift
  units+=("$unit.scope")
  systemd-run --user --scope --quiet --collect --unit="$unit" -- "$@" </dev/null >/dev/null 2>&1 &
}

cleanup() {
  # Closing its input ends the keyboard helper, and the kernel removes the
  # device with it. It runs as root through sudo, so it cannot be signalled.
  if [[ -n "${KEYS_PID:-}" ]]; then
    eval "exec ${KEYS[1]}>&-" 2>/dev/null || true
    timeout 5 tail --pid="$KEYS_PID" -f /dev/null 2>/dev/null || true
  fi
  (( ${#units[@]} )) && systemctl --user stop "${units[@]}" >/dev/null 2>&1 || true
  wl-copy --clear >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT INT TERM

systemctl --user is-active --quiet ditto-g0-wayfire.scope ditto-g0-fcitx.scope || {
  echo 'no Ditto G0 login is running; this check needs the login session' >&2
  exit 1
}
wayfire_pid="$(systemctl --user show -p MainPID --value ditto-g0-wayfire.scope | grep -E '^[1-9]' ||
  head -1 "/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value ditto-g0-wayfire.scope)/cgroup.procs")"
WAYLAND_DISPLAY="$(tr '\0' '\n' <"/proc/$wayfire_pid/environ" | sed -n 's/^WAYLAND_DISPLAY=//p')"
[[ -n "$WAYLAND_DISPLAY" ]] || WAYLAND_DISPLAY="$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p')"
export WAYLAND_DISPLAY WAYFIRE_SOCKET="$XDG_RUNTIME_DIR/ditto-wayfire-ipc.sock" DITTO_COMPOSITOR=wayfire
unset DISPLAY
# shellcheck source=/dev/null
source "$workspace/tools/compositor-probe/functional/compositor.sh"

for command in fcitx5-remote jq quickshell foot kate wl-copy wl-paste grim wayland-info; do
  command -v "$command" >/dev/null || { echo "required command is missing: $command" >&2; exit 1; }
done
globals="$(wayland-info 2>/dev/null || true)"
grep -q 'zwp_text_input_manager_v3' <<<"$globals" && grep -q "interface: 'zwp_input_method_v1'" <<<"$globals" || {
  echo 'the login session does not advertise text-input-v3 and input-method-v1' >&2
  exit 1
}

mkdir -p "$artifacts"
run="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$workspace" rev-parse --short=4 HEAD 2>/dev/null || echo 0000)"
prefix="$artifacts/input-method-login-auto"
artifact="$prefix-$run.json"
qml_log="$prefix-qml-$run.log"

coproc KEYS { exec sudo -n python3 "$here/uinput-keyboard.py"; }
read -r -t 10 ready <&"${KEYS[0]}" && [[ "$ready" == ready ]] || { echo 'the kernel keyboard did not start' >&2; exit 1; }
keys() {
  local line reply
  for line in "$@"; do
    printf '%s\n' "$line" >&"${KEYS[1]}"
    read -r -t 20 reply <&"${KEYS[0]}" && [[ "$reply" == ok ]] || { echo "kernel keyboard: '$line' failed" >&2; return 1; }
  done
}

# Fcitx keeps its active state per input context. Ctrl+Space is the default
# trigger key and toggles, so it is pressed only while the focused context is
# inactive (fcitx5-remote: 1 inactive, 2 active).
# Sets `switched`; the keyboard's descriptors do not reach a $(...) subshell.
switch_to_pinyin() {
  local state _
  switched=failed
  for _ in $(seq 1 30); do
    state="$(fcitx5-remote 2>/dev/null || echo 0)"
    [[ "$state" != 0 ]] && break
    sleep 0.1
  done
  [[ "$state" == 2 ]] || keys 'combo ctrl+space'
  for _ in $(seq 1 30); do
    [[ "$(fcitx5-remote 2>/dev/null)" == 2 && "$(fcitx5-remote -n 2>/dev/null)" == pinyin ]] && { switched=trigger-key; return 0; }
    sleep 0.1
  done
  return 1
}

focus() {
  compositor_wait_for_window "$1" || { echo "$1 did not map" >&2; return 1; }
  compositor_focus_window "$1"
  sleep 0.3
}

# Compose 你好 with a correction, and screenshot while the candidates show.
compose() {
  local shot="$1"
  keys 'type nihaox' 'key backspace' 'sleep 0.4'
  grim "$shot" 2>/dev/null || true
  keys 'key space'
}

# 1. QML probe.
start_app qml env QT_QPA_PLATFORM=wayland QT_IM_MODULES=wayland QT_IM_MODULE=wayland \
  QT_LOGGING_RULES='qt.qpa.wayland.textinput=true' \
  sh -c 'exec quickshell --no-color -p "$1" >"$2" 2>&1' sh "$here/qml-input-probe.qml" "$qml_log"
for _ in $(seq 1 50); do [[ -f "$qml_log" ]] && break; sleep 0.1; done
for _ in $(seq 1 100); do grep -aq DITTO_INPUT_READY "$qml_log" && break; sleep 0.1; done
qml_id=""
for _ in $(seq 1 100); do
  qml_id="$(wayfire_ipc window-rules/list-views | jq -r 'first(.[] | select(.title == "Ditto input method probe" and .mapped)) | .id // empty')"
  [[ -n "$qml_id" ]] && break
  sleep 0.1
done
[[ -n "$qml_id" ]] || { echo 'the QML probe did not map' >&2; exit 1; }
wayfire_ipc window-rules/configure-view "{\"id\":$qml_id,\"geometry\":{\"x\":220,\"y\":160,\"width\":720,\"height\":260}}" >/dev/null
wayfire_ipc window-rules/focus-view "{\"id\":$qml_id}" >/dev/null
sleep 0.3
switch_to_pinyin || true
qml_switch="$switched"
compose "$prefix-candidate-qml-$run.png"
composing_seen=false
grep -aq DITTO_INPUT_COMPOSING "$qml_log" && composing_seen=true
keys 'key enter'
for _ in $(seq 1 50); do grep -aq DITTO_INPUT_RESULT "$qml_log" && break; sleep 0.1; done
qml_text="$(sed -n 's/.*DITTO_INPUT_RESULT //p' "$qml_log" | tail -1 | jq -r '.text // empty')"

# 2. foot: the shell's read builtin is what receives the committed text.
foot_out="$work/foot.txt"
start_app terminal foot --app-id=ditto-im-terminal sh -c 'IFS= read -r line; printf %s "$line" >"$1"' sh "$foot_out"
focus ditto-im-terminal
switch_to_pinyin || true
foot_switch="$switched"
compose "$prefix-candidate-foot-$run.png"
keys 'key enter'
for _ in $(seq 1 50); do [[ -f "$foot_out" ]] && break; sleep 0.1; done
foot_text="$(cat "$foot_out" 2>/dev/null || true)"

# 3. Kate: Ubuntu's Qt and its fcitx5 frontend, as manual-session.sh uses. A
# fresh profile opens on the welcome page, which has no text to type into, so
# Kate is given an empty document.
: >"$work/kate.txt"
start_app editor env QT_QPA_PLATFORM=wayland QT_IM_MODULE=fcitx QT_IM_MODULES=fcitx \
  sh -c 'exec kate --new "$1" >"$2" 2>&1' sh "$work/kate.txt" "$prefix-kate-$run.log"
focus org.kde.kate
switch_to_pinyin || true
kate_switch="$switched"
compose "$prefix-candidate-kate-$run.png"
wl-copy --clear >/dev/null 2>&1 || true
keys 'combo ctrl+a' 'combo ctrl+c' 'sleep 0.3'
kate_text="$(timeout 5 wl-paste --no-newline 2>/dev/null || true)"

# 4. Three-way clipboard. Each application's own copy replaces the selection,
# so the phrase is offered again before every paste.
phrase='剪貼簿互通'
offer() { printf '%s' "$phrase" | wl-copy >/dev/null 2>&1; sleep 0.2; }
paste_out="$work/foot-paste.txt"
start_app paste foot --app-id=ditto-im-paste sh -c 'IFS= read -r line; printf %s "$line" >"$1"' sh "$paste_out"
focus ditto-im-paste
offer
keys 'combo ctrl+shift+v' 'key enter'
for _ in $(seq 1 50); do [[ -f "$paste_out" ]] && break; sleep 0.1; done
foot_paste="$(cat "$paste_out" 2>/dev/null || true)"

focus org.kde.kate
offer
keys 'combo ctrl+a' 'combo ctrl+v' 'sleep 0.2' 'combo ctrl+a' 'combo ctrl+c' 'sleep 0.3'
kate_paste="$(timeout 5 wl-paste --no-newline 2>/dev/null || true)"

wayfire_ipc window-rules/focus-view "{\"id\":$qml_id}" >/dev/null
sleep 0.3
offer
results_before="$(grep -ac DITTO_INPUT_RESULT "$qml_log" || true)"
keys 'combo ctrl+a' 'combo ctrl+v' 'key enter'
for _ in $(seq 1 50); do (( $(grep -ac DITTO_INPUT_RESULT "$qml_log" || true) > results_before )) && break; sleep 0.1; done
qml_paste="$(sed -n 's/.*DITTO_INPUT_RESULT //p' "$qml_log" | tail -1 | jq -r '.text // empty')"

verdict() { [[ "$1" == *你好* ]] && echo pass || echo fail; }
clipboard=fail
[[ "$foot_paste" == "$phrase" && "$kate_paste" == "$phrase" && "$qml_paste" == "$phrase" ]] && clipboard=pass
shot() { [[ -s "$prefix-candidate-$1-$run.png" ]] && echo "$prefix-candidate-$1-$run.png" || echo; }

jq -n --arg run_id "$run" --arg environment "${DITTO_ENVIRONMENT_LABEL:-development-vm}" \
  --arg session "$(tr '\0' '\n' <"/proc/$wayfire_pid/environ" | sed -n 's/^XDG_SESSION_ID=//p')" \
  --arg fcitx "$(fcitx5 --version 2>&1 | head -1)" \
  --arg qml_text "$qml_text" --arg qml_result "$(verdict "$qml_text")" --arg qml_switch "$qml_switch" \
  --argjson composing "$composing_seen" --arg qml_shot "$(shot qml)" \
  --arg foot_text "$foot_text" --arg foot_result "$(verdict "$foot_text")" --arg foot_switch "$foot_switch" --arg foot_shot "$(shot foot)" \
  --arg kate_text "$kate_text" --arg kate_result "$(verdict "$kate_text")" --arg kate_switch "$kate_switch" --arg kate_shot "$(shot kate)" \
  --arg phrase "$phrase" --arg foot_paste "$foot_paste" --arg kate_paste "$kate_paste" --arg qml_paste "$qml_paste" \
  --arg clipboard "$clipboard" --arg qml_log "$qml_log" '{
    run_id: $run_id,
    environment: $environment,
    evidence_class: "development",
    login_session: $session,
    compositor: "wayfire",
    input_method: $fcitx,
    input_source: "kernel uinput keyboard in the display-manager login session",
    switch_method: "Ctrl+Space trigger key, pressed only when the focused input context was inactive",
    qml: {result: $qml_result, text: $qml_text, switched: $qml_switch, composing_observed: $composing,
          candidate_screenshot: (if $qml_shot == "" then null else $qml_shot end)},
    terminal: {result: $foot_result, text: $foot_text, switched: $foot_switch,
               candidate_screenshot: (if $foot_shot == "" then null else $foot_shot end)},
    editor: {result: $kate_result, text: $kate_text, switched: $kate_switch,
             candidate_screenshot: (if $kate_shot == "" then null else $kate_shot end)},
    candidate_window: "screenshots recorded for review; placement is not judged by this script",
    clipboard: {result: $clipboard, phrase: $phrase, terminal: $foot_paste, editor: $kate_paste, qml: $qml_paste},
    logs: {qml: $qml_log},
    not_evidence_for: ["EX-08: needs a physical keyboard, a person and a recording on the reference machine"]
  }' >"$artifact"

echo "artifact: $artifact"
jq -r '"qml=\(.qml.result) (\(.qml.text)) terminal=\(.terminal.result) (\(.terminal.text)) editor=\(.editor.result) (\(.editor.text)) clipboard=\(.clipboard.result)"' "$artifact"
jq -e '.qml.result == "pass" and .terminal.result == "pass" and .editor.result == "pass" and .clipboard.result == "pass"' "$artifact" >/dev/null
