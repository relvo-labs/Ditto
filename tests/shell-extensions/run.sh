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
    package_dir="$evidence/package-store/ditto.settings.$page/1.0.0"
    mkdir -p "$package_dir"
    archive="$evidence/ditto.settings.$page-1.0.0.dittopkg"
    tar --zstd -cf "$archive" -C "$source_dir" manifest.json qml
    tar --zstd -xf "$archive" -C "$package_dir"
    # Production loads by absolute file URL from a store outside the config root.
    page_url="$(python3 -c 'import json; from pathlib import Path; import sys; p = Path(sys.argv[1]); print((p / json.loads((p / "manifest.json").read_text())["qml_entry"]).as_uri())' "$package_dir")"
    set +e
    DITTO_TEST_PAGE_ID="$page" DITTO_TEST_PAGE_URL="$page_url" LD_LIBRARY_PATH="${DITTO_QS_LD_LIBRARY_PATH:?source the runner environment first}" timeout 15 "$qt/bin/quickshell" -p "$evidence/real/shell.qml" > "$evidence/real-load-$page.log" 2>&1
    code=$?
    set -e
    cat "$evidence/real-load-$page.log" | tee -a "$evidence/real-load.log"
    [[ $code -eq 0 ]] || exit "$code"
    grep -aq "REAL_PAGE_READY root:/sdk/Ditto/Ui packaged $page" "$evidence/real-load-$page.log"
done
