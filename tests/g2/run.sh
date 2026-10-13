#!/usr/bin/env bash
# G2 suites on this machine, after a build (cargo build --workspace --bins,
# pnpm -r build, scripts/build-builtin-packages.sh, tools/dbus-proxy/build.sh).
#   bash tests/g2/run.sh            headless suites (fixture compositor)
#   bash tests/g2/run.sh desktop    plus the nested-Wayfire desktop suites
# Each suite's own output goes to artifacts/g2/run-<id>/<suite>.log; one
# line per suite in summary.jsonl. Exit 2 from a suite means it could not
# run here (environment) and is recorded as not_run, never as a pass.
# Development evidence only: exit decisions use the reference machine.
set -euo pipefail
workspace="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$workspace"
run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git rev-parse --short=4 HEAD)"
out="${DITTO_ARTIFACTS:-$workspace/artifacts/g2}/run-$run_id"
mkdir -p "$out"
label="${DITTO_ENVIRONMENT_LABEL:-development-host}"
record() { jq -cn --arg suite "$1" --arg status "$2" --arg label "$label" '{suite:$suite,status:$status,evidence_class:$label}' | tee -a "$out/summary.jsonl"; }
suite() {
  local name="$1" code=0; shift
  DITTO_ENVIRONMENT_LABEL="$label" "$@" >"$out/$name.log" 2>&1 || code=$?
  if (( code == 0 )); then record "$name" pass; elif (( code == 2 )); then record "$name" not_run; else record "$name" fail; fi
}
if [[ ! -x target/fault-injection/debug/ditto-core ]]; then
  cargo build --locked -q -p ditto-core -p ditto-confine --features ditto-core/fault-injection --target-dir target/fault-injection
fi
suite confine cargo test --locked -q -p ditto-confine
suite foundation node tests/g2/foundation/run.mjs
suite codex-run node tests/g2/codex/run.mjs
suite codex-faults node tests/g2/codex/faults.mjs
suite codex-crash node tests/g2/codex/crash.mjs
suite codex-injection node tests/g2/codex/injection.mjs
suite codex-races node tests/g2/codex/races.mjs
suite jobs node tests/g2/jobs/run.mjs
suite lifecycle node tests/g2/lifecycle/run.mjs quick
# The NFR-13 method measures the release build; a debug-only tree has none.
if [[ -x target/release/ditto-core ]]; then suite cold-start node tests/g2/measure/cold-start.mjs; else record cold-start not_run; fi
if [[ "${1:-}" == desktop ]]; then
  export DITTO_COMPOSITOR=wayfire
  suite layout timeout -k 15 1800 bash tests/g2/layout/run.sh
  suite codex-desktop timeout -k 15 1800 bash tests/g2/codex/desktop.sh
  suite shell timeout -k 15 1800 bash tests/g2/shell/run.sh
  # The semantic oracle itself (no model): reference solutions pass, the
  # null control fails. Chrome stands in for the browser where it exists.
  command -v google-chrome >/dev/null && export DITTO_SEMANTIC_BROWSER=chrome
  for set in fixed holdout; do
    suite "semantic-$set-self-test" timeout -k 15 3600 bash tests/g2/semantic/run.sh --tasks "$set" --self-test
    suite "semantic-$set-null" timeout -k 15 3600 bash tests/g2/semantic/run.sh --tasks "$set" --null
  done
fi
echo "G2 run: $out"
! jq -e 'select(.status == "fail")' "$out/summary.jsonl" >/dev/null
