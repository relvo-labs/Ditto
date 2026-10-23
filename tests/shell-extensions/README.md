# UI-P02／P03a 離屏驗證

先載入 runner 的 env.sh，再執行 `bash tests/shell-extensions/run.sh <evidence-dir>`。
這是開發環境證據，對應 #159 的 UI-AT02、UI-AT07、UI-AT10 最小切片；不代表整組驗收完成。

測試載入實際 ProviderHost、SlotHost、Centers、SettingsPageContainer、BackgroundFallback 與背景套件。
檢查 prepare 沒有頁面實例、commit 登錄與版本身分、升版後 rollback、abort、語法錯誤、
內建頁取代與額外頁排序、開關視窗的實例生命週期、建立失敗後備援，以及背景顯示交接。
頁面可選 flickable；普通 Item 不取得捲動或 FocusReveal 假設。
History、Composition、Plugins 三個真實官方頁使用同一組資料驅動測試：套件取代同 id 內建分頁，
無重複分頁；無關提交保留頁面實例、分頁物件與鍵盤焦點；建立失敗改用可信內建頁，rollback 再恢復套件。

qmltestrunner 沒有 Quickshell 的 `root:/` scheme，也沒有 layer-shell。`stage.py` 在 evidence 目錄複製
來源，僅移除 Wayland import／WlrLayershell 附加屬性行，並將 SDK 的那一條 import 改成絕對 file URL。
`staging.json` 保存來源雜湊與逐行移除清單。沿用 G4 視覺測試的 Quickshell stubs，另以 Instantiator
模擬 Variants 的 model/delegate 生命週期；不把這些測試當成輸入穿透、圖層或實體輸出熱插拔證據。

腳本另外將真實 History、Composition、Plugins 套件封裝並解開至 config root 外的套件庫，以絕對 `file://` URL 載入；
SDK／ui／change／jelly／centers 位於 config root 的微型設定中，
以真正 Quickshell、原封不動的 `root:/sdk/Ditto/Ui` import 建立頁面，檢查頁面屬性與測試 client 的讀取結果，
包含 SDK 提供的 GeneratedArtifacts。這不是與真實 Core 連線的證據。
Quickshell 的記錄、runtime、cache 都在 evidence 目錄；離屏環境無法建立 IPC socket 時會印出錯誤，
頁面載入判定仍依實例檢查。ui/change 的 qmldir 是共用元件相依型別解析所需，不是元件副本。

尚未驗證：真實登入、同 URL 改檔後熱換、同一次 commit 內的合成器逐幀背景交接、實體多輸出／輸入穿透、
Orca、效能與長跑、插件中心自我升版時已受理操作的對帳與草稿／焦點交接。
可信內建 QML 與 Shell 同程序，沒有逐插件強隔離。
