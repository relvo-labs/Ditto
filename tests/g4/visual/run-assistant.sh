#!/usr/bin/env bash
# Additive #67 suite. The existing R1 runner remains unchanged.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="${1:?evidence directory required}"
qt="${QT_PREFIX:-$HOME/Qt/6.10.2/gcc_64}"
mkdir -p "$out"
cd "$root"
export QT_QPA_PLATFORM=offscreen
python3 "$here/stage-assistant.py" | tee "$out/assistant-staging.log"
cp "$here/.staged/assistant/staging.json" "$out/assistant-staging.json"
"$qt/bin/qmltestrunner" -import "$here/stubs" -input "$here/unit/tst_assistant.qml" > "$out/assistant-unit.log" 2>&1
"$qt/bin/qmltestrunner" -import "$here/stubs" -input "$here/assistant" > "$out/assistant-flow.log" 2>&1
"$qt/bin/qmltestrunner" -import "$here/stubs" -input "$here/capture/tst_assistant_capture.qml" > "$out/assistant-capture.log" 2>&1
cp "$here/.staged/out/assistant-"*.png "$out/"
python3 - "$out" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1])
sources={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for pattern in ['shell/shell.qml','shell/chat/*.qml','shell/assistant/*.qml','shell/avatar/*.qml'] for path in sorted(Path('.').glob(pattern))}
(out/'assistant-source-hashes.json').write_text(json.dumps(sources,indent=2)+'\n')
rows=[json.loads(line.split('ASSISTANT_CAPTURE ',1)[1]) for line in (out/'assistant-capture.log').read_text().splitlines() if 'ASSISTANT_CAPTURE ' in line]
for row in rows:
 path=out/Path(row['file']).name
 row['file']=str(path)
 row['png_sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
 row['commit']=subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()
 row['source_dirty']=bool(subprocess.check_output(['git','status','--porcelain','--','shell','tests/g4/visual']))
(out/'assistant-captures.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
print(f'{len(rows)} assistant fixture captures; development evidence only')
PY
