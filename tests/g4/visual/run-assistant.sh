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
 'collapsed': '收合，圓形命中區', 'hover': '游標 hover（0.96，僅回饋與狀態提示）',
 'focus': '鍵盤 focus（0.96、焦點環與狀態提示）', 'expanded': '點擊展開',
 'working-collapsed': '收合且 working；Core 狀態 fixture', 'working': '展開且 working；顯示真實投影文字',
 'reduced-motion': '展開＋減少動畫，立即 settle', 'legacy-theme': '僅在明確 opt-in 下套舊主題；不改 legacy 預設',
 'desktop': '全桌面原生元件合成，含頂部列與 Dock；無乾淨桌布素材',
}
lines = ['# 小 Ditto＋FAB 候選（#67）', '',
 '候選待 owner，沒有改 Core／Profile、shell.qml 或預設呈現。development：Qt offscreen、software renderer、layer-shell／視窗替身；不是 Wayfire／真模型／實體輸入／NFR 或視覺接受證據。', '',
 'D1：既有 body.png，35 px／70 px（2×）解碼＋QML 臉，授權**未釐清**（shell/avatar/layers/SOURCES.md）；D2：純 QML 向量，未新增點陣素材，角色／名稱權利仍待確認。詳 shell/assistant/SOURCES.md。', '',
 '48 px 是緊湊提案；56 px 的 E1 展開約 195×56，搭配 35 px 小 Ditto，最接近參考圖約 195×54／35 px 頭像比例。入口沿現行 32 px 邊距，沒有自行定案原圖位置或 #46 移動方式。', '',
 'E1：點擊／Enter／Space 先展開標籤膠囊，再啟動才開既有對話；Escape 收合。E2：點擊／Enter／Space 直接開同一 compact ChatPanel；Escape 走既有 composing guard 收合。hover／focus 僅回饋，不開 editor、不啟動 Agent。沒有新增快捷動作。收合不取消 turn 或 approval。', '',
 '待 owner：D1／D2？48／56？E1 兩段展開／E2 直開對話？目前明示 click／鍵盤，是否另提 hover／focus 自動展開標籤（不自動開 editor）？建議先比較 D1-56-E1 與 D2-56-E2。', '',
 '| 候選 ID | 場景／差異 | 實測入口尺寸 | 截圖（1280×800） |', '| --- | --- | --- | --- |']
for row in rows:
 if 'candidate' not in row: continue
 scene = row['scene'][len(row['candidate'])+1:]
 image_name = Path(row['file']).name
 lines.append(f"| {row['candidate']} | {scenes[scene]} | {row['entry']['width']}×{row['entry']['height']} | [{image_name}]({image_name}) |")
lines += ['', '既有 normal／legacy 六場景各一張亦保留（assistant-normal-*／assistant-legacy-*），用於檢視預設與舊角色呈現；逐像素／幾何與行為 oracle 見 assistant-flow.log。來源、fixture、PNG SHA-256 與 commit 見 assistant-captures.json／assistant-source-hashes.json。']
(out/'candidates.md').write_text('\n'.join(lines)+'\n')
PY
