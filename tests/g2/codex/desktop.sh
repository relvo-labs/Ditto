#!/usr/bin/env bash
# G2 M1 on a real (headless) desktop: Wayfire, the real Shell under Core,
# hostd, the Agent controller and the pinned Codex app-server inside
# ditto-confine, with a scripted loopback model in place of the subscription.
#   ① the chat opens from the Shell command and reaches a connected backend
#   ② a message typed into the chat (synthetic keyboard: paste + Enter)
#   ③ the turn ends verified: Core reads the accent back, the Shell's chat
#      shows the answer and the Core change card
#   ④ closing the chat window does not cancel anything; undo restores
#   ⑤ stopping the Agent leaves the Shell and hostd running
# Development evidence only: the model is scripted, the run is headless,
# and nothing here measures subscription access, model quality or memory.
set -euo pipefail

export DITTO_ARTIFACTS="${DITTO_ARTIFACTS:-$(cd "$(dirname "$0")/../../.." && pwd)/artifacts/g2}"
source "$(cd "$(dirname "$0")/../../g1" && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
WINDOW_PIDS=()
PROVIDER_PID=""
cleanup() { [[ -n "$PROVIDER_PID" ]] && kill "$PROVIDER_PID" 2>/dev/null; shell_fixture_stop; }
trap cleanup EXIT INT TERM

g1_begin g2-m1-desktop "G2 M1 (development)"
g1_preflight
evidence="$(g1_evidence_dir)"

