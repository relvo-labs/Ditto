# QML 視覺回歸（開發證據）

執行 `bash tests/g4/visual/run.sh <evidence-dir>`。需要本機 Qt 6.10.2、Node 與系統 Python 的 Pillow；以 `QT_PREFIX`、`DITTO_QMLTESTRUNNER` 指定工具鏈。Quickshell 由 `stubs/` 替代，layer-shell 行的移除與來源雜湊記在 `staging.json`。這些 offscreen 結果不代表實體座位、合成器、鍵盤、無障礙或效能驗收。

`unit/tst_accent_foreground.qml` 檢查無主題、`soft-jelly`、`soft-jelly-light` 的預設值、Profile `on_accent` 初始及即時覆寫、移除覆寫、無效色值，以及尚未收到 projection 的預設值。QML 使用 `accentForeground`，避免 `on` 加大寫字母被當成訊號處理器；Profile 的鍵名不變。

`unit/tst_tokens.qml` 以 WCAG 相對亮度公式計算三種主題的 accent 及各材質文字對比，門檻 4.5。#72 未改任何 fallback 色值。

`unit/tst_status_contrast.qml` 直接讀取 Button、Badge、TasksPanel 與 Avatar 的實際文字／背景配對，涵蓋三種主題的一般、降低透明度與低耗電模式。狀態填色用衍生 `statusForeground`（light 白色、dark `#1a1626`），accent 填色仍用可覆寫的 `accentForeground`；並驗證 accent 覆寫不會影響狀態前景色。中性 Badge／secondary Button 的 surfaceStrong 配對也有元件斷言。

Repair round 1b 已獲協調者授權，只修改 Avatar awaiting 問號的前景色為 `statusForeground`。light warning 上的對比從 1.96 提高到 7.48；三主題三模式均由一般對比斷言檢查，沒有 skip 或放寬門檻。

`unit/tst_legacy.qml` 仍比較舊版 Dock 的尺寸、文字、窗口位置與命中區。#72 修復後，啟用中項目的前景色從黑色變成設計值，所以正常畫面應有像素差異；再將目前版本的 `on_accent` 明確覆寫為黑色時，必須逐像素與舊版一致。基準 Dock 與 Tokens 均取自已固定的 `f582426`，不讓基準誤用目前 Tokens。

擷取包括：

| 檔名 | 真實 QML 元件與測試情境 |
| --- | --- |
| `normal`、`reduced-transparency`、`low-power`、`dock-states` | PanelTop 活動工作區、DockPill 與材質樣本 |
| `legacy-soft-jelly`、`legacy-no-theme` | 舊主題的活動工作區與有焦點的 Dock 項目 |
| `accent-controls-<theme>` | primary／danger Button、非 neutral Badge、已選 Choice、已開 Toggle |
| `accent-Centers-<theme>` | 管理中心目前頁籤，以及組合頁共用控制項 |
| `accent-LauncherGrid-<theme>` | 搜尋欄、目前分類與應用程式首字回退 |
| `accent-LauncherSearch-<theme>` | 已選搜尋結果 |
| `accent-TasksPanel-<theme>` | 示範資料標籤（使用 warning 背景） |

`<theme>` 為 `no-theme`、`soft-jelly`、`soft-jelly-light`。後四類使用標明的 fixture 資料；管理中心的 Core 呼叫回報不可用，沒有實際寫入。FloatingWindow 替身只呈現內容；不驗證原生視窗行為。原始 PNG 在 `.staged/out/`，擷取後可複製到證據目錄；PanelTop 的時鐘是擷取當下時間，比較時須另辨識時鐘差異。

狀態元件的控制項圖與 TasksPanel 圖另外擷取 `-reduced-transparency`、`-low-power` 兩種後綴，覆蓋全部三種主題。

#184 的 `unit/tst_launcher_grid.qml` 使用實際網格啟動器與可控制回覆順序的 Core 替身，檢查搜尋參數、跨類別排序、過期成功／錯誤回覆、清除與關閉、預設 Enter、四方向鍵，以及圖示載入與首字回退。`capture/tst_launcher_grid_capture.qml` 擷取 `launcher-grid-{normal,search,no-icon}-{1,2}x.png`，由 `run.sh` 複製到證據目錄；`launcher-grid-scenes.jsonl` 記錄查詢、結果、圖示來源與裝置縮放。資料是標明的 fixture，沒有查詢實際應用索引；不代表實體 HiDPI 座位驗收。

#187／#188／#189 補充同一組測試；`run.sh` 另以 `QT_SCALE_FACTOR=2` 重跑 `unit/tst_launcher_grid.qml`。

