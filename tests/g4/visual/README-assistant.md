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
