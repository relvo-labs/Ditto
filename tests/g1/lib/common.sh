#!/usr/bin/env bash
# Shared helpers for the G1 gate runners. They reuse the G0 fixture helpers
# (headless compositor, development Core, run_id, environment label) and add
# the G1 bookkeeping: one JSON document per run at
# artifacts/g1/<name>-<run_id>.json, one entry per sub-check, and an overall
# status that can only be "pass" when every sub-check ran and passed.
#
# Sub-check statuses:
#   pass              ran, and the observed state met the criterion
#   fail              ran, and it did not
#   not_implemented   a Core/Shell/hostd feature it needs does not exist yet
#   environment       the environment cannot run it (no second monitor, no
#                     logged-in Ditto session, not the reference machine, ...)
#   operator          needs a person (physical unplug, recording); pending
# Exit codes: 0 pass, 1 fail, 3 anything else (never counted as a pass).
set -euo pipefail

G1_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DITTO_ARTIFACTS="${DITTO_ARTIFACTS:-$(cd "$G1_ROOT/../.." && pwd)/artifacts/g1}"
# shellcheck source=../../g0/lib/session.sh
source "$G1_ROOT/../g0/lib/session.sh"

G1_CHECKS=""
g1_begin() {
  G1_NAME="$1"
  G1_GATE="$2"
  RUN_ID="$(run_id)"
  mkdir -p "$ARTIFACTS"
  OUTPUT="$ARTIFACTS/$G1_NAME-$RUN_ID.json"
  G1_CHECKS="$(mktemp "${TMPDIR:-/tmp}/ditto-g1-checks.XXXXXX")"
  G1_FINGERPRINT=""
  G1_NOTES=()
}

# Reference-machine runs must pass the frozen-platform preflight; every run
# keeps a fingerprint beside its result so machines are never mixed.
g1_preflight() {
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    bash "$WORKSPACE/packaging/reference-image/preflight.sh" >&2
  fi
  local fingerprint="$ARTIFACTS/$G1_NAME-$RUN_ID.fingerprint.json"
  if bash "$WORKSPACE/packaging/reference-image/capture-fingerprint.sh" "$fingerprint" >/dev/null 2>&1; then
    G1_FINGERPRINT="$fingerprint"
  else
    G1_NOTES+=("platform fingerprint could not be captured (capture-fingerprint.sh failed)")
  fi
}

g1_note() { G1_NOTES+=("$*"); }

# check <id> <status> <detail> [evidence-json]
check() {
  python3 - "$G1_CHECKS" "$1" "$2" "$3" "${4:-null}" <<'PYEOF'
import json, sys
path, check_id, status, detail, evidence = sys.argv[1:6]
allowed = {"pass", "fail", "not_implemented", "environment", "operator"}
if status not in allowed:
    raise SystemExit(f"unknown check status {status}")
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps({"id": check_id, "status": status, "detail": detail,
                             "evidence": json.loads(evidence)}, ensure_ascii=False) + "\n")
PYEOF
  printf '%-28s %-16s %s\n' "$1" "$2" "$3" >&2
}

# Capabilities a running Core serves, one per line with its availability:
#   <capability_id> <available|unavailable>
# Empty when Core is unreachable, which callers treat as not implemented.
g1_capabilities() {
  "$BINARIES/dittoctl" --json probe capabilities 2>/dev/null | python3 -c '
import json, sys
try:
    record = json.loads(sys.stdin.read() or "{}")
except ValueError:
    raise SystemExit(0)
for capability in (record.get("result") or {}).get("capabilities", []):
    availability = capability.get("availability") or {}
    available = availability.get("kind") == "always" or availability.get("available") is True
    print(capability.get("capability_id"), "available" if available else "unavailable")
' || true
}

# has_capability <listing> <id>: served and available.
has_capability() {
  grep -qx "$2 available" <<<"$1"
}

# missing_capabilities <listing> <id>...: the ids not served or unavailable.
missing_capabilities() {
  local listing="$1" missing=() id
  shift
  for id in "$@"; do has_capability "$listing" "$id" || missing+=("$id"); done
  echo "${missing[*]:-}"
}

