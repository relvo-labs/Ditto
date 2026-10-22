# D-50 Shell 擴充契約的五項工程選擇（#159 §10）

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-22 |
| 狀態 | 已決定（安全預設，待 owner 檢視） |
| 決策者 | coordinator，依 owner 對安全預設的事先授權；五項都不改變產品權威，因此未升級給 owner。owner 可於檢視時推翻，推翻須另寫新紀錄 |

編號說明：D-49 已由尚未合併的 PR #147 保留，本紀錄使用 D-50。契約內容見 [docs/contracts/shell-extensions.md](../../../docs/contracts/shell-extensions.md)。

## 結論

1. **設定頁採多條目 area，不另建 registry。** 新增 area `ui.settings_page`；頁面 metadata 為 manifest 的選用欄位 `settings_page: { page_id, title_key, order, category? }`。缺宣告與重複 `page_id` 在預檢以 `schema_invalid` 拒絕（`settings_page_missing`、`duplicate_page_id`），顯示順序固定為 `(order, page_id)`。`composition`、`plugins`、`history`、`personalization`、`ai` 五個內建 id 維持相容命令的目標；同 id 的套件頁取代內建頁，內建頁是可信備援。
2. **跨信任設定擴充先採宣告式表單。** P02／P03 只把可信內建 QML 頁嵌入設定視窗；第三方設定由可信宿主依 `config_schema` 繪製表單，寫入走 `set_entry_config` ChangeSet，在 P03／P07 建置。表單的前提是 Core 在預檢依 `config_schema` 驗證寫入的 `config`：現行 Core 只檢查 `config` 是物件（`crates/ditto-core/src/docops.rs:154-162`、`:225-230`），`config_schema` 只由 SDK 在作者端檢查；補上前表單不得啟用。第三方 QML 永不嵌入可信設定視窗；獨立 surface 等 #154／#155。
3. **UI 暫態只在 Shell 程序記憶體。** 由 renderer 之外的 Shell facade 持有：受控切換時保留，Shell 崩潰或重啟後不保留；聊天草稿與未送出的附件一併遺失。不寫入 Profile、revision 或匯出，本階段不新增 Core 儲存；每頁草稿序列化後 ≤64 KiB。
4. **UI SDK 是 Shell 擁有的 qmldir 模組。** 位置 `shell/sdk/Ditto/Ui/qmldir`，條目引用既有 `shell/ui`、`shell/change` 原始檔；套件以 `import "root:/sdk/Ditto/Ui"` 取得。主版本放在路徑，相容範圍暫以 `required_protocol_version` 表達。
5. **舊 Profile 不遷移，走內建 fallback。** 沒有 `ui.background` 綁定或 `ui.settings_page` 成員時，Shell 顯示內建背景與內建頁，回報為 fallback。只有新 store 綁定官方套件；既有 Profile 經明確 ChangeSet 採用（P06）。

P02 的契約形狀（全部是選用欄位，依 D-39 相容規則加入，與 `artifact_id` 相同）：`SLOTS += "ui.background"`；`AREAS += "ui.settings_page"`；`ShellSlotBinding.settings_page`；`PanelMount` 新增選用 `package`、`version`、`page_state: registered | open`。設定頁以「已註冊於導覽」為回讀成功，`open` 只是資訊。

## 依據

**第 1 項**：area 機制已具備所需語意，不需新權威路徑。成員資格由 Core 寫入 `EntrySpec.area`（`crates/ditto-protocol/src/profile.rs:26-30`、`:57-61`）；預檢已有 `not_a_provider_for_area`、`wrong_host`、`unknown_area`、`placed_twice`（`crates/ditto-core/src/preflight.rs:215-242`、`:488-510`）；area 成員以 `entry_id` 逐項回讀（`crates/ditto-core/src/projection.rs:308-354`）。現行設定頁是固定 id 與 `sourceComponent` 分支（`shell/centers/Centers.qml:37-43`、`:263-275`），命令由 `shell.qml:177-202` 對應到頁面 id。

**第 2 項**：預檢只放行 `source: builtin` 且 `trusted` 的套件（`preflight.rs:328-352`），所有可信 QML 供應者同在 Shell 程序、無隔離（`shell/core/ProviderHost.qml:28-30`）。同程序沒有能擋住惡意程式碼的邊界，嵌入第三方 QML 等於把它當成可信程式碼。

**第 3 項**：現行聊天草稿已只在記憶體（`shell/chat/ConversationState.qml:75`；[agent-0.3.md §3](../../../docs/contracts/agent-0.3.md)），附件內容留在 Core（`:77-80`），但未送出的附件跟著 Shell 的連線：連線結束時 Core 釋放該連線持有、尚未綁定 turn 的 context（`crates/ditto-core/src/lib.rs:795-800`、`context.rs:459-464`），所以 Shell 崩潰或重啟後未送出的附件也遺失；已保存的會話與 turn 仍在 Core。跨崩潰保留需要另定保存期限與隱私政策，不能順手塞進 Profile（[ditto-authority-boundaries](../../skills/ditto-authority-boundaries/SKILL.md) 第 3 步：UI 暫態不進 Profile 匯出）。

