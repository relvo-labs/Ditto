#!/usr/bin/env bash
# EX1-03: rollback holds, and what cannot be rolled back is listed.
#   ① undo one cross-plugin change (Dock + launcher in one ChangeSet) → the
#     base revision's content, read back;
#   ② a candidate fails its health check → aborted, the active one untouched;
#   ③ undo a layout change after one of its windows closed → partially
#     applied, every item not restored listed with its reason;
#   plus the policy: undoing an older change that a newer one touched is
#   refused ("undo the newer change first").
#
# Each scenario is a Rust test against Core with fake participants that
# follow the participant protocol. Besides the run document this writes
# artifacts/g1/rollback-<run_id>.jsonl, one line per scenario with its
# outcome class, as plan/03/01 asks.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

g1_begin rollback "EX1-03"
g1_preflight

lib=(-p ditto-core --lib -- --exact)
g1_cargo cross-plugin-undo "① Dock + launcher in one ChangeSet, undone: the base content hash and the Shell's mounts are back" \
  "${lib[@]}" tests::undoing_a_cross_plugin_change_returns_to_the_base_content
g1_cargo candidate-health-failure "② a candidate that fails to load aborts the change; the active Dock stays mounted" \
  "${lib[@]}" tests::a_dock_swap_is_a_transaction_and_a_broken_candidate_leaves_the_active_dock
g1_cargo readback-mismatch "a participant that reports done but reads back otherwise is rolled back" \
  "${lib[@]}" tests::a_readback_that_disagrees_rolls_the_change_back
g1_cargo partially-applied "③ a rollback that cannot restore an item ends partially_applied and lists it with its reason" \
  "${lib[@]}" tests::a_rollback_that_cannot_restore_an_item_is_partially_applied
g1_cargo undo-policy "undoing an older change that a newer one touched is refused; an unrelated newer change does not block" \
  "${lib[@]}" tests::undoing_an_older_change_that_a_newer_one_touched_is_refused
g1_cargo layout-window-closed "③ a layout change undone after one of its windows closed: committed with result partial, the closed window listed as window_closed, the open one back where it floated" \
  "${lib[@]}" tests::undoing_a_layout_change_after_a_window_closed_is_partial

python3 - "$G1_CHECKS" "$ARTIFACTS/rollback-$RUN_ID.jsonl" <<'PYEOF'
import json, sys
classes = {
    "cross-plugin-undo": "committed (undo)",
    "candidate-health-failure": "aborted",
    "readback-mismatch": "rolled_back",
    "partially-applied": "partially_applied",
    "undo-policy": "refused: undo_blocked_by_newer_change",
    "layout-window-closed": "committed, result partial (window_closed listed)",
}
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for line in open(sys.argv[1], encoding="utf-8"):
        check = json.loads(line)
        out.write(json.dumps({"scenario": check["id"], "status": check["status"],
                              "outcome_class": classes.get(check["id"]),
                              "detail": check["detail"]}, ensure_ascii=False) + "\n")
PYEOF
g1_note "per-scenario outcome classes: $ARTIFACTS/rollback-$RUN_ID.jsonl"

g1_finish
