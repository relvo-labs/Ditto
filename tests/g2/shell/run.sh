#!/usr/bin/env bash
# G2-SHELL-01..06 on a headless desktop with the real Shell, hostd, the
# Agent and the confined Codex backend (scripted loopback model):
#   ① Super+A opens the chat beside the character (no click needed)
#   ② a draft survives 20 switches between the panel and the full window,
#      and nothing is sent by switching
#   ③ the answer streams into the chat while the character shows thinking;
#      the stored answer then replaces the stream
#   ④ AI settings by keyboard: approval mode changed and read back from Core
#   ⑤ a new conversation offers the first-step examples
#   ⑥ with the character turned off, Super+A opens the chat as a window
# Development evidence (synthetic keyboard, scripted model).
set -euo pipefail
export DITTO_ARTIFACTS="${DITTO_ARTIFACTS:-$(cd "$(dirname "$0")/../../.." && pwd)/artifacts/g2}"
source "$(cd "$(dirname "$0")/../../g1" && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"
WINDOW_PIDS=()
PROVIDER_PID=""
cleanup() { [[ -n "$PROVIDER_PID" ]] && kill "$PROVIDER_PID" 2>/dev/null; shell_fixture_stop; }
trap cleanup EXIT INT TERM
g1_begin g2-shell "G2-SHELL (development)"
g1_preflight
evidence="$(g1_evidence_dir)"
codex="$(readlink -f "${DITTO_CODEX_BINARY:-$HOME/.local/bin/codex}" 2>/dev/null || true)"
pin_sha="$(jq -r .sha256 "$WORKSPACE/tools/codex/pin.json")"
pin_version="$(jq -r .version "$WORKSPACE/tools/codex/pin.json")"
[[ -n "$codex" && "$(sha256sum "$codex" | cut -d' ' -f1)" == "$pin_sha" ]] || { check environment environment "the pinned Codex binary is missing"; g1_finish; }
node "$WORKSPACE/tests/g2/codex/provider.mjs" "$evidence/model-requests.jsonl" >"$evidence/provider.port" 2>"$evidence/provider.log" &
PROVIDER_PID=$!
for _ in $(seq 1 50); do [[ -s "$evidence/provider.port" ]] && break; sleep 0.1; done
start_compositor >/dev/null
export DITTO_TEST_FIXTURE=1
if ! shell_fixture_start --hostd \
    --agent "agent 0.3.0 $(readlink -f "$(command -v node)") $WORKSPACE/packages/agent-runtime/dist/ditto-agentd.mjs" \
    --agent-backend "codex-app-server $pin_version $pin_sha $codex" \
    --agent-backend-test-provider "http://127.0.0.1:$(head -n1 "$evidence/provider.port")/v1"; then
  cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
  check fixture fail "the desktop fixture did not come up"; g1_finish
fi
chat() { shell_line chat; }
wait_chat() { local deadline=$((SECONDS + $2)); while (( SECONDS < deadline )); do chat >"$evidence/chat.json" 2>/dev/null && jq -e "$1" "$evidence/chat.json" >/dev/null && return 0; sleep 0.3; done; return 1; }
settings="$(relay agent.settings.describe '{}' | jq -c .result)"
relay agent.settings.patch "$(jq -c '{expected_revision:.revision, settings:(del(._meta) | .enabled=true)}' <<<"$settings")" >/dev/null

# ① the shortcut
"${G1_GUI[@]}" chord KEY_LEFTMETA KEY_A
if wait_chat '.open and .mode == "panel" and .connected' 60; then
  check shortcut-opens pass "Super+A opened the chat beside the character" "$(jq -c '{mode,state}' "$evidence/chat.json")"
else
  check shortcut-opens fail "Super+A did not open a connected chat panel" "$(cat "$evidence/chat.json" 2>/dev/null || echo null)"
fi

# ② draft through 20 switches
sleep 0.5
"${G1_GUI[@]}" paste "這段草稿不要送出"
wait_chat '.draft == "這段草稿不要送出"' 10 || true
events_before="$(jq -c .events "$evidence/chat.json")"
for i in $(seq 1 20); do
  if (( i % 2 )); then shell_line "chat-mode window" >/dev/null 2>&1 || true; else shell_line "chat-mode panel" >/dev/null 2>&1 || true; fi
  sleep 0.25
