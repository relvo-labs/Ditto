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
# #116: base (87a2462) and current application surfaces for tst_ui_style_off.qml.
node "$here/stage-ui116.mjs" > "$evidence/ui116-staging.log"
cp "$here/.staged/ui116/staging.json" "$evidence/ui116-staging.json"

# Unit regressions also consume the real Yaru lookup; prepare it before the
# first QML import so clean checkouts never depend on old capture data.
echo "== system icon/app lookup"
"$python" "$here/capture/prepare.py"
cp "$here/.staged/capture-sources.json" "$evidence/capture-sources.json"

echo "== unit tests"
"$runner" -import "$here/stubs" -input "$here/unit" 2>&1 | tee "$evidence/unit-tests.log"
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || { echo "unit tests failed ($status)"; exit "$status"; }
# #188: the launcher unit regressions again at device pixel ratio 2 (icon
# decode size follows the ratio; keyboard and plain-text rows are unchanged).
QT_SCALE_FACTOR=2 "$runner" -import "$here/stubs" -input "$here/unit/tst_launcher_grid.qml" 2>&1 \
  | tee "$evidence/unit-launcher-2x.log"
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || { echo "2x launcher unit tests failed ($status)"; exit "$status"; }
grep 'CONTRAST ' "$evidence/unit-tests.log" | sed 's/.*CONTRAST //' > "$evidence/contrast.txt"
# #105 C4 state table (real Yaru, pixels at 3:1 and 4.5:1) and C1 narrow steps.
grep 'STATUS_STATE ' "$evidence/unit-tests.log" | sed 's/.*STATUS_STATE //' > "$evidence/status-states.jsonl"
grep 'NARROW ' "$evidence/unit-tests.log" | sed 's/.*NARROW //' > "$evidence/narrow-layout.jsonl"
# #116 candidate text colours over every wallpaper pixel (and black).
"$python" "$here/capture/ui_contrast.py" "$evidence/unit-tests.log" "$root/shell/wallpapers/soft-jelly-default.jpg" \
  "$evidence/ui-contrast.json" | tee "$evidence/ui-contrast.log"
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || { echo "ui contrast failed ($status)"; exit "$status"; }

echo "== capture"
rm -f "$here/.staged/out/"*.png
rm -rf "$here/.staged/out/candidates"
mkdir -p "$here/.staged/out/candidates"
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
# #184: grid search, cross-category results and missing-icon fallback at 2x.
# #188: absolute-path raster PNG (grid and search launcher) and load error.
QT_SCALE_FACTOR=2 "$runner" -import "$here/stubs" -input "$here/capture/tst_launcher_grid_capture.qml" 2>&1 \
  | tee "$evidence/launcher-grid-hidpi-2x.log"
status=${PIPESTATUS[0]}
cp "$here/.staged/out/"launcher-grid-*.png "$here/.staged/out/"launcher-search-*.png "$evidence/"
grep 'LAUNCHER_META ' "$evidence/capture.log" "$evidence/launcher-grid-hidpi-2x.log" \
  | sed 's/.*LAUNCHER_META //' > "$evidence/launcher-grid-scenes.jsonl"
# Capture sizes (2560x1600 at 2x), device-pixel decode size and raster
# sharpness against a direct raster of the same PNG.
"$python" "$here/capture/check_launcher_icons.py" "$evidence" "$evidence/capture.log" "$evidence/launcher-grid-hidpi-2x.log" \
  | tee "$evidence/launcher-icons.log"
icons=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || { echo "2x launcher capture failed ($status)"; exit "$status"; }
[[ $icons -eq 0 ]] || { echo "launcher icon check failed ($icons)"; exit "$icons"; }
"$python" "$here/capture/check_hidpi.py" "$evidence" "$evidence/capture.log" "$evidence/capture-hidpi-2x.log" \
  | tee "$evidence/hidpi.log"
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || { echo "2x glyph check failed ($status)"; exit "$status"; }
# #105 C1/C2 review scenes (capture/tst_panel_scenes.qml): narrow bars, menu, tooltip.
cp "$here/.staged/out/"panel-scene-*.png "$evidence/"
grep 'SCENE_META ' "$evidence/capture.log" | sed 's/.*SCENE_META //' > "$evidence/panel-scenes.jsonl"

echo "== compose"
"$python" "$here/capture/compose.py" "$evidence" "$evidence/capture.log"
# #116 candidate screens (capture/tst_apps_candidates.qml) and comparison sheets.
mkdir -p "$evidence/candidates"
cp "$here/.staged/out/candidates/"*.png "$evidence/candidates/"
"$python" "$here/capture/compose_candidates.py" "$evidence/candidates" "$evidence/capture.log"
{
  echo "commit $(git -C "$root" rev-parse HEAD)"
  echo "dirty $(git -C "$root" status --porcelain -- shell tests/g4 | wc -l)"
  echo "qt $("$qt/bin/qtpaths" --qt-version 2>/dev/null || echo unknown)"
  echo "platform $(uname -srm)"
  echo "reference_sha256 $(sha256sum "$root/docs/design/default-desktop/reference/owner-desktop-reference.jpg" | cut -d' ' -f1)"
  for png in "$evidence"/*.png; do echo "png $(basename "$png") $(sha256sum "$png" | cut -d' ' -f1)"; done
} > "$evidence/run-record.txt"
echo "evidence: $evidence"
