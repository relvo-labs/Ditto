#!/usr/bin/env bash
# Physical-keyboard portion of G0-PLAT-04. Run this from a terminal inside the
# actual Ditto Wayfire login session. It does not start or replace the
# compositor, session bus, or Fcitx instance.
set -euo pipefail

WORKSPACE="${DITTO_WORKSPACE:-$(cd "$(dirname "$0")/../../.." && pwd)}"
ARTIFACTS="${DITTO_ARTIFACTS:-$WORKSPACE/artifacts/g0}"
RUNTIME_DIR="$(mktemp -d /tmp/ditto-input-manual.XXXXXX)"
QML_PID=""
WATCH_PID=""
KATE_PID=""

cleanup() {
  [[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null || true
  [[ -n "$KATE_PID" ]] && kill "$KATE_PID" 2>/dev/null || true
  [[ -n "$QML_PID" ]] && kill "$QML_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf -- "$RUNTIME_DIR"
}
trap cleanup EXIT INT TERM

for command in fcitx5-remote jq quickshell wayland-info wl-copy wl-paste kate; do
  command -v "$command" >/dev/null || {
    echo "required command is missing: $command" >&2
    exit 1
  }
done

[[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]] || {
  echo 'run this script from a terminal inside the Ditto Wayfire session' >&2
  exit 1
}

globals="$(wayland-info 2>/dev/null || true)"
grep -q 'zwp_text_input_manager_v3' <<<"$globals" || {
  echo 'the current session does not advertise zwp_text_input_manager_v3' >&2
  exit 1
}
grep -q "interface: 'zwp_input_method_v1'" <<<"$globals" || {
  echo 'the current session does not advertise zwp_input_method_v1' >&2
  exit 1
}
fcitx5-remote -n >/dev/null 2>&1 || {
  echo 'the current session has no reachable Fcitx input context' >&2
  exit 1
}

mkdir -p "$ARTIFACTS"
run="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$WORKSPACE" rev-parse --short=4 HEAD 2>/dev/null || echo 0000)"
qml_log="$ARTIFACTS/input-method-physical-qml-$run.log"
screenshot="$ARTIFACTS/input-method-physical-candidate-$run.png"
artifact="$ARTIFACTS/input-method-physical-$run.json"

export QT_QPA_PLATFORM=wayland
export QT_IM_MODULES=wayland
export QT_IM_MODULE=wayland
export QT_LOGGING_RULES='qt.qpa.wayland.textinput=true'

quickshell --no-color -p "$WORKSPACE/tests/g0/input-method/qml-input-probe.qml" \
  >"$qml_log" 2>&1 &
QML_PID=$!
for _ in $(seq 1 100); do
  grep -aq 'DITTO_INPUT_READY' "$qml_log" && break
  kill -0 "$QML_PID" 2>/dev/null || {
    cat "$qml_log" >&2
    echo 'the QML input probe stopped before it became ready' >&2
    exit 1
  }
  sleep 0.1
done
grep -aq 'DITTO_INPUT_READY' "$qml_log" || {
  cat "$qml_log" >&2
  echo 'the QML input probe did not become ready' >&2
  exit 1
}

if command -v grim >/dev/null; then
  (
    while kill -0 "$QML_PID" 2>/dev/null; do
      if grep -aq 'DITTO_INPUT_COMPOSING' "$qml_log"; then
        # Give the input method one frame to map its candidate popup.
        sleep 0.1
        grim "$screenshot" >/dev/null 2>&1 || true
        exit 0
      fi
      sleep 0.1
    done
  ) &
  WATCH_PID=$!
else
  screenshot=""
fi

cat <<'EOF'
QML 測試窗已開啟。請用實體鍵盤完成：
  1. 點擊文字欄並用平常的快捷鍵切到拼音。
  2. 輸入 nihaox，按一次 Backspace，確認候選窗貼近游標。
  3. 選擇「你好」，再按 Enter 送出。

腳本會等待文字元件的實際提交結果；不要在這個終端按 Enter。
EOF

while ! grep -aq 'DITTO_INPUT_RESULT' "$qml_log"; do
  kill -0 "$QML_PID" 2>/dev/null || {
    cat "$qml_log" >&2
    echo 'the QML input probe closed before reporting a result' >&2
    exit 1
  }
  sleep 0.1
done

[[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
[[ -z "$screenshot" || -s "$screenshot" ]] || screenshot=""
result_line="$(sed -n 's/.*DITTO_INPUT_RESULT //p' "$qml_log" | tail -1)"
committed="$(jq -r '.text' <<<"$result_line")"
engine="$(fcitx5-remote -n 2>/dev/null || true)"
if [[ "$committed" == *[一-龥]* ]]; then
  commit_result=pass
else
  commit_result=fail
fi

printf '候選窗位置是否貼近輸入游標？輸入 correct、wrong 或 not-seen： '
IFS= read -r candidate_result
case "$candidate_result" in
  correct|wrong|not-seen) ;;
  *)
    echo 'invalid observation; expected correct, wrong, or not-seen' >&2
    exit 1
    ;;
esac

cat <<'EOF'

終端測試（目前這個 foot 視窗）：
  1. 切到拼音，輸入 nihaox，按一次 Backspace。
  2. 確認候選窗位置，選擇「你好」。
  3. 按 Enter；下方提示會直接讀取終端收到的文字。
EOF
printf '終端提交文字： '
IFS= read -r terminal_text
printf '終端候選窗位置（correct、wrong 或 not-seen）： '
IFS= read -r terminal_candidate
case "$terminal_candidate" in correct|wrong|not-seen) ;; *) echo 'invalid terminal observation' >&2; exit 1 ;; esac

