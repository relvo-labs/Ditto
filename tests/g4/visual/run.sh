#!/usr/bin/env bash
# #65 visual harness (development evidence, offscreen; not reference-machine).
#
#   tests/g4/visual/run.sh [evidence-dir]
#
# 1. stage the rendered providers (layer-shell lines removed, see
#    stage-providers.mjs), 2. qmltestrunner unit tests (tokens, material,
#    backdrop, dock), 3. collect this machine's installed applications for the
#    Dock (capture/prepare.py), 4. render the 1280×800 capture, plus the top
#    panel status capsule again at device pixel ratio 2 (capture/check_hidpi.py
#    compares its glyphs with a direct raster), 5. compose side-by-side and
#    overlay images against the reference. PNGs go to the
#    evidence directory (default tests/g4/visual/.staged/evidence), never git.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
evidence="${1:-$here/.staged/evidence}"
qt="${QT_PREFIX:-$HOME/Qt/6.10.2/gcc_64}"
runner="${DITTO_QMLTESTRUNNER:-$qt/bin/qmltestrunner}"
python="${DITTO_PIL_PYTHON:-/usr/bin/python3}"
mkdir -p "$evidence" "$here/.staged/out"
export QT_QPA_PLATFORM=offscreen

cd "$root"
node "$here/stage-providers.mjs"
cp "$here/.staged/staging.json" "$evidence/staging.json"
# The capture directory also includes the assistant scene. Prepare its real
# QML sources on a clean checkout, without relying on another runner's cache.
python3 "$here/stage-assistant.py" > "$evidence/assistant-staging.log"
cp "$here/.staged/assistant/staging.json" "$evidence/assistant-staging.json"

# Unit regressions also consume the real Yaru lookup; prepare it before the
# first QML import so clean checkouts never depend on old capture data.
echo "== system icon/app lookup"
"$python" "$here/capture/prepare.py"
cp "$here/.staged/capture-sources.json" "$evidence/capture-sources.json"

echo "== unit tests"
"$runner" -import "$here/stubs" -input "$here/unit" 2>&1 | tee "$evidence/unit-tests.log"
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || { echo "unit tests failed ($status)"; exit "$status"; }
grep 'CONTRAST ' "$evidence/unit-tests.log" | sed 's/.*CONTRAST //' > "$evidence/contrast.txt"
# #105 C4 state table (real Yaru, pixels at 3:1 and 4.5:1) and C1 narrow steps.
grep 'STATUS_STATE ' "$evidence/unit-tests.log" | sed 's/.*STATUS_STATE //' > "$evidence/status-states.jsonl"
grep 'NARROW ' "$evidence/unit-tests.log" | sed 's/.*NARROW //' > "$evidence/narrow-layout.jsonl"

echo "== capture"
rm -f "$here/.staged/out/"*.png
"$runner" -import "$here/stubs" -input "$here/capture" 2>&1 | tee "$evidence/capture.log"
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || { echo "capture failed ($status)"; exit "$status"; }

# #105 C3: the same status capsule at device pixel ratio 2 (the scale-1 run is
# part of the capture directory above), then compare glyphs with a raster.
echo "== capture (device pixel ratio 2)"
QT_SCALE_FACTOR=2 "$runner" -import "$here/stubs" -input "$here/capture/tst_hidpi_capture.qml" 2>&1 \
  | tee "$evidence/capture-hidpi-2x.log"
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || { echo "2x capture failed ($status)"; exit "$status"; }
"$python" "$here/capture/check_hidpi.py" "$evidence" "$evidence/capture.log" "$evidence/capture-hidpi-2x.log" \
  | tee "$evidence/hidpi.log"
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || { echo "2x glyph check failed ($status)"; exit "$status"; }
# #105 C1/C2 review scenes (capture/tst_panel_scenes.qml): narrow bars, menu, tooltip.
cp "$here/.staged/out/"panel-scene-*.png "$evidence/"
grep 'SCENE_META ' "$evidence/capture.log" | sed 's/.*SCENE_META //' > "$evidence/panel-scenes.jsonl"

echo "== compose"
"$python" "$here/capture/compose.py" "$evidence" "$evidence/capture.log"
{
  echo "commit $(git -C "$root" rev-parse HEAD)"
  echo "dirty $(git -C "$root" status --porcelain -- shell tests/g4 | wc -l)"
  echo "qt $("$qt/bin/qtpaths" --qt-version 2>/dev/null || echo unknown)"
  echo "platform $(uname -srm)"
  echo "reference_sha256 $(sha256sum "$root/docs/design/default-desktop/reference/owner-desktop-reference.jpg" | cut -d' ' -f1)"
  for png in "$evidence"/*.png; do echo "png $(basename "$png") $(sha256sum "$png" | cut -d' ' -f1)"; done
} > "$evidence/run-record.txt"
echo "evidence: $evidence"
