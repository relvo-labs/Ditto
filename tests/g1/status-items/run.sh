#!/usr/bin/env bash
# D-34: the five QML status items mount side by side in the real Shell.
#   ① keyboard-enable  the plugin center enables the clock (Tab, Enter)
#   ② five-mounted     the other four in one ChangeSet; five rows in
#                      desktop.panels.list (slot ui.status_item, mounted,
#                      visible, Profile order) and five items in the top panel
#   ③ one-disabled     the CPU item turned off; four remain, in order
#   ④ broken-aborts    a candidate whose QML does not load aborts the change
#                      and leaves the mounted items as they were
#   strip-fallback     with the top panel removed the items move to the
#                      Shell's own strip (still mounted and visible); undo
#                      brings the panel and the items back into it
#   ⑤ all-removed      every status item removed; none left anywhere
#
# The run is a headless fixture (tests/g1/lib/shell-fixture.sh): Wayfire on a
# headless output, Core in normal mode with the built-in packages plus the
# D-34 QML fixtures and one broken status item built here, the real Shell and
# the verification relay. Results are read back through Core; the Shell's
# `status` control line is read beside it to see the items themselves. It is
# the prerequisite of EX1-10's +10-plugin A/B (what "loaded" means there),
# not EX1-10 evidence.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
WINDOW_PIDS=()
trap shell_fixture_stop EXIT INT TERM

g1_begin status-items "D-34 status items (EX1-10 prerequisite)"
g1_preflight
evidence="$(g1_evidence_dir)"

missing=()
for tool in quickshell node jq; do command -v "$tool" >/dev/null || missing+=("$tool"); done
[[ -d "$WORKSPACE/target/ditto-packages" ]] || missing+=("target/ditto-packages (scripts/build-builtin-packages.sh)")
if (( ${#missing[@]} > 0 )); then
  check status-items environment "missing: ${missing[*]}"
  g1_finish
fi

# The product's built-ins, the five D-34 QML items, and a status item whose
# QML does not parse (a built-in, so trust policy is not what refuses it).
packages="$evidence/packages"
mkdir -p "$packages" "$evidence/broken/qml"
cp "$WORKSPACE"/target/ditto-packages/*.dittopkg "$packages/"
node "$WORKSPACE/packages/host-sdk/scripts/pack-each.mjs" "$WORKSPACE"/packages/plugin-fixtures/qml/* --out "$packages" >/dev/null
jq '.id = "ditto.fixture.status_broken" | .version = "1.0.0" | .name = {"zh-TW": "壞掉的狀態項目", "en": "Broken status item"} | .qml_entry = "qml/StatusBroken.qml"' \
  "$WORKSPACE/packages/plugin-fixtures/qml/clock/manifest.json" >"$evidence/broken/manifest.json"
printf 'import QtQuick\nItem {\n    this is not QML\n' >"$evidence/broken/qml/StatusBroken.qml"
tar --zstd --sort=name --mtime='2026-01-01 00:00Z' --owner=0 --group=0 --numeric-owner \
  -cf "$packages/ditto.fixture.status_broken-1.0.0.dittopkg" -C "$evidence/broken" manifest.json qml

start_compositor >/dev/null
export DITTO_FIXTURE_PACKAGES="$packages"
if ! shell_fixture_start; then
  cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
  check status-items fail "the desktop fixture did not come up (Core, Shell boot sync, relay); log in $evidence/core.log"
  g1_finish
fi
shell_pid="$(core_child quickshell)"

STATUS_ITEMS_SCREENSHOT="$evidence/five-items.png" python3 "$HERE/drive.py" >"$evidence/checks.jsonl" 2>"$evidence/drive.log" || true
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  check "$(jq -r .id <<<"$line")" "$(jq -r .status <<<"$line")" "$(jq -r .detail <<<"$line")" "$(jq -c .evidence <<<"$line")"
done <"$evidence/checks.jsonl"
(( $(grep -c . "$evidence/checks.jsonl" || true) == 6 )) ||
  check driver fail "the driver reported $(grep -c . "$evidence/checks.jsonl" || true) of 6 checks; see $evidence/drive.log"

# The Shell process that mounted and unmounted the items is the one that
# started: nothing was restarted to get here.
if [[ -n "$shell_pid" && "$(core_child quickshell)" == "$shell_pid" ]]; then
  check shell-survived pass "the Shell (pid $shell_pid) ran throughout"
else
  check shell-survived fail "the Shell was restarted (pid $shell_pid → $(core_child quickshell))"
fi
cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
g1_finish
