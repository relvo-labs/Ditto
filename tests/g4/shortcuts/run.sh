#!/usr/bin/env bash
# #190 development evidence. QML fixtures, no VM or compositor key capture.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
evidence="${1:?usage: run.sh evidence-dir [source-root] [a|b|baseline]}"
source_root="${2:-$root}"
label="${3:-a}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
export QT_QPA_PLATFORM=offscreen QML_DISABLE_DISK_CACHE=1
python3 "$root/tests/g4/shortcuts/stage.py" "$source_root" "$evidence/staged" "$label"
runner="${QT_PREFIX:?source the runner environment}/bin/qmltestrunner"
# Baseline controls deliberately return RED; keep rendering after that failure.
set +e
timeout -k 2 40 "$runner" -import "$evidence/staged/stubs" -input "$evidence/staged/tst_baseline.qml" > "$evidence/regressions.log" 2>&1
regressions=$?
set -e
if [[ "$label" != baseline ]]; then
    timeout -k 2 40 "$runner" -import "$evidence/staged/stubs" -input "$evidence/staged/tst_shortcuts.qml" > "$evidence/workflows.log" 2>&1
fi
timeout -k 2 55 "$runner" -import "$evidence/staged/stubs" -input "$evidence/staged/tst_capture.qml" > "$evidence/capture.log" 2>&1
printf 'regressions_exit=%s\n' "$regressions" > "$evidence/status.txt"
python3 - "$evidence" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
rows = [json.loads(line.split("SHORTCUT_CAPTURE ", 1)[1]) for line in (out / "capture.log").read_text().splitlines() if "SHORTCUT_CAPTURE " in line]
assert len(rows) == 24, len(rows)
assert len({row["file"] for row in rows}) == 24
assert all(Path(row["file"]).is_file() for row in rows)
(out / "captures.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
PY
printf 'shortcut fixtures: %s, regression exit %s, 24 captures\n' "$label" "$regressions"
exit "$regressions"
