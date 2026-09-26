#!/usr/bin/env bash
# Automated diagnostic for G0-PLAT-04. It records protocol discovery, Qt's
# text-input-v3 activation, the selected Fcitx engine, and the text read back
# from a real QML control. It fails unless that control contains committed
# Chinese. Physical input and the reference applications remain manual checks.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"

WINDOW_PIDS=()
FCITX_PID=""
QML_PID=""

cleanup() {
  [[ -n "$QML_PID" ]] && kill "$QML_PID" 2>/dev/null || true
  [[ -n "$FCITX_PID" ]] && kill "$FCITX_PID" 2>/dev/null || true
  stop_all
}
trap cleanup EXIT INT TERM

for command in fcitx5 fcitx5-remote jq quickshell wayland-info; do
  command -v "$command" >/dev/null || {
    echo "required command is missing: $command" >&2
    exit 1
  }
done

[[ "$DITTO_COMPOSITOR" == "wayfire" ]] || {
  echo 'C-08 follows the selected Wayfire path; set DITTO_COMPOSITOR=wayfire' >&2
  exit 1
}

mkdir -p "$ARTIFACTS"
start_compositor

# The fixture owns its input-method configuration. It never reads or changes
# the developer's profile, and its session bus was created by start_compositor.
export XDG_CONFIG_HOME="$RUNTIME_DIR/config"
mkdir -p "$XDG_CONFIG_HOME/fcitx5"
cp "$WORKSPACE/tests/g0/input-method/fcitx5-profile" "$XDG_CONFIG_HOME/fcitx5/profile"
export XMODIFIERS='@im=fcitx'
export QT_QPA_PLATFORM=wayland
# Qt 6.7+ uses the plural fallback list. Selecting `wayland` is what makes the
# Qt 6.10 client bind text-input-v3. The singular selector is also explicit:
# merely unsetting it falls back to the compose input context on this non-KWin
# compositor, even when the plural fallback is present.
export QT_IM_MODULES=wayland
export QT_IM_MODULE=wayland
export QT_LOGGING_RULES='qt.qpa.wayland.textinput=true'
unset GTK_IM_MODULE

globals="$(wayland-info 2>/dev/null || true)"
grep -q 'zwp_text_input_manager_v3' <<<"$globals" || {
  echo 'Wayfire did not advertise zwp_text_input_manager_v3' >&2
  exit 1
}
grep -q "interface: 'zwp_input_method_v1'" <<<"$globals" || {
  echo 'Wayfire did not advertise zwp_input_method_v1' >&2
  exit 1
}

fcitx5 -D --replace >"$RUNTIME_DIR/fcitx5.log" 2>&1 &
FCITX_PID=$!
for _ in $(seq 1 100); do
  if fcitx5-remote -n >/dev/null 2>&1; then
    break
  fi
  kill -0 "$FCITX_PID" 2>/dev/null || {
    cat "$RUNTIME_DIR/fcitx5.log" >&2
    echo 'fcitx5 stopped before its D-Bus interface became ready' >&2
    exit 1
  }
  sleep 0.1
done
fcitx5-remote -n >/dev/null 2>&1 || {
  cat "$RUNTIME_DIR/fcitx5.log" >&2
  echo 'fcitx5 D-Bus interface did not become ready' >&2
  exit 1
}

quickshell --no-color -p "$WORKSPACE/tests/g0/input-method/qml-input-probe.qml" \
  >"$RUNTIME_DIR/qml-input.log" 2>&1 &
QML_PID=$!
for _ in $(seq 1 100); do
  grep -aq 'DITTO_INPUT_READY' "$RUNTIME_DIR/qml-input.log" && break
  kill -0 "$QML_PID" 2>/dev/null || {
    cat "$RUNTIME_DIR/qml-input.log" >&2
    echo 'the QML input probe stopped before it became ready' >&2
    exit 1
  }
  sleep 0.1
done
grep -aq 'DITTO_INPUT_READY' "$RUNTIME_DIR/qml-input.log" || {
  cat "$RUNTIME_DIR/qml-input.log" >&2
  echo 'the QML input probe did not become ready' >&2
  exit 1
}

# Put the xdg-toplevel at a known location and focus it through the compositor.
# The click still goes through the seat, as it would for a user's pointer.
view_id=""
for _ in $(seq 1 100); do
  view_id="$(wayfire_ipc window-rules/list-views | jq -r \
    'first(.[] | select(.title == "Ditto input method probe" and .mapped)) | .id // empty')"
  [[ -n "$view_id" ]] && break
  sleep 0.1
done
[[ -n "$view_id" ]] || {
  wayfire_ipc window-rules/list-views >&2
  echo 'the QML input probe did not map an xdg-toplevel' >&2
  exit 1
}
wayfire_ipc window-rules/configure-view \
  "{\"id\":$view_id,\"geometry\":{\"x\":220,\"y\":160,\"width\":720,\"height\":260}}" >/dev/null
wayfire_ipc window-rules/focus-view "{\"id\":$view_id}" >/dev/null
wayfire_ipc stipc/move_cursor '{"x":360,"y":260}' >/dev/null
wayfire_ipc stipc/feed_button '{"combo":"BTN_LEFT","mode":"full"}' >/dev/null
for _ in $(seq 1 50); do
  [[ -n "$(fcitx5-remote -n 2>/dev/null || true)" ]] && break
  sleep 0.1
