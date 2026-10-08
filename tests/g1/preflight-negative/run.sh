#!/usr/bin/env bash
# EX1-02: install and enable are refused by preflight, before `validated`.
# The six negatives — a missing required dependency, a dependency cycle, an
# incompatible version, a single-provider conflict, a package hash mismatch,
# an incompatible required_protocol_version — must each leave:
#   ① the profile head revision unchanged;
#   ② the profile's content hash in the database unchanged;
#   ③ no new mount in hostd or the Shell (nothing reached a participant);
#   ④ a product-language explanation, with the contract id in diagnostics.
#
# The six run as Rust contract tests against a Core with test packages
# (they also block the merge in rust.yml). A second pass sends the negatives
# the built-in packages can express to a real ditto-core binary through
# dittoctl and reads head, hash and the stored change back. ④'s wording is
# the plugin center's, judged once on the reference machine by a person.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap g1_fixture_stop EXIT INT TERM

g1_begin preflight-negative "EX1-02"
g1_preflight
evidence="$(g1_evidence_dir)"

g1_cargo six-negatives "①②③ missing dependency, cycle, version, single provider, protocol: rejected, head/hash unchanged, no prepare reached the Shell" \
  -p ditto-core --lib -- --exact tests::preflight_refuses_every_problem_at_once_and_changes_nothing
g1_cargo hash-mismatch "①② a package changed after installation is integrity_mismatch" \
  -p ditto-core --lib -- --exact tests::a_tampered_package_is_an_integrity_mismatch
g1_cargo stale-base "a stale base is refused instead of overwriting the newer change" \
  -p ditto-core --lib -- --exact tests::a_stale_base_is_refused_instead_of_overwriting_the_newer_change

# The live pass: the real binary, its own store.
g1_fixture_core
read -r head digest < <(g1_head)
live() {
  local id="$1" code="$2" ops="$3"
  local record
  record="$(g1_call desktop.changes.propose "{\"base_revision\":\"$head\",\"ops\":$ops}" 2>/dev/null || true)"
  echo "$record" >"$evidence/$id.json"
  local change_id
  change_id="$(python3 -c 'import json, sys
try: record = json.loads(sys.argv[1])
except ValueError: raise SystemExit
print(((record.get("error") or {}).get("data") or {}).get("change_id") or "")' "$record")"
  local stored=""
  [[ -n "$change_id" ]] && stored="$(g1_call desktop.changes.get "{\"change_id\":\"$change_id\"}" 2>/dev/null || true)"
  echo "$stored" >"$evidence/$id.stored.json"
  local after_head after_digest
  read -r after_head after_digest < <(g1_head)
  python3 - "$record" "$stored" "$code" "$head" "$after_head" "$digest" "$after_digest" <<'PYEOF'
import json, sys
record, stored, code, head, after_head, digest, after_digest = sys.argv[1:8]
problems = []
try:
    error = json.loads(record).get("error") or {}
except ValueError:
    error = {}
if error.get("name") != "preflight_rejected":
    problems.append(f"answer was {error.get('name') or 'not an error'}")
codes = [reason.get("code") for reason in (error.get("data") or {}).get("reasons", [])]
if code not in codes:
    problems.append(f"reasons {codes} lack {code}")
if any(not reason.get("detail_key") for reason in (error.get("data") or {}).get("reasons", [])):
    problems.append("a reason has no detail_key for the product text")
try:
    state = (json.loads(stored).get("result") or {}).get("state")
except ValueError:
    state = None
if state != "rejected":
    problems.append(f"stored change is {state}, not rejected")
if head != after_head:
    problems.append("head moved")
if digest != after_digest:
    problems.append("content hash changed")
print("; ".join(problems) or "ok")
PYEOF
}
for spec in \
  'package-missing|package_missing|[{"op":"add_entry","entry":{"package":"ditto.nowhere","version":"1.0.0","host":"qml"}}]' \
  'single-provider|single_provider_violation|[{"op":"add_entry","entry":{"package":"ditto.dock.pill","version":"1.1.0","host":"qml"},"slot":"svc.tasks"}]'; do
  IFS='|' read -r id code ops <<<"$spec"
  verdict="$(live "$id" "$code" "$ops")"
  if [[ "$verdict" == ok ]]; then
    check "live-$id" pass "real binary: $code rejected before validated; stored as rejected; head and hash unchanged" "{\"record\": \"$evidence/$id.json\"}"
  else
    check "live-$id" fail "real binary, $code: $verdict" "{\"record\": \"$evidence/$id.json\"}"
  fi
done
g1_fixture_stop

check product-language operator "④ each negative once through the plugin center on the reference machine: product text plus the contract id under diagnostics (plan/03/06 §8)"

g1_finish
