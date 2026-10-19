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
export DITTO_ASSISTANT_CAPTURE_OUT="$(cd "$out" && pwd)"
node "$here/stage-providers.mjs" > "$out/provider-staging.log" 2>&1
cp "$here/.staged/staging.json" "$out/provider-staging.json"
"${DITTO_PIL_PYTHON:-/usr/bin/python3}" "$here/capture/prepare.py" > "$out/capture-prepare.log" 2>&1
cp "$here/.staged/capture-sources.json" "$out/capture-sources.json"
python3 "$here/stage-assistant.py" | tee "$out/assistant-staging.log"
cp "$here/.staged/assistant/staging.json" "$out/assistant-staging.json"
"$qt/bin/qmltestrunner" -import "$here/stubs" -input "$here/unit/tst_assistant.qml" > "$out/assistant-unit.log" 2>&1
"$qt/bin/qmltestrunner" -import "$here/stubs" -input "$here/assistant" > "$out/assistant-flow.log" 2>&1
"$qt/bin/qmltestrunner" -import "$here/stubs" -input "$here/capture/tst_assistant_capture.qml" > "$out/assistant-capture.log" 2>&1
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
scenes = {
 'collapsed': '收合', 'hover': 'hover：0.96，僅回饋', 'focus': 'focus：0.96、焦點環',
 'expanded': 'E1 第一次啟動：標籤膠囊', 'working-collapsed': 'working 收合', 'working': 'working 標籤膠囊',
 'open': 'E1 第二次啟動：compact 與 active 雙輪廓', 'open-collapsed': '對話開啟時的圓形 FAB',
 'reduced-motion': '減少動畫下的 open 狀態', 'legacy-theme': 'legacy 主題下的 open 狀態',
 'desktop': '全桌面合成：頂部列、Dock、E1 標籤膠囊',
}
lines = ['# D1／56／E1（owner 2026-10-19 選定）', '',
 '新預設助理採小 Ditto、固定56 px、E1兩段啟動；既有 capsule／neutral／portrait 接點保留。', '',
 'D1 body.png 授權仍**未釐清**，不代表可散布。35 px 顯示、依 device pixel ratio 的3×解碼、較深淡紫圓底與固定外環；開啟加雙輪廓和 Accessible 文字。', '',
 'click／Enter／Space：先展開標籤、再開既有compact；hover／focus僅回饋，Escape收合不取消turn或approval。', '',
 'development：Qt offscreen/software；Core／模型／layer-shell與視窗為fixture／替身。無桌布素材、未執行Wayfire／IME／Orca／NFR，不宣稱owner視覺接受或忠實還原。', '',
 '| 場景 | 實測入口尺寸 | 截圖（1280×800） |', '| --- | --- | --- |']
for row in rows:
 if row.get('presentation') != 'D1-56-E1': continue
 scene = row['scene'][len('D1-56-E1-'):]
 image_name = Path(row['file']).name
 lines.append(f"| {scenes[scene]} | {row['entry']['width']}×{row['entry']['height']} | [{image_name}]({image_name}) |")
lines += ['', '另保留normal／legacy各六場景。來源／commit／PNG hashes見assistant-captures.json及assistant-source-hashes.json；量測與前後裁圖見repair1/repair1.md。']
(out/'assistant-captures.md').write_text('\n'.join(lines)+'\n')
PY