done
fcitx5-remote -s pinyin
fcitx5-remote -o
[[ "$(fcitx5-remote -n)" == "pinyin" ]] || {
  echo "fcitx5 selected an unexpected input method: $(fcitx5-remote -n)" >&2
  exit 1
}

feed_key() {
  local key="$1"
  wayfire_ipc stipc/feed_key "{\"key\":\"$key\",\"state\":true}" >/dev/null
  wayfire_ipc stipc/feed_key "{\"key\":\"$key\",\"state\":false}" >/dev/null
}

for key in KEY_N KEY_I KEY_H KEY_A KEY_O; do
  feed_key "$key"
done

run="$(run_id)"
screenshot="$ARTIFACTS/input-method-candidate-$run.png"
if command -v grim >/dev/null; then
  # The screenshot is evidence for the remaining visual judgement. The script
  # deliberately does not turn pixels into a pass/fail claim.
  grim "$screenshot" 2>"$RUNTIME_DIR/grim.log" || screenshot=""
else
  screenshot=""
fi

feed_key KEY_SPACE
feed_key KEY_ENTER

for _ in $(seq 1 50); do
  grep -aq 'DITTO_INPUT_RESULT' "$RUNTIME_DIR/qml-input.log" && break
  sleep 0.1
done
result_line="$(sed -n 's/.*DITTO_INPUT_RESULT //p' "$RUNTIME_DIR/qml-input.log" | tail -1)"
[[ -n "$result_line" ]] || {
  cat "$RUNTIME_DIR/qml-input.log" >&2
  cat "$RUNTIME_DIR/fcitx5.log" >&2
  echo 'the QML control did not report a committed result' >&2
  exit 1
}
committed="$(jq -r '.text' <<<"$result_line")"
if [[ "$committed" == *[一-龥]* ]]; then
  commit_result=pass
  candidate_result=manual_review_required
else
  commit_result=fail
  candidate_result=not_observed
fi

if grep -aq 'QWaylandTextInputv3::enableSurface' "$RUNTIME_DIR/qml-input.log"; then
  qt_text_input_v3=enabled
else
  qt_text_input_v3=not_observed
fi

qml_log="$ARTIFACTS/input-method-qml-$run.log"
fcitx_log="$ARTIFACTS/input-method-fcitx-$run.log"
compositor_log="$ARTIFACTS/input-method-wayfire-$run.log"
cp "$RUNTIME_DIR/qml-input.log" "$qml_log"
cp "$RUNTIME_DIR/fcitx5.log" "$fcitx_log"
cp "$COMPOSITOR_LOG" "$compositor_log"

artifact="$ARTIFACTS/input-method-$run.json"
jq -n \
  --arg run_id "$run" \
  --arg environment "$(environment_label)" \
  --arg compositor "wayfire" \
  --arg input_method "$(fcitx5 --version 2>&1 | head -1)" \
  --arg engine "$(fcitx5-remote -n)" \
  --arg text "$committed" \
  --arg screenshot "$screenshot" \
  --arg commit_result "$commit_result" \
  --arg candidate_result "$candidate_result" \
  --arg qt_text_input_v3 "$qt_text_input_v3" \
  --arg qml_log "$qml_log" \
  --arg fcitx_log "$fcitx_log" \
  --arg compositor_log "$compositor_log" \
  '{
    run_id: $run_id,
    environment: $environment,
    compositor: $compositor,
    protocols: {
      text_input_v3: "advertised",
      input_method_v1: "advertised",
      qt_text_input_v3: $qt_text_input_v3
    },
    input_method: $input_method,
    engine: $engine,
    injection: "Wayfire stipc virtual keyboard",
    qml_commit: {result: $commit_result, text: $text},
    candidate_window: {
      result: $candidate_result,
      screenshot: (if $screenshot == "" then null else $screenshot end)
    },
    logs: {
      qml: $qml_log,
      fcitx: $fcitx_log,
      compositor: $compositor_log
    },
    not_probed: [
      "physical keyboard input",
      "reference terminal",
      "reference editor",
      "clipboard interoperability among all three applications",
      "display-manager login session"
    ]
  }' >"$artifact"

if [[ "$commit_result" != pass ]]; then
  echo "C-08 automated diagnostic failed: fcitx5 did not commit Chinese text; QML read back '$committed'" >&2
  echo "artifact: $artifact" >&2
  [[ -z "$screenshot" ]] || echo "screenshot: $screenshot" >&2
  echo 'This does not distinguish a stipc virtual-keyboard limitation from a compositor/input-method bridge defect; rerun with a physical keyboard.' >&2
  exit 1
fi

echo "C-08 automated slice: Wayfire advertised both protocols and fcitx5 committed '$committed' into the QML control"
[[ -z "$screenshot" ]] || echo "candidate-window screenshot for manual review: $screenshot"
echo "artifact: $artifact"
echo 'development evidence only; EX-08 still requires the reference terminal/editor, clipboard, candidate placement, and reference-machine rerun'