missing=()
for tool in quickshell node jq wl-copy; do command -v "$tool" >/dev/null || missing+=("$tool"); done
[[ -d "$WORKSPACE/target/ditto-packages" ]] || missing+=("target/ditto-packages")
codex="$(readlink -f "${DITTO_CODEX_BINARY:-$HOME/.local/bin/codex}" 2>/dev/null || true)"
pin_sha="$(jq -r .sha256 "$WORKSPACE/tools/codex/pin.json")"
pin_version="$(jq -r .version "$WORKSPACE/tools/codex/pin.json")"
[[ -n "$codex" && -f "$codex" && "$(sha256sum "$codex" | cut -d' ' -f1)" == "$pin_sha" ]] || missing+=("the pinned Codex binary")
"$WORKSPACE/target/debug/ditto-confine" --read /usr -- /usr/bin/true 2>/dev/null || { check environment environment "this kernel cannot confine the Codex backend (Landlock ABI < 6); Core refuses it, as designed"; g1_finish; }
if (( ${#missing[@]} > 0 )); then
  check g2-m1-desktop environment "missing: ${missing[*]}"
  g1_finish
fi

accent="#3366ff"
export DITTO_G2_CLIP="clip-canary-$RANDOM$RANDOM"
node "$HERE/provider.mjs" "$evidence/model-requests.jsonl" "$accent" >"$evidence/provider.port" 2>"$evidence/provider.log" &
PROVIDER_PID=$!
for _ in $(seq 1 50); do [[ -s "$evidence/provider.port" ]] && break; sleep 0.1; done
port="$(head -n1 "$evidence/provider.port")"

start_compositor >/dev/null
export DITTO_TEST_FIXTURE=1
if ! shell_fixture_start --hostd \
    --agent "agent 0.3.0 $(readlink -f "$(command -v node)") $WORKSPACE/packages/agent-runtime/dist/ditto-agentd.mjs" \
    --agent-backend "codex-app-server $pin_version $pin_sha $codex" \
    --agent-backend-test-provider "http://127.0.0.1:$port/v1"; then
  cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
  check fixture fail "the desktop fixture did not come up; log in $evidence/core.log"
  g1_finish
fi
shell_pid="$(core_child quickshell)"
host_pid="$(core_child ditto-hostd)"

chat() { shell_line chat; }
wait_chat() { # <jq predicate> <seconds>
  local deadline=$((SECONDS + $2))
  while (( SECONDS < deadline )); do
    chat >"$evidence/chat.json" 2>/dev/null && jq -e "$1" "$evidence/chat.json" >/dev/null && return 0
    sleep 0.5
  done
  return 1
}

settings="$(relay agent.settings.describe '{}' | jq -c .result)"
relay agent.settings.patch "$(jq -c '{expected_revision:.revision, settings:(del(._meta) | .enabled=true)}' <<<"$settings")" >"$evidence/settings.json"
jq -e '.result.enabled == true' "$evidence/settings.json" >/dev/null || { check settings fail "AI could not be enabled" "$(cat "$evidence/settings.json")"; g1_finish; }
before="$(relay desktop.appearance.get '{}' | jq -r .result.appearance.tokens.accent)"

# ① the chat opens and reaches the backend
shell_line "command chat.open" >/dev/null 2>&1 || true
if wait_chat '.open and .connected' 60; then
  check chat-opens pass "the chat opened and reached the confined backend" "$(jq -c '{state,text}' "$evidence/chat.json")"
else
  check chat-opens fail "the chat did not reach a connected backend" "$(cat "$evidence/chat.json" 2>/dev/null || echo null)"
  cp "$RUNTIME_DIR/core.log" "$evidence/core.log"; g1_finish
fi
runtime="$(relay agent.runtime.get '{}' | jq -c .result)"
if jq -e '.isolation_verified == true and (.backend_pid | type == "number")' <<<"$runtime" >/dev/null \
  && grep -q '^Seccomp:[[:space:]]*2' "/proc/$(jq -r .backend_pid <<<"$runtime")/status"; then
  check backend-confined pass "Core launched the backend confined" "$runtime"
else
  check backend-confined fail "the backend is not Core-verified confined" "$runtime"
fi

# ② typed into the chat: the message field has focus when the window opens
sleep 1
"${G1_GUI[@]}" paste "把強調色改成藍色"
"${G1_GUI[@]}" press enter

# ③ verified end, shown in the Shell
if wait_chat '.state == "done" or .state == "failed"' 90 && jq -e '.state == "done"' "$evidence/chat.json" >/dev/null; then
  check turn-verified pass "the chat shows a verified, finished turn" "$(jq -c '{state,text,turn_state,answer,changes}' "$evidence/chat.json")"
else
  check turn-verified fail "the turn did not finish verified" "$(cat "$evidence/chat.json")"
fi
appearance="$(relay desktop.appearance.get '{}' | jq -c .result)"
after="$(jq -r .appearance.tokens.accent <<<"$appearance")"
[[ "$after" == "$accent" ]] && check readback pass "Core reads the accent back as $after (was $before)" "$(jq -c .shell_applied <<<"$appearance")" \
  || check readback fail "Core reads $after, wanted $accent" "$appearance"
change_id="$(jq -r '.changes[0] // empty' "$evidence/chat.json")"
record="$(relay desktop.changes.get "{\"change_id\":\"$change_id\"}" | jq -c .result)"
if jq -e '.state == "committed" and .origin.kind == "agent"' <<<"$record" >/dev/null; then
  check change-card pass "the chat's change card is Core's committed, Agent-attributed record" "$(jq -c '{change_id,state,origin}' <<<"$record")"
else
  check change-card fail "no committed Agent change behind the chat" "$record"
fi
WAYLAND_DISPLAY="$WAYLAND_DISPLAY" grim "$evidence/chat.png" 2>/dev/null && g1_note "screenshot: $evidence/chat.png"

# ④ closing the chat window is not cancelling; undo goes through Core
"${G1_GUI[@]}" key KEY_ESC
wait_chat '.open == false' 10 && check chat-closes pass "Escape closed the chat; the turn stays $(jq -r .turn_state "$evidence/chat.json")" \
  || check chat-closes fail "the chat did not close"
relay desktop.changes.undo "{\"change_id\":\"$change_id\",\"idempotency_key\":\"m1-desktop-undo\"}" >/dev/null
undone="$(relay desktop.appearance.get '{}' | jq -r .result.appearance.tokens.accent)"
[[ "$undone" == "$before" ]] && check undo pass "undo restored $before" || check undo fail "after undo: $undone"

# ⑥ approval, allowed once by keyboard: the Agent may read the window list
#    only after the person allows that one call
ask() { # <message> → waits for the approval window to take focus
  shell_line "command chat.open" >/dev/null 2>&1 || true
  wait_chat '.open and .connected and (.state != "thinking")' 30 || true
  sleep 1
  "${G1_GUI[@]}" paste "$1"
  "${G1_GUI[@]}" press enter
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    "${G1_GUI[@]}" focus >"$evidence/focus.json" 2>/dev/null || true
    jq -e '.focused.name == "拒絕"' "$evidence/focus.json" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
if ask "列出目前的視窗"; then
  awaiting="$(chat | jq -r .state)"
  "${G1_GUI[@]}" tab-to "允許這一次" >/dev/null
  "${G1_GUI[@]}" press enter
  if wait_chat '.state == "done"' 60 && jq -e '.answer | test("個視窗")' "$evidence/chat.json" >/dev/null; then
    check approval-allowed pass "the chat showed $awaiting while the approval was open; allowed once, the Agent read the window list" "$(jq -c '{state,answer}' "$evidence/chat.json")"
  else
    check approval-allowed fail "allowing did not complete the turn" "$(cat "$evidence/chat.json")"
  fi
else
  check approval-allowed fail "no approval request reached the Shell" "$(cat "$evidence/focus.json" 2>/dev/null || echo null)"
fi

# ⑦ approval refused with Escape: the call is refused, nothing else runs
if ask "再列一次視窗"; then
  "${G1_GUI[@]}" key KEY_ESC
  if wait_chat '.state == "done" or .state == "failed"' 60 && jq -e '.answer | test("沒有取得")' "$evidence/chat.json" >/dev/null; then
    check approval-refused pass "refused with Escape; the tool call was denied and the model was told so" "$(jq -c '{state,turn_state,answer}' "$evidence/chat.json")"
  else
    check approval-refused fail "refusing did not end the turn as expected" "$(cat "$evidence/chat.json")"
  fi
else
  check approval-refused fail "the second approval request did not reach the Shell" "$(cat "$evidence/focus.json" 2>/dev/null || echo null)"
fi

# ⑧ approval mode "never": nobody is asked, the call is refused
patch_settings() { # <jq filter on settings>
  local current; current="$(relay agent.settings.describe '{}' | jq -c .result)"
  relay agent.settings.patch "$(jq -c "{expected_revision:.revision, settings:(del(._meta) | $1)}" <<<"$current")" >/dev/null
}
ask_quiet() { # <message> → no approval window may appear; waits for the turn
  shell_line "command chat.open" >/dev/null 2>&1 || true
  sleep 1
  "${G1_GUI[@]}" paste "$1"; "${G1_GUI[@]}" press enter
  local saw=""
  for _ in $(seq 1 60); do
    "${G1_GUI[@]}" focus >"$evidence/focus.json" 2>/dev/null || true
    jq -e '.focused.name == "拒絕"' "$evidence/focus.json" >/dev/null 2>&1 && saw=1
    chat >"$evidence/chat.json" 2>/dev/null || true
    jq -e '(.state == "done" or .state == "failed") and (.answer|type=="string")' "$evidence/chat.json" >/dev/null 2>&1 && [[ "$(jq -r .events[-1] "$evidence/chat.json")" == "turn/end" ]] && break
    sleep 0.5
  done
  [[ -z "$saw" ]]
}
patch_settings '.approval_mode="never"'
if ask_quiet "列出視窗（不要問我）" && jq -e '.answer|test("沒有取得")' "$evidence/chat.json" >/dev/null; then
  check approval-never pass "mode never: no prompt, the call was refused" "$(jq -c '{state,answer}' "$evidence/chat.json")"
else
  check approval-never fail "mode never did not refuse silently" "$(cat "$evidence/chat.json")"
fi
patch_settings '.approval_mode="ask"'

# ⑨ a standing grant: no prompt, allowed; ⑩ revoked: asked again
grant="$(relay desktop.permissions.grant '{"subject":"agent","scope":"desktop.windows.read","idempotency_key":"g2-grant-windows"}')"
echo "$grant" >"$evidence/grant.json"
if ask_quiet "列出現在的視窗" && jq -e '.answer|test("個視窗")' "$evidence/chat.json" >/dev/null; then
  check approval-granted pass "with a standing grant the Agent read windows without a prompt" "$(jq -c '{state,answer}' "$evidence/chat.json")"
else
  check approval-granted fail "the grant did not apply" "$(jq -c . "$evidence/grant.json"; cat "$evidence/chat.json")"
fi
grant_id="$(jq -r '.result.grant_id // .result.grant.grant_id // empty' "$evidence/grant.json")"
relay desktop.permissions.revoke "{\"grant_id\":\"$grant_id\"}" >"$evidence/revoke.json"
if ask "再看一次視窗"; then
  "${G1_GUI[@]}" key KEY_ESC
  wait_chat '.state == "done" or .state == "failed"' 60 || true
  check approval-revoked pass "after revoking, the Agent had to ask again" "$(jq -c "{grant_id:.result.grant_id,revoked_at:.result.revoked_at}" "$evidence/revoke.json")"
else
  check approval-revoked fail "no prompt after revoke" "$(cat "$evidence/revoke.json")"
fi

# ⑪ clipboard and ⑫ screen, attached from the chat and sent with a message
attach_and_send() { # <kind> <message> <expected answer> <check id>
  shell_line "command chat.open" >/dev/null 2>&1 || true
  sleep 1
  shell_line "chat-attach $1" >/dev/null 2>&1 || true
  if ! wait_chat "(.attached|length) == 1 and .attached[0].kind == \"$1\"" 20; then
    check "$4" fail "the $1 was not attached" "$(cat "$evidence/chat.json")"; return
  fi
  "${G1_GUI[@]}" paste "$2"; "${G1_GUI[@]}" press enter
  if wait_chat "(.state == \"done\" or .state == \"failed\") and (.answer|type==\"string\") and (.answer|test(\"$3\")) and (.attached|length)==0" 60; then
    check "$4" pass "attached $1 reached the model with the message and was cleared from the draft" "$(jq -c '{answer,attached}' "$evidence/chat.json")"
  else
    check "$4" fail "the $1 attachment did not complete" "$(cat "$evidence/chat.json")"
  fi
}
printf '%s' "$DITTO_G2_CLIP" | wl-copy
attach_and_send clipboard "看看這個附件" "剪貼簿" context-clipboard
WAYLAND_DISPLAY="$WAYLAND_DISPLAY" grim "$evidence/before-capture.png" 2>/dev/null || true
attach_and_send capture "看看附件截圖" "截圖" context-capture
if grep -q "$DITTO_G2_CLIP" "$RUNTIME_DIR/core.log"; then
  check context-private fail "the clipboard text appeared in Core's log"
else
  check context-private pass "the clipboard text is in no Core log line"
fi

# ⑤ the Agent goes; the desktop stays
backend_pid="$(jq -r .backend_pid <<<"$runtime")"
relay agent.runtime.stop '{}' >/dev/null
for _ in $(seq 1 100); do [[ "$(relay agent.runtime.get '{}' | jq -r .result.phase)" == stopped ]] && break; sleep 0.1; done
if [[ "$(relay agent.runtime.get '{}' | jq -r .result.phase)" == stopped && ! -d "/proc/$backend_pid" \
  && "$(core_child quickshell)" == "$shell_pid" && "$(core_child ditto-hostd)" == "$host_pid" ]]; then
  check agent-exit pass "Agent and backend stopped; Shell $shell_pid and hostd $host_pid kept running"
else
  check agent-exit fail "after stopping the Agent: shell $(core_child quickshell) (was $shell_pid), hostd $(core_child ditto-hostd) (was $host_pid), backend $backend_pid present=$([[ -d /proc/$backend_pid ]] && echo yes || echo no)"
fi

tools="$(jq -s '[.[] | ((.tools // []) + ([.input[]? | select(.type=="additional_tools") | .tools[]]) ) | .. | objects | select(has("name") and (has("tools") | not)) | .name] | unique' "$evidence/model-requests.jsonl")"
if jq -e 'map(select(type=="string")) | map(select(startswith("desktop__") or startswith("request_user_input") | not)) | length == 0' <<<"$tools" >/dev/null; then
  check tool-surface pass "the model was offered only Ditto tools (and refused user-input requests)" "$tools"
else
  check tool-surface fail "built-in tools reached the model" "$tools"
fi
cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
g1_note "model: scripted loopback (no subscription, no inference); evidence class: development headless desktop"
g1_finish
