#!/usr/bin/env bash
# EX1-09: a persistence fault never damages the last known good version.
#   ① SIGKILL Core in prepared, applying and verifying → after the restart
#     desktop.changes.get finds the change and it is decided (committed,
#     rolled_back, partially_applied or unknown), never left in between.
#   ② the filesystem holding the database is full during a change → storage
#     is reported, the head's and the protected revision's hashes are intact.
#   ③ SQLITE_IOERR at commit → as ②.
#   ④ a package install fails half way through unpacking → no staging
#     directory and no half package in the store.
#
# ①–④ run against the real ditto-core binary built with the fault-injection
# feature (crates/ditto-core/tests/persistence_faults.rs). ② additionally has
# a variant on a real capacity-limited filesystem: mounting one needs root,
# so it only runs when DITTO_G1_SMALL_FS names a writable, already mounted,
# small filesystem (for example `sudo mount -t tmpfs -o size=8m,uid=$UID tmpfs
# /mnt/ditto-small`); otherwise it is recorded as environment.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap g1_fixture_stop EXIT INT TERM

g1_begin persistence-faults "EX1-09 ①②③④"
g1_preflight

features=(-p ditto-core --features fault-injection --test persistence_faults)
g1_cargo crash-in-each-state "① SIGKILL in prepared/applying/verifying; each change is decided after the restart" \
  "${features[@]}" -- --exact a_crash_in_each_state_ends_in_a_decided_outcome
g1_cargo full-and-ioerr-at-commit "②③ SQLITE_FULL and SQLITE_IOERR at commit leave the head and last good unchanged" \
  "${features[@]}" -- --exact a_full_disk_or_an_io_error_at_commit_leaves_the_head_and_last_good
g1_cargo unpack-failure "④ a failed unpack leaves no staging directory and no half package" \
  "${features[@]}" -- --exact a_failed_unpack_leaves_no_half_package
g1_cargo store-transactions "the store's own transaction, trigger and lock tests" -p ditto-store

# ② on a real full filesystem, with the release-shaped binary (no injection).
small="${DITTO_G1_SMALL_FS:-}"
if [[ -z "$small" ]]; then
  check real-full-filesystem environment "no small filesystem given (DITTO_G1_SMALL_FS); mounting one needs root"
elif [[ ! -d "$small" || ! -w "$small" ]]; then
  check real-full-filesystem environment "DITTO_G1_SMALL_FS=$small is not a writable directory"
else
  evidence="$(g1_evidence_dir)"
  store="$small/ditto-g1-$RUN_ID"
  rm -rf -- "$store"
  DITTO_DATA_DIR_OVERRIDE="$store" g1_fixture_core
  read -r head_before digest_before < <(g1_head)
  df -B1 "$store" >"$evidence/full-filesystem-before.txt"
  # Fill what is left, keeping nothing back for SQLite.
  dd if=/dev/zero of="$store/filler" bs=64k status=none 2>/dev/null || true
  sync
  df -B1 "$store" >"$evidence/full-filesystem-filled.txt"
  operation_id="g1-full-$RUN_ID"
  record="$("$BINARIES/dittoctl" --json probe call --operation-id "$operation_id" desktop.changes.propose "{\"base_revision\":\"$head_before\",\"ops\":[{\"op\":\"set_value\",\"path\":\"/avatar/hidden\",\"after\":true}]}" 2>/dev/null || true)"
  echo "$record" >"$evidence/full-propose.json"
  rm -f -- "$store/filler"
  sync
  g1_call desktop.changes.get "{\"operation_id\":\"$operation_id\"}" >"$evidence/full-operation-after-free.json" 2>&1 || true
  read -r head_after digest_after < <(g1_head)
  cp "$FIXTURE_ROOT/core.log" "$evidence/full-core.log"
  verdict="$(python3 - "$record" <<'PYEOF'
import json, sys
try:
    record = json.loads(sys.argv[1])
except ValueError:
    print("no-answer"); raise SystemExit
# Three honest answers to "the disk is full", from earliest to latest: the
# draft could not be written (unavailable/storage_full), preflight saw too
# little space (precondition_failed/storage_low), or the commit write failed
# and the change was rolled back (failure_key change.storage_full).
error = record.get("error") or {}
data = error.get("data") or {}
reasons = [r.get("detail", {}).get("why") for r in data.get("reasons", []) if isinstance(r, dict)]
result = record.get("result") or {}
if data.get("reason") == "storage_full" or "storage_low" in reasons or result.get("failure_key") == "change.storage_full":
    print("storage_full")
else:
    print(data.get("reason") or error.get("name") or result.get("state") or "no-answer")
PYEOF
)"
  detail="propose on a full filesystem answered $verdict; head $head_before → $head_after"
  if [[ "$verdict" == storage_full && "$head_before" == "$head_after" && "$digest_before" == "$digest_after" ]]; then
    check real-full-filesystem pass "$detail; content hash unchanged" "{\"record\": \"$evidence/full-propose.json\"}"
  else
    check real-full-filesystem fail "$detail (expected storage_full and an unchanged head and hash)" "{\"record\": \"$evidence/full-propose.json\"}"
  fi
  g1_fixture_stop
  rm -rf -- "$store"
fi

g1_finish
