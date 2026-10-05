#!/usr/bin/env bash
# EX1-08: lifecycle contract tests L-01…L-10 (plan/03/06 §3). Each item passes
# only with both its positive case and its fault-injection negative.
#
#   L-01 L-02 L-03 L-04 L-08  Vitest, packages/host-runtime/tests/lifecycle/
#                             (createTestHost() and the fault layer). L-02 and
#                             L-03 also have a Rust half in ditto-core's unit
#                             tests (fake participants).
#   L-05 L-06 L-07 L-09 L-10  Rust integration tests against the real binaries
#                             (crates/ditto-core/tests/lifecycle.rs): Core in
#                             normal mode on the fixture compositor, the real
#                             hostd (fault-injection bundle) under Core's
#                             supervision, the built-in tasks service, and the
#                             Agent stand-in for L-10, all started by Core's
#                             launcher. L-05/L-06 time the unavailability
#                             (≤ 500 ms, EX1-08); the measured values are kept
#                             in the notes and the per-check logs.
#
# Needs: node and pnpm on PATH, the workspace dependencies installed, and the
# built-in packages (scripts/build-builtin-packages.sh). The hostd test bundle
# is rebuilt here so it always matches the source under test.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

g1_begin lifecycle "EX1-08 L-01～L-10"
g1_preflight
evidence="$(g1_evidence_dir)"

# vitest_check <check-id> <criterion> <test file>: the file must run at least
# two tests (positive and negative), none skipped, none failed.
vitest_check() {
  local id="$1" criterion="$2" file="$3" log status=0
  log="$evidence/$id.log"
  # Counts come from Vitest's JSON report, not from its console summary,
  # whose colouring depends on the environment (it read 0 tests on CI).
  local report="$evidence/$id.vitest.json"
  rm -f -- "$report"
  (cd "$WORKSPACE" && pnpm --filter @ditto/host-runtime exec vitest run --reporter=verbose --reporter=json \
    --outputFile.json="$report" "$file") >"$log" 2>&1 || status=$?
  local passed skipped failed
  read -r passed skipped failed < <(python3 - "$report" <<'PYEOF' 2>/dev/null || echo "0 0 0"
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    print("0 0 0"); raise SystemExit
print(data.get("numPassedTests", 0), data.get("numPendingTests", 0) + data.get("numTodoTests", 0), data.get("numFailedTests", 0))
PYEOF
)
  local evidence_json
  evidence_json="$(python3 -c 'import json, sys; print(json.dumps({"log": sys.argv[1], "exit": int(sys.argv[2]), "passed": int(sys.argv[3] or 0), "skipped": int(sys.argv[4] or 0), "failed": int(sys.argv[5] or 0), "file": sys.argv[6]}))' \
    "$log" "$status" "${passed:-0}" "${skipped:-0}" "${failed:-0}" "$file")"
  if [[ "$status" -eq 0 && "${passed:-0}" -ge 2 && "${skipped:-0}" -eq 0 ]]; then
    check "$id" pass "$criterion" "$evidence_json"
  elif [[ "$status" -eq 0 ]]; then
    check "$id" fail "$criterion: ${passed:-0} passed, ${skipped:-0} skipped (a positive and a negative must both run)" "$evidence_json"
  else
    check "$id" fail "$criterion: vitest failed" "$evidence_json"
  fi
}

# measured <check-id>: keep the "L-xx measured: …" lines of a Rust check.
measured() {
  local line
  while IFS= read -r line; do
    g1_note "$1: ${line#*measured: }"
  done < <(grep -Eo 'L-[0-9]+ measured: .*' "$evidence/$1.log" 2>/dev/null || true)
}