**第 4 項**：Quickshell 多檔案解析 spike。環境：開發 VM 上的 Quickshell 0.3.1（rev `1a4716c`），offscreen，與執行中的工作階段分開；以 `Qt.createComponent("file:///…")` 載入，與 `ProviderHost` 相同。**只是開發證據**，不是登入工作階段或參考機證據。摘要由 coordinator 保存在執行紀錄，未進版控；下表即其摘要：

| 案例 | 情形 | 結果 |
| --- | --- | --- |
| 1–3 | 套件以絕對 URL 載入：同目錄型別、相對子目錄、非同步 incubate | 可 |
| 4、6 | import 絕對目錄（含 Shell 的 `ui`） | 可 |
| 5 | 同一 engine 兩個套件各 import 不同版本 SDK 目錄 | 可 |
| 7 | 設定資料夾內檔案以相對路徑 import 資料夾外目錄 | 失敗（`TypeB is not a type`），即現行 README 記載的限制 |
| 8 | import `"root:/ui"`（無 `qmldir`） | 失敗（部分解析） |
| 9 | import `"root:/sdk/Ditto/Ui"`（有 `qmldir`） | 可 |
| 15 | `qmldir` 條目指向目錄外檔案（`../../../ui/…`） | 可，不需複製 |
| 10 | `import Ditto.Ui 1.0`，無 import path | 失敗 |
| 11、12、14 | 同上，Shell 環境或 `//@ pragma Env` 帶絕對 `QML_IMPORT_PATH`；兩個主版本並存 | 可 |
| 13 | `pragma Env` 用相對路徑 | 失敗 |

案例 9 與 15 證明不需任何環境變數即可取得多型別 SDK；URI 形式（11～14）可行，但需要絕對路徑進入每一個啟動 Shell 的地方。

**第 5 項**：D-48 已確立「只有新建 store 採新預設、既有 store 不改寫」的做法（`crates/ditto-core/src/defaults.rs:110-117`；[D-48](2026-10-17-d48-default-assistant-entry.md)）。Profile 沒有背景或設定頁綁定時，Shell 今天本來就顯示內建背景與內建頁（`shell/shell.qml:352-403`），維持這個行為不需要寫入任何文件。

## 考慮過但沒選的方案

- **第 1 項**：專用 contribution registry（新資料表與能力）。為已由 area 提供的成員語意另開一條權威與交易路徑，違反「權威只有一份」。以條目順序決定頁面順序：排序會隨新增、移除而變，不具確定性。
- **第 2 項**：現在就把社群 QML 嵌入設定視窗。同程序無隔離，等於讓第三方取得可信設定宿主的全部能力；#155 未就緒前不能如實宣稱安全。
- **第 3 項**：P02 就建立 Core 管理的 UI 暫態儲存。需要容量、期限、清除與隱私政策，且會成為新的持久狀態類別；延後為獨立後續工作。寫入 Profile：會進匯出與 revision，違反所有權表。
- **第 4 項**：URI 模組＋`QML_IMPORT_PATH`（案例 11～14 可行）。需要 Core 啟動器、systemd unit 與每一個測試 harness 都帶絕對路徑，相對路徑不生效（案例 13）；隨 #151 封裝再評估。把 SDK 檔案複製進每個套件：版本漂移，修正無法統一送達。維持「供應者必須單一檔案」：spike 證明限制被高估，會讓官方頁面無法合理拆檔。
- **第 5 項**：啟動時自動遷移，替舊 Profile 補上官方套件綁定。屬靜默改寫使用者組合，違反 CFG-06 與 D-48 的做法；也會讓舊版 Core 讀不到文件。

## 影響

- **P02（最小切片）**：Rust 型別、schema 與 TS 產物、SDK 規則、預檢兩個新原因、`check_shell` 比對 package／version、`ProviderHost`／`SlotHost` 的頁面註冊與只編譯的 prepare、`Centers` 改用 `flickable` 契約、內建背景的顯示切換、`shell/sdk/Ditto/Ui/qmldir`、修正 `shell/README.md` 的單一檔案規則。逐檔清單見契約第 12 節。
- **P03**：五個官方頁套件化與外框替換；宣告式表單（前提是 Core 端 `config_schema` 驗證）；新 store 綁定官方頁；設定頁的圖示、可用條件與所需能力欄位定案（契約第 4.1 節，所需能力只是請求，不授予權限）。
- **P06**：既有 Profile 的明確採用入口；token 套件形態。
- **P07**：第三方設定擴充與信任矩陣延伸。
- **#154／#155**：第三方 QML、獨立 surface 與能力代理仍是第三方接入的門檻；本決策不放寬 `trust_policy`。
- **#151**：URI 模組形式隨封裝與 runtime 工作重新評估。
- **未驗證**：真實登入工作階段；同一 URL 內容改變後的替換；`root:/` 路徑形式下兩個主版本並存。這些須在 P02／P03 補證據。
- G1～G4 的驗收結論與門檻不變。PRD 的增量列為提案（契約第 13 節），本決策不修改 PRD。
