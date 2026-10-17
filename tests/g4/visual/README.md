# QML 視覺回歸（開發證據）

執行 `bash tests/g4/visual/run.sh <evidence-dir>`。需要本機 Qt 6.10.2、Node 與系統 Python 的 Pillow；以 `QT_PREFIX`、`DITTO_QMLTESTRUNNER` 指定工具鏈。Quickshell 由 `stubs/` 替代，layer-shell 行的移除與來源雜湊記在 `staging.json`。這些 offscreen 結果不代表實體座位、合成器、鍵盤、無障礙或效能驗收。

`unit/tst_accent_foreground.qml` 檢查無主題、`soft-jelly`、`soft-jelly-light` 的預設值、Profile `on_accent` 初始及即時覆寫、移除覆寫、無效色值，以及尚未收到 projection 的預設值。QML 使用 `accentForeground`，避免 `on` 加大寫字母被當成訊號處理器；Profile 的鍵名不變。

`unit/tst_tokens.qml` 以 WCAG 相對亮度公式計算三種主題的 accent 文字對比，門檻 4.5。#72 未改任何 fallback 色值。

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
