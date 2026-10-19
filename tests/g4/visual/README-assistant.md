# R3 助理驗證（#67）

這些測試是 development 證據。正式端到端、IME、Wayfire 焦點、Orca、多屏與 NFR 仍需參考機；fixture 的 session／turn／approval 不是 Core 執行紀錄。

```sh
export QT_PREFIX=/data/hermes/.local/toolchains/qt/6.10.2/gcc_64
bash tests/g4/visual/run-assistant.sh /path/to/evidence
# 先 stage 助理後，原 R1 runner 也會擷取新增的十二張圖：
bash tests/g4/visual/run.sh /path/to/evidence/visual
```

`run-assistant.sh` 不改既有 runner、供應者或共用測試。`stage-assistant.py` 複製實際 QML，只移除有紀錄的 layer-shell 行、以數值替代 stub 缺少的 ExclusionMode enum，並提供 FloatingWindow Item 替身（無真視窗裝飾、focus ownership）。`staging.json` 保存來源 SHA-256 與每個改動。Legacy 來源固定為 `25c0b726ef3c3bc7c8e00232514604cc0498007e`。

- `unit/tst_assistant.qml`：27 項，真實 pre-open／設定未回讀、終態與離線／停用原因並列、鍵盤、符號候選、圓角命中、IME composing policy、七態／starting／cancelling／reconnecting、未知／部分／停止終態。沒有真正的輸入法事件注入。
- `assistant/tst_assistant_flow.qml`：12 項，真實 pre-open、X 開啟→切 Y→收合保留 Y（含延後回焦競態），四角 legacy compact 逐像素及幾何、入口真實矩形、0.5／1／2 倍命中區、hidden、表面切換保留草稿／串流／歷史／approval、Escape 收合不取消、approval Escape＝拒絕。真實應用回焦仍未執行。
- `capture/tst_assistant_capture.qml`：normal／legacy 各六場景：收合、compact、完整、approval 待決、unknown、offline。PNG 放 evidence，不進 git。JSON 記 fixture、場景、幾何、renderer、commit 與 PNG hash；`profile_hash = null` 明確表示沒有真實 Core Profile 快照。
- staging 另斷言 legacy avatar 掛載區塊、Avatar.qml、ApprovalWindow.qml 對照 base 逐字相同；不變的 approval／preview 仍走既有安全路徑。

協定 shape 與舊版拒絕／明確降版，可在沒有 Core socket 時用相同 TS schema checker 驗證：

```sh
git show 25c0b72:schema/profile-document.json > /path/to/evidence/profile-document-base.json
node --experimental-strip-types tests/g4/visual/check-assistant-contracts.mjs /path/to/evidence/profile-document-base.json
```

本 runner 的 sandbox 禁止 socket，也使 Node `spawnSync` 回 EPERM。原 `run.sh` 的 staging、protocol integration test、完整 Core IPC 與 lrelease 子程序 gate 需在 sandbox 外重跑，不能把替代步驟冒充原 gate 通過。本機替代程序直接跑 Python staging、qmltestrunner、`/usr/bin/python3 capture/compose.py`；TS shape checker 不啟動 Core；lrelease 直接執行並以 cmp 檢查 .qm。完整指令、exit、原始失敗及替代結果見 evidence `REPORT.md`／`gate-results.json`。

決策紀錄見 [D-48](../../../.agents/notes/decisions/2026-10-17-d48-default-assistant-entry.md)。最終符號待 owner 決定，暫用中性符號；新預設主題與 Dock 是依 #71 的可逆交接選擇。

收合場景現在直接使用 fresh ConversationState（wanted=false、settings/provider=null、無草稿／事件）；不再以已讀設定的 fixture 冒充首次呈現。新預設模板也適用日後 `desktop.profiles.create {from: default}` 建立的新 Profile，既有已儲存文件不改寫。

## #67 小 Ditto＋FAB 候選（2026-10-19）

依 owner 最新留言提供候選，**預設維持現行膠囊／中性符號**；不改 `shell.qml`、Core、Profile 或 D-48 決策結論。component-sheet D11 標記「候選待 owner」。未新增快捷動作。

`AssistantSurface`／`AssistantEntry` 的 opt-in 接點：`entryStyle: "fab"`、`fabSize: 48 | 56`、`symbolVariant: "ditto" | "ditto-vector"`、`expansionMode: "label" | "chat"`。D1 引用既有 body.png（35 px 顯示、70 px 解碼）；D2 是 QML Shape。來源與**未釐清**權利見 [SOURCES](../../../shell/assistant/SOURCES.md)。D2 也不是角色設計權利已解決的宣告。

- E1（label）：click／Enter／Space 先展開「助理＋狀態」膠囊，第二次才送既有 `activated`；Escape 收合。56 px 展開約 195×56，最接近原圖約 195×54 與 35 px 圓形頭像；48 px 為緊湊提案。長字級維持最小尺寸而可增高。
- E2（chat）：第一次 click／Enter／Space 就送既有 `activated`。候選 host 沿用同一 `ChatPanel`（compact ChatWindow 表面）與 ConversationState，位置是 FAB 真實矩形上方 8 px；Escape 沿既有 composing guard。表面 `collapseRequested` 供 host 收合，沒有 cancel／approval 副作用。
- hover／focus 只做 0.96 回饋、focus 框及文字狀態提示，press 0.90；沿用 120 ms OutCubic。工作中使用既有真實投影；reduced-motion 同步 settle 並停 pulse。膠囊／圓形命中區不跟符號縮放。

目前 Shell 不選用上述 opt-in。候選測試 host 明確連接 `activated` 到現有 compact；沒有新增第二個聊天元件或訂閱。Owner 選定後才由後續整合在原 shell 接點傳入所選屬性；本次不需要修改 `shell.qml` 便能擷取及操作候選。

離線重跑（Qt／PATH 依 common-b8）：

```sh
bash tests/g4/visual/run-assistant.sh /data/hermes/ditto-runs/g4-impl/fab/evidence/candidates
DITTO_ASSISTANT_CAPTURE_OUT=/data/hermes/ditto-runs/g4-impl/fab/evidence/candidates bash tests/g4/visual/run.sh /data/hermes/ditto-runs/g4-impl/fab/evidence/visual
```

runner 先 stage 現有 providers 及本機圖示資料。每個 D1／D2 × 48／56 × E1／E2，共 8 組各有收合、hover、focus、展開、working 收合、working 展開、reduced-motion、legacy-theme、全桌面 9 張；另保留原 12 張 normal／legacy。全桌面合成使用真正 staged 頂部列及 Dock，背景為現有漸層，沒有拿需求 JPEG 當桌布；無法據此宣稱壁紙／原圖忠實還原。正常動畫保留並等待有限過渡 settle；working 是有意保留的活動 pulse。

PNG、逐張 `candidates.md` 與含幾何、狀態、source／commit／PNG hashes 的 JSON 均在 evidence，不進 git。`DITTO_ASSISTANT_CAPTURE_OUT` 可指定 capture 目的地（run-assistant 自動設為參數目錄）；不設時保留舊 harness 的 staging 目的地。圓形 Region、2× 取樣、Enter／Space／Escape、同一會話保留由 QtTest 檢查。既有 legacy 像素／結構 oracle 保留。真實 Wayfire input region／回焦、IME、Orca、多屏及 NFR 尚未執行。