# Write the run document and exit with its status.
g1_finish() {
  local notes_json
  notes_json="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:], ensure_ascii=False))' "${G1_NOTES[@]:-}")"
  set +e
  python3 - "$OUTPUT" "$G1_CHECKS" "$RUN_ID" "$G1_NAME" "$G1_GATE" "$(environment_label)" \
    "$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo unknown)" \
    "$(git -C "$WORKSPACE" status --porcelain 2>/dev/null | wc -l)" "$G1_FINGERPRINT" "$notes_json" <<'PYEOF'
import json, sys
output, checks_path, run_id, name, gate, environment, commit, dirty, fingerprint, notes = sys.argv[1:11]
checks = [json.loads(line) for line in open(checks_path, encoding="utf-8") if line.strip()]
statuses = {check["status"] for check in checks}
# An empty result is never a pass.
if not checks:
    overall = "not_implemented"
elif statuses == {"pass"}:
    overall = "pass"
elif "fail" in statuses:
    overall = "fail"
elif "not_implemented" in statuses:
    overall = "not_implemented"
else:
    overall = "incomplete"
record = {
    "run_id": run_id,
    "runner": f"tests/g1/{name}/run.sh",
    "gate": gate,
    "environment": environment,
    "evidence_class": "reference-machine" if environment == "reference-machine" else "development",
    "commit": commit,
    "uncommitted_paths": int(dirty),
    "fingerprint": fingerprint or None,
    "status": overall,
    "checks": checks,
    "notes": [note for note in json.loads(notes) if note],
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=False, indent=2)
counts = {status: sum(1 for c in checks if c["status"] == status) for status in sorted(statuses)}
print(f"{gate}: {overall} {counts} -> {output}")
if record["evidence_class"] != "reference-machine":
    print("development evidence only; the gate is decided on the reference machine")
raise SystemExit({"pass": 0, "fail": 1}.get(overall, 3))
PYEOF
  local status=$?
  rm -f -- "$G1_CHECKS"
  exit "$status"
}

# A generic capability call. G0's dittoctl only has fixed probe commands; the
# G1 runners need `dittoctl probe call <capability_id> <params-json>` (printing
# the same JSON record as the other probe commands with --json). Until it
# exists, every step that calls a capability is not_implemented.
g1_can_call() {
  "$BINARIES/dittoctl" --json probe call desktop.capabilities.list '{}' >/dev/null 2>&1
}

g1_call() {
  "$BINARIES/dittoctl" --json probe call "$1" "${2:-{\}}"
}

# Fraction of screen pixels with exactly this colour (rrggbb), from grim.
# Prints "error: ..." when no screenshot can be taken.
screen_fraction() {
  local colour="$1" png="${2:-}"
  grim -t ppm - 2>/dev/null | python3 -c '
import re, sys
data = sys.stdin.buffer.read()
header = re.match(rb"P6\s+(\d+)\s+(\d+)\s+\d+\s", data)
if not header:
    print("error: no screenshot"); raise SystemExit(0)
width, height, pixels = int(header[1]), int(header[2]), data[header.end():]
target = bytes.fromhex(sys.argv[1])
step = 3 * 5
hits = sum(1 for i in range(0, width * height * 3, step) if pixels[i:i + 3] == target)
print(round(hits / max(1, len(range(0, width * height * 3, step))), 5))
' "$colour"
  if [[ -n "$png" ]]; then grim "$png" 2>/dev/null || true; fi
}

