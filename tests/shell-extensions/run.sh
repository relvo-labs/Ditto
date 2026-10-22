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
# A real archive, unpacked separately from the source tree; no SDK import rewrite.
package_dir="$evidence/package-store/ditto.settings.history/1.0.0"
mkdir -p "$evidence/real" "$package_dir"
tar --zstd -cf "$evidence/ditto.settings.history-1.0.0.dittopkg" -C "$root/shell/providers/settings_history" manifest.json qml
tar --zstd -xf "$evidence/ditto.settings.history-1.0.0.dittopkg" -C "$package_dir"
# Production loads by absolute file URL from a store outside the config root.
page_url="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).as_uri())' "$package_dir/qml/HistoryPage.qml")"
for directory in sdk ui change jelly; do
    ln -sfn "$root/shell/$directory" "$evidence/real/$directory"
done
cp "$root/tests/shell-extensions/real-load.qml" "$evidence/real/shell.qml"
set +e
DITTO_TEST_PAGE_URL="$page_url" LD_LIBRARY_PATH="${DITTO_QS_LD_LIBRARY_PATH:?source the runner environment first}" timeout 15 "$qt/bin/quickshell" -p "$evidence/real/shell.qml" > "$evidence/real-load.log" 2>&1
code=$?
set -e
cat "$evidence/real-load.log"
[[ $code -eq 0 ]] || exit "$code"
rg -q 'REAL_PAGE_READY root:/sdk/Ditto/Ui packaged history' "$evidence/real-load.log"
