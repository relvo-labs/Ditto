#!/usr/bin/env bash
# G2-QA-01 semantic sets on a real (headless, nested) desktop: Wayfire, the
# real Shell under Core, hostd, the Agent and the pinned Codex app-server in
# ditto-confine, and Firefox, foot and Kate as the windows tasks arrange.
#
#   run.sh --tasks fixed|holdout [--self-test|--null] [task id ...]
#
# Model runs use the subscription signed in by tests/g2/codex/subscription.mjs
# (its Core store, DITTO_G2_SUBSCRIPTION_DIR, default
# ~/.cache/ditto-g2-subscription) and the person's session bus, where the
# keyring holds that sign-in; nothing is copied anywhere. Without a signed-in
# subscription the run is not_run (exit 2), never scored.
# --self-test applies each task's reference solution as the CLI instead of
# asking the model: it proves fixtures and predicates, and is no score.
# --null does nothing at all: every task must fail (no vacuous oracle).
# The nested desktop has its own sockets and store beside a logged-in Ditto
# session (DITTO_REFERENCE_MACHINE fixture mode).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export DITTO_ARTIFACTS="${DITTO_ARTIFACTS:-$(cd "$here/../../.." && pwd)/artifacts/g2}"
source "$here/../../g1/lib/common.sh"
source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"

set_name="" mode=model ids=()
while (( $# )); do
  case "$1" in
    --tasks) set_name="$2"; shift 2 ;;
    --self-test) mode=self-test; shift ;;
    --null) mode=null; shift ;;
    *) ids+=("$1"); shift ;;
  esac
done
case "$set_name" in fixed) tasks="$here/tasks.json" ;; holdout) tasks="$here/holdout.json" ;; *) echo 'usage: run.sh --tasks fixed|holdout [--self-test] [id ...]' >&2; exit 2 ;; esac

codex="$(readlink -f "${DITTO_CODEX_BINARY:-$HOME/.local/bin/codex}" 2>/dev/null || true)"
pin_sha="$(jq -r .sha256 "$WORKSPACE/tools/codex/pin.json")"
pin_version="$(jq -r .version "$WORKSPACE/tools/codex/pin.json")"
if [[ -z "$codex" || "$(sha256sum "$codex" | cut -d' ' -f1)" != "$pin_sha" ]]; then echo '{"ok":false,"not_run":"pinned Codex binary not installed"}'; exit 2; fi
"$WORKSPACE/target/debug/ditto-confine" --read /usr -- /usr/bin/true 2>/dev/null || { echo '{"ok":false,"not_run":"this kernel cannot confine the Codex backend"}'; exit 2; }
subscription="${DITTO_G2_SUBSCRIPTION_DIR:-$HOME/.cache/ditto-g2-subscription}"
if [[ "$mode" == model && ! -d "$subscription/store" ]]; then echo '{"ok":false,"not_run":"no subscription sign-in (run tests/g2/codex/subscription.mjs first)"}'; exit 2; fi

g1_begin "g2-semantic-$set_name-$mode" "G2 semantic $set_name ($mode, development)"
g1_preflight
evidence="$(g1_evidence_dir)"
cleanup() { shell_fixture_stop; }
trap cleanup EXIT INT TERM

export DITTO_COMPOSITOR=wayfire DITTO_REFERENCE_MACHINE=1
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
start_compositor >/dev/null
# The model run's Core uses the subscription's store, so Codex finds the
# sign-in the keyring holds for it; a self-test gets a store of its own.
[[ "$mode" == model ]] && export DITTO_DATA_DIR="$subscription/store"
if ! shell_fixture_start --hostd \
    --agent "agent 0.3.0 $(readlink -f "$(command -v node)") $WORKSPACE/packages/agent-runtime/dist/ditto-agentd.mjs" \
    --agent-backend "codex-app-server $pin_version $pin_sha $codex"; then
  cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
  check fixture fail "the desktop did not come up; log in $evidence/core.log"
  g1_finish
fi
WINDOW_PIDS=()
browser_id=firefox_firefox
if [[ "${DITTO_SEMANTIC_BROWSER:-firefox}" == chrome ]]; then
  # Development only: Firefox in the headless fixture keeps its own width
  # under any configure; Chrome stands in so layout tasks can be exercised.
  # Reference runs use Firefox, the frozen reference browser.
  REFERENCE_APP_ROLES=() REFERENCE_APP_IDS=() REFERENCE_APP_PIDS=()
  chrome_profile="$RUNTIME_DIR/semantic-chrome-$$"
  mkdir -p "$chrome_profile"
  google-chrome --user-data-dir="$chrome_profile" --ozone-platform=wayland --no-first-run --no-default-browser-check \
    --disable-gpu about:blank >"$RUNTIME_DIR/chrome-$$.log" 2>&1 &
  WINDOW_PIDS+=("$!")
  compositor_wait_for_window google-chrome 300 || { check browser fail "Chrome did not map"; g1_finish; }
  browser_id=google-chrome
  g1_note "development browser stand-in: Chrome (DITTO_SEMANTIC_BROWSER=chrome)"
  start_reference_app terminal
  start_reference_app editor
else
  start_all_reference_apps
fi
area="$(python3 - "$WAYFIRE_SOCKET" <<'PYEOF'
import json, socket, struct, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
body = json.dumps({"method": "window-rules/list-outputs", "data": {}}).encode()
s.sendall(struct.pack("<I", len(body)) + body)
n = struct.unpack("<I", s.recv(4))[0]; data = b""
while len(data) < n: data += s.recv(n - len(data))
out = json.loads(data)[0]; g, w = out["geometry"], out["workarea"]
print(json.dumps([w["x"] - g["x"], w["y"] - g["y"], w["width"], w["height"]]))
PYEOF
)"
export DITTO_SEMANTIC_MODE="$mode" DITTO_SEMANTIC_WORKAREA="$area" DITTO_SEMANTIC_RUN_ID="$(basename "$evidence")"
export DITTO_SEMANTIC_APPS="{\"foot\":\"ditto-ref-terminal\",\"firefox\":\"$browser_id\",\"org.kde.kate\":\"org.kde.kate\"}"
status=0
node "$here/driver.mjs" "$tasks" "$evidence/tasks" "${ids[@]}" >"$evidence/summary.line" 2>"$evidence/driver.log" || status=$?
cat "$evidence/driver.log" >&2
summary="$(cat "$evidence/summary.line")"
if (( status == 2 )); then
  check semantic environment "$(jq -r .not_run <<<"$summary")"
elif [[ -f "$evidence/tasks/summary.json" ]]; then
  passed="$(jq -r .passed "$evidence/tasks/summary.json")"; total="$(jq -r .total "$evidence/tasks/summary.json")"
  if [[ "$mode" == null ]]; then
    (( passed == 0 )) && check null-control pass "no task passes when nothing is done" "$summary" \
      || check null-control fail "$passed tasks pass with nothing done: their oracle is vacuous" "$summary"
  elif [[ "$mode" == self-test ]]; then
    # Every reference solution must satisfy its own task.
    (( passed == total )) && check self-test pass "$passed/$total reference solutions satisfy their oracle" "$summary" \
      || check self-test fail "$passed/$total reference solutions satisfy their oracle" "$summary"
  else
    # The score is recorded, not judged here: 45/50 and the holdout
    # comparison are decided in the exit review with the raw records.
    check semantic-score pass "$passed/$total tasks passed ($set_name, model)" "$summary"
  fi
else
  check semantic fail "the driver did not finish" "$(tail -5 "$evidence/driver.log")"
fi
cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
g1_finish