- **純文字（#189）**：兩個啟動器的名稱、首字回退與含名稱的啟動錯誤，以 zh-TW／en 實際目錄字串檢查。測試字串包含標籤、`&`、實體、引號、CJK 與 `<br>`；先確認 `Text.PlainText`，再與同字型純文字參照比對寬高。
- **左右鍵（#187）**：以表格經實際按鍵事件測試游標在首／中／尾、Shift、Ctrl、已選取文字、空查詢，以及有無結果的情況。組字中無法用 QtTest 按鍵產生 pre-edit，只測決策函式，沒有送出實際輸入事件。
- **選取通知（#187）**：鍵盤移動選取後，`selectionAnnouncement` 為名稱與位置，並經 `Accessible.announce` 送出。測試只確認文字與呼叫沒有錯誤，沒有讀屏證據。
- **點陣圖清晰度（#188）**：`fixtures/raster-icon-256.png` 是絕對路徑點陣 PNG，由 `fixtures/make-raster-icon.py` 產生；`fixtures/corrupt-icon.png` 是無法解碼的檔案。擷取另加 `launcher-grid-{raster,load-error}-{1,2}x.png` 與 `launcher-search-raster-{1,2}x.png`。`capture/check_launcher_icons.py` 檢查擷取 PNG 的裝置尺寸（2× 為 2560×1600）、`sourceSize = ceil(顯示尺寸 × 裝置縮放)`、載入失敗的首字回退，並把點陣圖示的裝置像素與同檔案的直接點陣比較，結果寫入 `launcher-icons.json`。

修正前 2× 量測：網格平均誤差 0.125、邊緣能量比 0.52；搜尋式 0.111／0.30。修正後：網格 0.028／0.88，搜尋式 0.023／1.03。門檻 0.06／0.75 落在兩者之間。以上是 offscreen 軟體繪製的開發證據，不是參考機量測。

## #116 Soft Jelly 應用風格（三種可選，預設 J1）

`run.sh` 另外執行：`stage-ui116.mjs`（把 `87a2462` 與目前的 `shell/ui`、`jelly`、`centers`、`chat`、`change`、`assistant`、`avatar`、`dock_pill` 並排放到 `.staged/ui116/`，只移除 layer-shell 行）、`unit/tst_ui_style.qml`（風格來自 Profile token `ui_style`、預設 J1、非法值＝J1、深色與無主題不受影響、提交後即時切換；新元件的鍵盤／名稱／角色、減少動畫、降低透明度、對比）、`unit/tst_ui_style_off.qml`（深色主題（也含設了 `ui_style`）與無主題時與基底逐像素相同）、`unit/tst_ui_style_pages.qml`（卡片動作、AI 關閉空狀態、確認視窗預設拒絕）、`unit/tst_ui_style_layout.qml`（1600×900：設定標題避開待辦面板、捲到底、Tab 捲入、compact 對話的角色／分頁／範例／輸入框不重疊、AI 關閉沒有「新對話」、J3 視窗鈕與灰字對比、個人化中心「外觀風格」的鍵盤與無障礙；把較早的樹以 `tree` 指向即可做 RED）、`unit/tst_ui_style_dock.qml`、`unit/tst_ui_style_frameless.qml`（Centers、ChatWindow、ApprovalWindow 在 `DittoStub.StubFloatingWindow`（依 Quickshell 0.3.1 建模、後端是真的 offscreen 視窗）上，視窗顯示中時旗標不得改變：第一次顯示、風格切換、撤銷、主題切換、關閉；`stage-ui116.mjs` 另產生 `<tree>-native`，並可帶 ref 參數暫存較早的樹做 RED）、`capture/ui_contrast.py`（各風格文字疊在桌布每個像素與黑色上的最小對比），以及 `capture/tst_apps_candidates.qml`：J1／J2／J3（由 Profile token 選）各十張 1280×800（組合中心一般／降低透明度／低效能／`⋯` 選單、個人化、AI 設定、對話 AI 關閉、角色旁 compact 對話 AI 關閉、對話進行中＋確認、Dock 缺圖示），複製到 `<證據目錄>/candidates/`，由 `capture/compose_candidates.py` 產生三欄與手機直式比較板和 `candidates.json`。資料都是 `fixtures/AppFixtureClient.qml`、`ConversationFixture.qml` 的標明 fixture；offscreen 沒有 Qt／Wayfire 的視窗標題列與陰影。標題列與 foot 的設定檔另由 `tools/ui-candidates/check-styles.py`（`selftest.sh`）檢查。

#183 的 Plugin Center 在深色與無主題也新增搜尋。`stage-ui116.mjs` 另建立 `plugin-search` oracle tree：
固定 `87a2462` 的整棵歷史來源，只在歷史 PluginCenter 的已安裝列表前插入手寫的
`fixtures/plugin-search-controls.qml.inc`（標籤與空搜尋欄位）。不從目前頁面抽取 QML、不重錄目前輸出的像素，
fixture 不實作篩選。來源、fixture 與結果雜湊記在 staging.json；原 `base` tree 與其他頁面的比較不變。
五個 plugin 比較列仍要求逐像素完全相等，另由 `test_plugin_search_in_legacy_modes` 在五種模式實際鍵入、
篩選條目 ID、顯示純文字無結果與 Esc 清除，並檢查沒有新增 Core 讀寫或更動套件資料。
