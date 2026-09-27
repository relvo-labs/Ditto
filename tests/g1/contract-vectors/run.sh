#!/usr/bin/env bash
# EX1-06: the cross-language contract.
#   ① the shared protocol 0.2 vectors decode and encode alike in Rust and TS;
#   ② a 0.1 client is refused (protocol_version_unsupported);
#   ③ an out-of-order event is detected and forces a fresh subscription;
#   ④ after a reconnect the client rebuilds from a snapshot, and the same
#     operation_id is never committed twice;
#   ⑤ hostd's on_behalf_of naming an entry not assigned to it is refused
#     (identity_rejected);
#   ⑥ the catalog gate passes on every capability.
# Plus the identity path the Agent stand-in (G1-QA-07) exercises: launched by
# Core it is admitted as `agent`; the same program without the launcher's
# token is refused.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap g1_fixture_stop EXIT INT TERM

g1_begin contract-vectors "EX1-06"
g1_preflight
evidence="$(g1_evidence_dir)"

g1_cargo vectors-rust "① shape and scenario vectors in Rust" -p ditto-core --lib -- tests::contract_vectors
g1_run vectors-ts "① the same vectors, judged by the Rust schemas and run against the Rust Core from TS" \
  pnpm --filter @ditto/protocol test
g1_cargo protocol-0-1-refused "② 0.1 clients and unknown kinds are refused" \
  -p ditto-core --lib -- --exact tests::protocol_0_1_clients_and_unknown_kinds_are_refused
g1_cargo gap-rust "③ Core requires a resync after a gap" \
  -p ditto-core --lib -- events::tests::replays_retained_events_and_requires_resync_after_gap
g1_cargo operation-id-after-reconnect "④ an operation_id finds its change after a lost connection; nothing is submitted twice" \
  -p ditto-core --lib -- --exact tests::a_client_operation_id_finds_its_change_after_a_lost_connection
g1_cargo idempotency "④ the same idempotency key returns the first change" \
  -p ditto-core --lib -- --exact tests::the_same_idempotency_key_returns_the_first_change
g1_cargo on-behalf-of-forged "⑤ hostd naming an entry it was not assigned, and a non-hostd naming any entry, are identity_rejected" \
  -p ditto-core --lib -- --exact tests::a_service_is_leased_forwarded_and_read_back_by_core
g1_cargo catalog-gate "⑥ every catalog entry has a handler, a consumer, closed errors and a known scope" \
  -p ditto-core --lib -- --exact tests::every_catalog_entry_has_a_handler_and_a_consumer
g1_cargo catalog-rules "⑥ scopes are non-empty and configuration writes go through ChangeSets" -p ditto-protocol catalog::

# The stand-in's identity path, with the real binaries.
standin="$WORKSPACE/tests/g1/fixtures/agent-standin/standin.mjs"
node="$(command -v node || true)"
if [[ -z "$node" ]]; then
  check standin-launched environment "node is not on PATH"
else
  FIXTURE_ROOT="$(mktemp -d /tmp/ditto-g1.XXXXXX)"
  export DITTO_RUNTIME_DIR="$FIXTURE_ROOT/run" DITTO_DATA_DIR="$FIXTURE_ROOT/store" DITTO_SYSTEM=none WAYFIRE_SOCKET='' SWAYSOCK=''
  unset DITTO_DEV_TOKEN
  "$BINARIES/ditto-core" serve --compositor fixture \
    --launch "agent 0.2.0 $node $standin get op-g1-identity" >"$FIXTURE_ROOT/core.log" 2>&1 &
  CORE_PID=$!
  for _ in $(seq 1 50); do
    grep -q '"id":"standin-' "$FIXTURE_ROOT/core.log" 2>/dev/null && break
    sleep 0.1
  done
  # Without the launcher: the same program with a made-up token. Core, not
  # the client, must be the one that refuses.
  refused="$(DITTO_CORE_SOCKET="$DITTO_RUNTIME_DIR/core.sock" DITTO_DEV_TOKEN=forged-g1-token "$node" "$standin" get op-g1-identity 2>&1 || true)"
  cp "$FIXTURE_ROOT/core.log" "$evidence/standin-core.log"
  printf '%s\n' "$refused" >"$evidence/standin-without-launcher.txt"
  if grep -q '"event":"connection.open","kind":"agent"' "$FIXTURE_ROOT/core.log" \
    && grep -q '"id":"standin-2","error":{"code":-32002,"name":"not_found"' "$FIXTURE_ROOT/core.log"; then
    check standin-launched pass "launched by Core, the stand-in is admitted as agent and its lookup reaches desktop.changes.get" "{\"log\": \"$evidence/standin-core.log\"}"
  else
    check standin-launched fail "the launched stand-in did not complete a handshake and a lookup (core.log saved)" "{\"log\": \"$evidence/standin-core.log\"}"
  fi
  if grep -q 'handshake refused: identity_rejected' <<<"$refused"; then
    check standin-without-launcher pass "the same program outside the launcher, with a forged token, is refused by Core (identity_rejected)" "{\"output\": \"$evidence/standin-without-launcher.txt\"}"
  else
    check standin-without-launcher fail "the stand-in connected without a launcher token" "{\"output\": \"$evidence/standin-without-launcher.txt\"}"
  fi
  g1_fixture_stop
fi

g1_finish