wl-copy --clear 2>/dev/null || true
# Kate uses Ubuntu's system Qt and matching fcitx5-frontend-qt6 plugin. It must
# not inherit Quickshell's self-built Qt 6.10 Wayland input-context selector.
QT_QPA_PLATFORM=wayland QT_IM_MODULE=fcitx QT_IM_MODULES=fcitx \
  kate --new >"$ARTIFACTS/input-method-physical-kate-$run.log" 2>&1 &
KATE_PID=$!
cat <<'EOF'

Kate 測試：
  1. 在新文件切到拼音，輸入 nihaox，按一次 Backspace。
  2. 確認候選窗位置，選擇「你好」。
  3. Ctrl+A、Ctrl+C；回到這個終端按 Enter。
EOF
IFS= read -r _
editor_text="$(timeout 5 wl-paste --no-newline 2>/dev/null || true)"
printf 'Kate 候選窗位置（correct、wrong 或 not-seen）： '
IFS= read -r editor_candidate
case "$editor_candidate" in correct|wrong|not-seen) ;; *) echo 'invalid editor observation' >&2; exit 1 ;; esac

clipboard_phrase='剪貼簿互通'
printf '%s' "$clipboard_phrase" | wl-copy
cat <<'EOF'

剪貼簿互通測試：
  1. 在目前 foot 提示按 Ctrl+Shift+V，再按 Enter。
EOF
printf 'foot 貼上結果： '
IFS= read -r terminal_paste

printf '%s' "$clipboard_phrase" | wl-copy
cat <<'EOF'
  2. 在 Kate Ctrl+A、Ctrl+V、Ctrl+A、Ctrl+C；回到這個終端按 Enter。
EOF
IFS= read -r _
editor_paste="$(timeout 5 wl-paste --no-newline 2>/dev/null || true)"

printf '%s' "$clipboard_phrase" | wl-copy
before_results="$(grep -ac 'DITTO_INPUT_RESULT' "$qml_log" || true)"
cat <<'EOF'
  3. 在 QML 測試窗 Ctrl+A、Ctrl+V，再按 Enter。
EOF
while [[ "$(grep -ac 'DITTO_INPUT_RESULT' "$qml_log" || true)" -le "$before_results" ]]; do
  kill -0 "$QML_PID" 2>/dev/null || { echo 'QML probe closed during clipboard check' >&2; exit 1; }
  sleep 0.1
done
qml_paste_line="$(sed -n 's/.*DITTO_INPUT_RESULT //p' "$qml_log" | tail -1)"
qml_paste="$(jq -r '.text' <<<"$qml_paste_line")"

terminal_result=fail
editor_result=fail
clipboard_result=fail
[[ "$terminal_text" == *[一-龥]* && "$terminal_candidate" == correct ]] && terminal_result=pass
[[ "$editor_text" == *[一-龥]* && "$editor_candidate" == correct ]] && editor_result=pass
[[ "$terminal_paste" == "$clipboard_phrase" && "$editor_paste" == "$clipboard_phrase" && "$qml_paste" == "$clipboard_phrase" ]] && clipboard_result=pass

jq -n \
  --arg run_id "$run" \
  --arg environment "${DITTO_ENVIRONMENT_LABEL:-development-workstation-physical-session}" \
  --arg engine "$engine" \
  --arg text "$committed" \
  --arg commit_result "$commit_result" \
  --arg candidate_result "$candidate_result" \
  --arg terminal_text "$terminal_text" \
  --arg terminal_result "$terminal_result" \
  --arg terminal_candidate "$terminal_candidate" \
  --arg editor_text "$editor_text" \
  --arg editor_result "$editor_result" \
  --arg editor_candidate "$editor_candidate" \
  --arg clipboard_phrase "$clipboard_phrase" \
  --arg terminal_paste "$terminal_paste" \
  --arg editor_paste "$editor_paste" \
  --arg qml_paste "$qml_paste" \
  --arg clipboard_result "$clipboard_result" \
  --arg screenshot "$screenshot" \
  --arg qml_log "$qml_log" \
  '{
    run_id: $run_id,
    environment: $environment,
    compositor: "wayfire",
    protocols: {
      text_input_v3: "advertised",
      input_method_v1: "advertised"
    },
    input_source: "physical keyboard",
    engine: $engine,
    qml_commit: {result: $commit_result, text: $text},
    candidate_window: {
      result: $candidate_result,
      screenshot: (if $screenshot == "" then null else $screenshot end)
    },
    terminal: {result: $terminal_result, text: $terminal_text, candidate_window: $terminal_candidate},
    editor: {result: $editor_result, text: $editor_text, candidate_window: $editor_candidate},
    clipboard: {
      result: $clipboard_result,
      phrase: $clipboard_phrase,
      terminal: $terminal_paste,
      editor: $editor_paste,
      qml: $qml_paste
    },
    logs: {qml: $qml_log},
    recording: "attach the physical-session recording location in docs/platform/input-method-report.md"
  }' >"$artifact"

echo "artifact: $artifact"
[[ -z "$screenshot" ]] || echo "candidate screenshot: $screenshot"
if [[ "$commit_result" != pass || "$candidate_result" != correct || "$terminal_result" != pass || "$editor_result" != pass || "$clipboard_result" != pass ]]; then
  echo "physical-session input chain did not pass; inspect $artifact" >&2
  exit 1
fi
echo 'physical-session QML, foot, Kate and three-way clipboard checks passed.'
echo 'EX-08 evidence still requires the recording location to be entered in docs/platform/input-method-report.md.'
