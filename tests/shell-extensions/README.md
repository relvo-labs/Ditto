# UI-P02／P03a／P03b 離屏驗證

先載入 runner 的 env.sh，再執行 `bash tests/shell-extensions/run.sh <evidence-dir>`。
這是開發環境證據，對應 #159 的 UI-AT02、UI-AT07、UI-AT10 最小切片；不代表整組驗收完成。

測試載入實際 ProviderHost、SlotHost、Centers、SettingsPageContainer、BackgroundFallback 與背景套件。
檢查 prepare 沒有頁面實例、commit 登錄與版本身分、升版後 rollback、abort、語法錯誤、
內建頁取代與額外頁排序、開關視窗的實例生命週期、建立失敗後備援，以及背景顯示交接。
頁面可選 flickable；普通 Item 不取得捲動或 FocusReveal 假設。
History、Composition、Plugins、Personalization、AI 五個真實官方頁使用同一組資料驅動測試：套件取代同 id 內建分頁，
無重複分頁；無關提交保留頁面實例、分頁物件與鍵盤焦點；建立失敗改用可信內建頁，rollback 再恢復套件。

qmltestrunner 沒有 Quickshell 的 `root:/` scheme，也沒有 layer-shell。`stage.py` 在 evidence 目錄複製
來源，僅移除 Wayland import／WlrLayershell 附加屬性行，並將 SDK 的那一條 import 改成絕對 file URL。
`staging.json` 保存來源雜湊與逐行移除清單。沿用 G4 視覺測試的 Quickshell stubs，另以 Instantiator
模擬 Variants 的 model/delegate 生命週期；不把這些測試當成輸入穿透、圖層或實體輸出熱插拔證據。

AI 套件與內建備援使用相同 `ConversationState.aiSettings`，測試確認回讀會更新、來源物件與聊天欄位／動作不可讀、屬性不可重新指派、設定動作委派與金鑰只回讀引用；宣告但初值為 undefined 的選用輸入仍會注入，facade 更新不重建頁面；未宣告 `aiSettings` 的頁面不取得該屬性。Personalization 套件不取得未使用的 `providers`。

腳本另外將真實 History、Composition、Plugins、Personalization、AI 套件封裝並解開至 config root 外的套件庫，以絕對 `file://` URL 載入；
SDK／ui／change／jelly／centers／chat 位於 config root 的微型設定中，
以真正 Quickshell、原封不動的 `root:/sdk/Ditto/Ui` import 建立頁面，檢查頁面屬性與測試 client 的讀取結果，
包含 SDK 提供的 GeneratedArtifacts。這不是與真實 Core 連線的證據。
Quickshell 的記錄、runtime、cache 都在 evidence 目錄；離屏環境無法建立 IPC socket 時會印出錯誤，
頁面載入判定仍依實例檢查。ui/change 的 qmldir 是共用元件相依型別解析所需，不是元件副本。

尚未驗證：真實登入、同 URL 改檔後熱換、同一次 commit 內的合成器逐幀背景交接、實體多輸出／輸入穿透、
Orca、效能與長跑、插件中心自我升版時已受理操作的對帳與草稿／焦點交接。
可信內建 QML 與 Shell 同程序，沒有逐插件強隔離。

G4 視覺 fixture 的 Centers 輸入同樣改為 `aiSettings`；舊版像素對照仍用舊的 `conversation` 輸入。
`stage-assistant.py` 只逆轉 Shell 中那一行 facade 接線後，再與原先固定的整份 Shell 比對，保留其他結構斷言。

R1 修正另驗證兩個控制器的 inline facade 各自綁定擁有者；AI 內建頁與套件在未提供 facade 時，
逐一觸發所有按鈕、選項與開關，不產生動作或 TypeError／ReferenceError。

#183 R1：外部套件測試以 manifest 的版本建立 archive／解包路徑，不再假設五頁都是 1.0.0。
插件頁供應者因新增搜尋升至 1.1.0；runtime fixture 從實際解包的 manifest 建立完整 PackageSummary，
以 production-shaped EntryStatus（無虛構名稱欄位）與 manifest 描述驗證套件 ID、條目 ID、描述、無結果，
並在查詢不變時切換 zh-TW／en，確認真正 `root:/sdk/Ditto/Ui` 的 PluginFilter 執行、重新篩選且不呼叫 Core。
兩份實際頁面的 markup、符號、引號與 CJK 查詢另以表格檢查 `Text.PlainText` 及字面匹配。

部署限制：新 archive 是 `ditto.settings.plugins-1.1.0.dittopkg`。安裝新版不會自動改變既有 Profile 的精確版本綁定；
仍固定 1.0.0 的條目須經明確的既有升版 ChangeSet 才啟用新版。本修復不更動 live Profile，也不處理 #144。

#188：`run.sh` 最後以真正 Quickshell（offscreen）在裝置縮放 1 與 2 下載入兩個啟動器，逐列檢查五種圖示來源。
主題名稱經 `Quickshell.iconPath(name, true)` 解析為 `image://icon/…` 並載入成功；
絕對 PNG 路徑直接載入；未知名稱與無圖示改用首字；檔案存在但無法解碼時為 `Image.Error`，同樣改用首字。
每個圖示的 `sourceSize` 須為 `ceil(顯示尺寸 × 裝置縮放)`。
主題 `DittoLauncherTest` 是證據目錄中的 fixture（`launcher-icon-theme/index.theme` 加上 G4 的 `raster-icon-256.png`）。

Qt 的 offscreen 平台沒有圖示搜尋路徑（`QIcon::themeSearchPaths()` 只有 `:/icons`），主題查找一律失敗。
因此以測試專用的 LD_PRELOAD `icon-search-paths.cpp` 設定 `$XDG_DATA_DIRS/icons`，與 Wayland／X11 平台主題相同；其餘查找仍由 Quickshell 自己完成。
沒有 Wayland 合成器時 Quickshell 沒有 PanelWindow 後端，`stage-launcher.py` 因此把 layer-shell 視窗改成 FloatingWindow。
它另外移除 layer-shell 屬性與 `focusable`，並加一行 `stagedSurface` 讓測試找到圖示；每條規則須命中預期行數，改動逐行記在 `launcher-icons/staged/staging.json`。
offscreen 的 FloatingWindow 不回傳 `grabToImage`，像素清晰度因此由 G4 視覺測試的 `check_launcher_icons.py` 比較。
這裡不驗證實際桌面圖示主題、layer-shell、合成器縮放或實體 HiDPI 螢幕。
