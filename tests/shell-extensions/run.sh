#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
evidence="${1:?usage: run.sh evidence-dir}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
qt="${QT_PREFIX:?source the runner environment first}"
export QT_QPA_PLATFORM=offscreen QML_DISABLE_DISK_CACHE=1
export XDG_RUNTIME_DIR="$evidence/runtime" XDG_CACHE_HOME="$evidence/cache" XDG_STATE_HOME="$evidence/state"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
chmod 700 "$XDG_RUNTIME_DIR"
python3 "$root/tests/shell-extensions/stage.py" "$evidence/staged"
"$qt/bin/qmltestrunner" -import "$evidence/staged/stubs" -input "$evidence/staged/unit" > "$evidence/unit.log" 2>&1
cat "$evidence/unit.log"
# Real archives, unpacked separately from the source tree; no SDK import rewrite.
mkdir -p "$evidence/real"
for directory in sdk ui change jelly centers chat; do
    ln -sfn "$root/shell/$directory" "$evidence/real/$directory"
done
cp "$root/tests/shell-extensions/real-load.qml" "$evidence/real/shell.qml"
: > "$evidence/real-load.log"
for page in history composition plugins personalization ai; do
    source_dir="$root/shell/providers/settings_$page"
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$source_dir/manifest.json")"
    package_dir="$evidence/package-store/ditto.settings.$page/$version"
    mkdir -p "$package_dir"
    archive="$evidence/ditto.settings.$page-$version.dittopkg"
    tar --zstd -cf "$archive" -C "$source_dir" manifest.json qml
    tar --zstd -xf "$archive" -C "$package_dir"
    # Production loads by absolute file URL from a store outside the config root.
    page_url="$(python3 -c 'import json; from pathlib import Path; import sys; p = Path(sys.argv[1]); print((p / json.loads((p / "manifest.json").read_text())["qml_entry"]).as_uri())' "$package_dir")"
    plugin_manifest="$(cat "$package_dir/manifest.json")"
    plugin_sha256="$(sha256sum "$archive" | cut -d' ' -f1)"
    set +e
    DITTO_TEST_PAGE_ID="$page" DITTO_TEST_PAGE_URL="$page_url" DITTO_TEST_PLUGIN_MANIFEST="$plugin_manifest" DITTO_TEST_PLUGIN_SHA256="$plugin_sha256" LD_LIBRARY_PATH="${DITTO_QS_LD_LIBRARY_PATH:?source the runner environment first}" timeout 15 "$qt/bin/quickshell" -p "$evidence/real/shell.qml" > "$evidence/real-load-$page.log" 2>&1
    code=$?
    set -e
    cat "$evidence/real-load-$page.log" | tee -a "$evidence/real-load.log"
    [[ $code -eq 0 ]] || exit "$code"
    grep -aq "REAL_PAGE_READY root:/sdk/Ditto/Ui packaged $page" "$evidence/real-load-$page.log"
    if [[ "$page" == plugins ]]; then
        grep -aq "REAL_PLUGIN_SEARCH_READY root:/sdk/Ditto/Ui ditto.settings.plugins@$version checks=8" "$evidence/real-load-$page.log"
    fi
done
# #188: both launchers with real Quickshell icon lookup (theme name through
# image://icon, absolute PNG path, unknown name, undecodable file, no icon)
# at device pixel ratio 1 and 2. Offscreen Qt has no icon search paths, so a
# test-only preload sets the XDG ones (icon-search-paths.cpp); the theme is a
# fixture under the evidence directory. Layer-shell windows are staged as
# FloatingWindow (stage-launcher.py records every changed line).
launcher="$evidence/launcher-icons"
rm -rf "$launcher"
mkdir -p "$launcher/real" "$launcher/data/icons/DittoLauncherTest/256x256/apps"
python3 "$root/tests/shell-extensions/stage-launcher.py" "$launcher/staged" | tee "$launcher/staging.log"
g++ -std=c++17 -shared -fPIC "$root/tests/shell-extensions/icon-search-paths.cpp" \
    -I"$qt/include" -I"$qt/include/QtCore" -I"$qt/include/QtGui" -L"$qt/lib" -lQt6Gui -lQt6Core \
    -o "$launcher/libditto-icon-search-paths.so"
cp "$root/tests/shell-extensions/launcher-icon-theme/index.theme" "$launcher/data/icons/DittoLauncherTest/"
cp "$root/tests/g4/visual/fixtures/raster-icon-256.png" "$launcher/data/icons/DittoLauncherTest/256x256/apps/ditto-launcher-raster.png"
ln -sfn "$root/shell/jelly" "$launcher/real/jelly"
cp "$root/tests/shell-extensions/launcher-icons.qml" "$launcher/real/shell.qml"
for ratio in 1 2; do
    set +e
    QT_SCALE_FACTOR="$ratio" XDG_DATA_DIRS="$launcher/data:/usr/local/share:/usr/share" \
    DITTO_TEST_LAUNCHER_DIR="$launcher/staged" DITTO_TEST_RASTER_FILE="$root/tests/g4/visual/fixtures/raster-icon-256.png" \
    DITTO_TEST_CORRUPT_FILE="$root/tests/g4/visual/fixtures/corrupt-icon.png" \
    LD_PRELOAD="$launcher/libditto-icon-search-paths.so" LD_LIBRARY_PATH="${DITTO_QS_LD_LIBRARY_PATH:?source the runner environment first}" \
        timeout 20 "$qt/bin/quickshell" -p "$launcher/real/shell.qml" > "$launcher/real-launcher-${ratio}x.log" 2>&1
    code=$?
    set -e
    grep -a 'REAL_LAUNCHER_' "$launcher/real-launcher-${ratio}x.log"
    [[ $code -eq 0 ]] || exit "$code"
    grep -aq 'REAL_LAUNCHER_ICONS_DONE failures=0' "$launcher/real-launcher-${ratio}x.log"
    grep -aq "REAL_LAUNCHER_ICONS_READY grid ratio=$ratio checks=6" "$launcher/real-launcher-${ratio}x.log"
    grep -aq "REAL_LAUNCHER_ICONS_READY search ratio=$ratio checks=6" "$launcher/real-launcher-${ratio}x.log"
done
