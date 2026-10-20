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
| `accent-LauncherGrid-<theme>` | 目前分類與應用程式首字 |
| `accent-LauncherSearch-<theme>` | 已選搜尋結果 |
| `accent-TasksPanel-<theme>` | 示範資料標籤（使用 warning 背景） |

`<theme>` 為 `no-theme`、`soft-jelly`、`soft-jelly-light`。後四類使用標明的 fixture 資料；管理中心的 Core 呼叫回報不可用，沒有實際寫入。FloatingWindow 替身只呈現內容；不驗證原生視窗行為。原始 PNG 在 `.staged/out/`，擷取後可複製到證據目錄；PanelTop 的時鐘是擷取當下時間，比較時須另辨識時鐘差異。

狀態元件的控制項圖與 TasksPanel 圖另外擷取 `-reduced-transparency`、`-low-power` 兩種後綴，覆蓋全部三種主題。

## #116 Soft Jelly 應用風格（三種可選，預設 J1）

`run.sh` 另外執行：`stage-ui116.mjs`（把 `87a2462` 與目前的 `shell/ui`、`jelly`、`centers`、`chat`、`change`、`assistant`、`avatar`、`dock_pill` 並排放到 `.staged/ui116/`，只移除 layer-shell 行）、`unit/tst_ui_style.qml`（風格來自 Profile token `ui_style`、預設 J1、非法值＝J1、深色與無主題不受影響、提交後即時切換；新元件的鍵盤／名稱／角色、減少動畫、降低透明度、對比）、`unit/tst_ui_style_off.qml`（深色主題（也含設了 `ui_style`）與無主題時與基底逐像素相同）、`unit/tst_ui_style_pages.qml`（卡片動作、AI 關閉空狀態、確認視窗預設拒絕）、`unit/tst_ui_style_layout.qml`（1600×900：設定標題避開待辦面板、捲到底、Tab 捲入、compact 對話的角色／分頁／範例／輸入框不重疊、AI 關閉沒有「新對話」、J3 視窗鈕與灰字對比、個人化中心「外觀風格」的鍵盤與無障礙；把較早的樹以 `tree` 指向即可做 RED）、`unit/tst_ui_style_dock.qml`、`capture/ui_contrast.py`（各風格文字疊在桌布每個像素與黑色上的最小對比），以及 `capture/tst_apps_candidates.qml`：J1／J2／J3（由 Profile token 選）各十張 1280×800（組合中心一般／降低透明度／低效能／`⋯` 選單、個人化、AI 設定、對話 AI 關閉、角色旁 compact 對話 AI 關閉、對話進行中＋確認、Dock 缺圖示），複製到 `<證據目錄>/candidates/`，由 `capture/compose_candidates.py` 產生三欄與手機直式比較板和 `candidates.json`。資料都是 `fixtures/AppFixtureClient.qml`、`ConversationFixture.qml` 的標明 fixture；offscreen 沒有 Qt／Wayfire 的視窗標題列與陰影。標題列與 foot 的設定檔另由 `tools/ui-candidates/check-styles.py`（`selftest.sh`）檢查。