done
chat >"$evidence/chat.json"
if jq -e --argjson before "$events_before" '.draft == "這段草稿不要送出" and .events == $before and .mode == "panel"' "$evidence/chat.json" >/dev/null; then
  check draft-survives pass "20 panel/window switches kept the draft and sent nothing"
else
  check draft-survives fail "after 20 switches" "$(cat "$evidence/chat.json")"
fi

# ③ streaming: replace the draft and ask for a slow answer
shell_line "command chat.open" >/dev/null 2>&1 || true
sleep 0.4
"${G1_GUI[@]}" chord KEY_LEFTCTRL KEY_A
"${G1_GUI[@]}" paste "請慢慢說"
"${G1_GUI[@]}" press enter
saw_stream="" saw_thinking=""
for _ in $(seq 1 100); do
  chat >"$evidence/chat.json" 2>/dev/null || true
  jq -e '.streaming > 0' "$evidence/chat.json" >/dev/null 2>&1 && saw_stream=1
  jq -e '.state == "thinking"' "$evidence/chat.json" >/dev/null 2>&1 && saw_thinking=1
  jq -e '.state == "done"' "$evidence/chat.json" >/dev/null 2>&1 && break
  sleep 0.2
done
if [[ -n "$saw_stream" && -n "$saw_thinking" ]] && jq -e '.state == "done" and .streaming == 0 and (.answer|test("串流測試"))' "$evidence/chat.json" >/dev/null; then
  check streaming pass "the answer streamed while the character showed thinking; the stored answer replaced it" "$(jq -c '{state,answer}' "$evidence/chat.json")"
else
  check streaming fail "stream seen=$saw_stream thinking seen=$saw_thinking" "$(cat "$evidence/chat.json")"
fi

# ④ AI settings by keyboard
shell_line "command ai_settings.open" >/dev/null 2>&1 || true
sleep 1
if "${G1_GUI[@]}" tab-to "不要詢問，直接拒絕" >"$evidence/tab.json" 2>&1 && "${G1_GUI[@]}" press space \
  && sleep 0.5 && [[ "$(relay agent.settings.describe '{}' | jq -r .result.approval_mode)" == never ]] \
  && "${G1_GUI[@]}" tab-to "詢問我" >/dev/null 2>&1 && "${G1_GUI[@]}" press space && sleep 0.5 \
  && [[ "$(relay agent.settings.describe '{}' | jq -r .result.approval_mode)" == ask ]]; then
  check ai-settings pass "approval mode set to never and back to ask by keyboard, read back from Core"
else
  check ai-settings fail "AI settings could not be driven by keyboard" "$(cat "$evidence/tab.json" 2>/dev/null | head -c 400 | jq -Rs . )"
fi
"${G1_GUI[@]}" key KEY_ESC

# ⑤ first-step examples on a new conversation
shell_line "command chat.open" >/dev/null 2>&1 || true
sleep 0.5
if "${G1_GUI[@]}" tab-to "新對話" >/dev/null 2>&1 && "${G1_GUI[@]}" press space && sleep 0.5 \
  && "${G1_GUI[@]}" tab-to "把 Dock 移到左邊" >"$evidence/example.json" 2>&1; then
  check examples pass "a new conversation offers the first-step examples" "$(jq -c '.focused|{name,enabled}' "$evidence/example.json" 2>/dev/null || echo null)"
else
  check examples fail "the examples were not reachable" "$(head -c 300 "$evidence/example.json" | jq -Rs .)"
fi

# ⑥ no character: the shortcut opens a window
shell_line "command chat.toggle" >/dev/null 2>&1 || true
base="$(relay desktop.profiles.get '{}' | jq -r .result.profile.head_revision)"
relay desktop.changes.propose "{\"base_revision\":\"$base\",\"ops\":[{\"op\":\"set_value\",\"path\":\"/avatar/enabled\",\"after\":false}]}" >"$evidence/avatar-off.json"
sleep 1
"${G1_GUI[@]}" chord KEY_LEFTMETA KEY_A
if wait_chat '.open and .mode == "window"' 20; then
  check no-character pass "with the character off, Super+A opened the chat as a window"
else
  check no-character fail "no window chat without the character" "$(cat "$evidence/chat.json")"
fi
WAYLAND_DISPLAY="$WAYLAND_DISPLAY" grim "$evidence/window.png" 2>/dev/null || true
cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
g1_finish