# PIDs of a user scope, never of the root cgroup.
scope_pids() {
  local group
  group="$(systemctl --user show -p ControlGroup --value "$1" 2>/dev/null || true)"
  [[ "$group" == /*.scope && -r "/sys/fs/cgroup$group/cgroup.procs" ]] && cat "/sys/fs/cgroup$group/cgroup.procs"
  return 0
}

in_ditto_session() {
  systemctl --user is-active --quiet ditto-session.target 2>/dev/null
}

# g1_evidence_dir: one directory of raw evidence per run, beside the result.
g1_evidence_dir() {
  local directory="$ARTIFACTS/$G1_NAME-$RUN_ID.d"
  mkdir -p "$directory"
  echo "$directory"
}

# g1_cargo <check-id> <criterion> <cargo test args...>
# One Rust test (or filter) as one sub-check, its full log kept as evidence.
# A filter that runs no test is a fail, never a pass.
g1_cargo() {
  local id="$1" criterion="$2" log
  shift 2
  log="$(g1_evidence_dir)/$id.log"
  local status=0
  (cd "$WORKSPACE" && cargo test --locked "$@") >"$log" 2>&1 || status=$?
  local passed failed
  passed="$(grep -Eo '[0-9]+ passed' "$log" | awk '{s += $1} END {print s + 0}')"
  failed="$(grep -Eo '[0-9]+ failed' "$log" | awk '{s += $1} END {print s + 0}')"
  local evidence
  evidence="$(python3 -c 'import json, sys; print(json.dumps({"log": sys.argv[1], "passed": int(sys.argv[2]), "failed": int(sys.argv[3]), "command": sys.argv[4]}))' \
    "$log" "$passed" "$failed" "cargo test --locked $*")"
  if [[ "$status" -eq 0 && "$passed" -gt 0 ]]; then
    check "$id" pass "$criterion" "$evidence"
  elif [[ "$status" -eq 0 ]]; then
    check "$id" fail "$criterion: the filter matched no test" "$evidence"
  else
    check "$id" fail "$criterion: cargo test failed" "$evidence"
  fi
}

# g1_fixture_core [extra serve args...]: a development Core on the fixture
# compositor, with its own runtime directory and store, never the session's.
# Sets FIXTURE_ROOT, CORE_PID and exports DITTO_RUNTIME_DIR, DITTO_DATA_DIR,
# DITTO_DEV_TOKEN. The root is short: a socket path must fit in sun_path.
g1_fixture_core() {
  FIXTURE_ROOT="${FIXTURE_ROOT:-$(mktemp -d /tmp/ditto-g1.XXXXXX)}"
  export DITTO_RUNTIME_DIR="$FIXTURE_ROOT/run"
  export DITTO_DATA_DIR="${DITTO_DATA_DIR_OVERRIDE:-$FIXTURE_ROOT/store}"
  export DITTO_DEV_TOKEN="${DITTO_DEV_TOKEN:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
  export DITTO_SYSTEM=none WAYFIRE_SOCKET='' SWAYSOCK=''
  "$BINARIES/ditto-core" serve --development --compositor fixture "$@" >>"$FIXTURE_ROOT/core.log" 2>&1 &
  CORE_PID=$!
  local _
  for _ in $(seq 1 100); do
    [[ -S "$DITTO_RUNTIME_DIR/core.sock" ]] && return 0
    kill -0 "$CORE_PID" 2>/dev/null || break
    sleep 0.1
  done
  echo "fixture Core did not bind its socket; see $FIXTURE_ROOT/core.log" >&2
  return 1
}

g1_fixture_stop() {
  if [[ -n "${CORE_PID:-}" ]]; then kill "$CORE_PID" 2>/dev/null || true; wait "$CORE_PID" 2>/dev/null || true; fi
  CORE_PID=""
  if [[ "${FIXTURE_ROOT:-}" == /tmp/ditto-g1.* && -d "$FIXTURE_ROOT" ]]; then
    # Installed packages are read-only by design (the store's integrity rule).
    chmod -R u+w -- "$FIXTURE_ROOT" 2>/dev/null || true
    rm -rf -- "$FIXTURE_ROOT"
  fi
  return 0
}

# g1_head: "<head_revision> <document_sha256>" of the active profile.
g1_head() {
  g1_call desktop.profiles.get '{}' | python3 -c '
import json, sys
record = json.load(sys.stdin)
result = record.get("result") or {}
print(result.get("profile", {}).get("head_revision"), result.get("revision", {}).get("document_sha256"))'
}

# g1_run <check-id> <criterion> <command...>: any test command as one
# sub-check, pass when it exits 0; the output is kept as evidence.
g1_run() {
  local id="$1" criterion="$2" log status=0
  shift 2
  log="$(g1_evidence_dir)/$id.log"
  (cd "$WORKSPACE" && "$@") >"$log" 2>&1 || status=$?
  local evidence
  evidence="$(python3 -c 'import json, sys; print(json.dumps({"log": sys.argv[1], "exit": int(sys.argv[2]), "command": sys.argv[3]}))' "$log" "$status" "$*")"
  if [[ "$status" -eq 0 ]]; then
    check "$id" pass "$criterion" "$evidence"
  else
    check "$id" fail "$criterion: exit $status" "$evidence"
  fi
}