missing=()
command -v node >/dev/null || missing+=(node)
command -v pnpm >/dev/null || missing+=(pnpm)
if [[ ${#missing[@]} -gt 0 ]]; then
  for id in L-01 L-02 L-03 L-04 L-05 L-06 L-07 L-08 L-09 L-10; do
    check "$id" environment "${missing[*]} not on PATH"
  done
  g1_finish
fi

# ---- TS half -----------------------------------------------------------------------
lifecycle=tests/lifecycle
vitest_check L-01 "dependency loss: consumer PENDING and revoked, back to ACTIVE; a throwing disposer is isolated" \
  "$lifecycle/l01-dependency-loss.test.ts"
vitest_check L-02 "service replacement: consumers move to B with no fiber of A left; B failing in apply aborts and A keeps serving" \
  "$lifecycle/l02-service-replacement.test.ts"
vitest_check L-03 "duplicate registration: one binding before and after commit; a candidate's claim is conflict(candidate_cannot_claim)" \
  "$lifecycle/l03-duplicate-registration.test.ts"
vitest_check L-04 "context disposal: 100 mount/unmount cycles keep every count; a 2 s async disposer delays the next mount, never two instances" \
  "$lifecycle/l04-context-disposal.test.ts"
vitest_check L-08 "async disposer: the next mount waits; a disposer that never finishes faults the entry and the mount is refused" \
  "$lifecycle/l08-async-disposer.test.ts"
g1_cargo L-02-rust "L-02 Rust half: a replacement is a transaction and a broken candidate leaves the active provider" \
  -p ditto-core --lib -- --exact tests::a_dock_swap_is_a_transaction_and_a_broken_candidate_leaves_the_active_dock
g1_cargo L-03-rust "L-03 Rust half: a candidate's registration during prepare is conflict(candidate_cannot_claim); one binding after commit" \
  -p ditto-core --lib -- --exact tests::a_candidate_cannot_claim_before_commit

# ---- Rust half (real Core, real hostd) ---------------------------------------------
build_log="$evidence/hostd-fault-build.log"
if ! (cd "$WORKSPACE" && DITTO_HOST_FAULT_ENABLE=1 pnpm --filter @ditto/host-runtime build) >"$build_log" 2>&1; then
  for id in L-05 L-06 L-07 L-09 L-10; do
    check "$id" fail "the hostd fault-injection bundle did not build" "{\"log\": \"$build_log\"}"
  done
  g1_finish
fi
packages="${DITTO_BUILTIN_PACKAGES:-$WORKSPACE/target/ditto-packages}"
if [[ ! -f "$packages/ditto.svc.tasks-1.0.0.dittopkg" ]]; then
  for id in L-05 L-06 L-07 L-09 L-10; do
    check "$id" fail "build first: $packages/ditto.svc.tasks-1.0.0.dittopkg (scripts/build-builtin-packages.sh)"
  done
  g1_finish
fi

rust=(-p ditto-core --features fault-injection --test lifecycle)
g1_cargo L-05 "hostd SIGKILLed after prepare: aborted, unavailable within 500 ms, compositor answers; a concurrent call answers unavailable" \
  "${rust[@]}" -- --exact l05_hostd_killed_after_prepare_aborts_and_unbinds_within_500_ms --nocapture
measured L-05
g1_cargo L-06 "hostd SIGKILLed during hand-over: failed or partial with every item; no side effect replayed; the restarted hostd does not know the change and the readback decides" \
  "${rust[@]}" -- --exact l06_hostd_killed_during_handoff_lists_items_and_replays_nothing --nocapture
measured L-06
g1_cargo L-07 "renewal stopped (SIGSTOP 10 s): bindings revoked, calls refused, a new generation registers; old-generation lease ids are refused" \
  "${rust[@]}" -- --exact l07_stopped_renewal_revokes_bindings_and_old_leases_stay_dead --nocapture
measured L-07
g1_cargo L-09 "a plan on a stale base is rejected (base_revision_stale) and the manual edit stays; two changes at once are strictly serialized" \
  "${rust[@]}" -- l09_ --nocapture
g1_cargo L-10 "Agent stand-in killed before acceptance: nothing runs; after: Core finishes and a new stand-in finds it; the same idempotency key makes no second change" \
  "${rust[@]}" -- --exact l10_a_client_killed_before_or_after_acceptance --nocapture

g1_note "L-05 and L-06 run against the fixture compositor and a Core in normal mode, not a logged-in session"
g1_finish
