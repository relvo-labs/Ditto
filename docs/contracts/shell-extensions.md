# Shell 擴充契約：surface、設定頁與佈景

| 欄位 | 內容 |
| --- | --- |
| 狀態 | **提案；P02 實作中**（#159 UI-P01 產出） |
| 決策 | [D-50](../../.agents/notes/decisions/2026-10-22-d50-shell-extension-contracts.md) |
| 型別權威 | P02 落地後為 `crates/ditto-protocol`（`profile`、`manifest`、`participant`）→ `schema/*.json` |
| 基準 | `main@d063f03` |

## 1. 狀態與權威

- 本文是 #159 的**提案契約**。標示「現行」的內容描述 `main@d063f03` 已有的程式碼；標示「P02 實作中」的形狀尚未進入程式碼，不得當作已支援。
- P02 合併後，欄位的確切形狀以 Rust 型別與產生的 schema 為準；本文只描述語意與不變量。兩者不一致時是缺陷，以 Rust 型別為準修正本文（同 [README](README.md)）。
- 本文不改變 G1～G4 的驗收結論，也不宣稱既有版本已支援下述契約。官方介面抽取完成前，Shell 仍直接組裝背景、設定視窗、對話與助理（`shell/shell.qml`）。

## 2. 三種擴充面

| 項目 | surface provider | embedded page | theme／style |
| --- | --- | --- | --- |
| 例 | Dock、啟動器、面板；P02 新增 `ui.background` | 設定頁；P02 新增 area `ui.settings_page` | token recipe、UI SDK 樣式、完整組合 |
| Profile 位置 | `slots[<slot>] = entry_id`（單一供應者） | 條目的 `area: "ui.settings_page"`（多條目） | `appearance.theme`、`appearance.tokens`；組合即整份 Profile |
| manifest | `plugin_kind: qml_provider`、`host_kind: qml`、`slots: [<slot>]`、`qml_entry`、`hot_swap` | 同左，`slots: ["ui.settings_page"]`，另加 `settings_page`（P02 實作中） | P02 不新增；token 套件形態屬 P06 |
| 宿主 | `ProviderHost`／`SlotHost` | 設定視窗（現行 `Centers`）提供視覺 parent | `jelly/Tokens.qml`；樣式元件來自 UI SDK |
| 根物件 | `Scope`，自己擁有 layer-shell 視窗 | `Item`，不是 `Scope` | 無（宣告值） |
| 回讀鍵 | slot 名稱 | `entry_id` | `appearance` |

### 2.1 surface provider（單一 slot）

現行契約見 [shell/README.md](../../shell/README.md)「UI 供應者」：根為 `Scope`，取得 `client`、`tokens`、`config`、`screen`、`slotName`、`entryId`、`shown`，宣告 `reservedEdge`、`ready`、`healthy()`、`release()`。

| 階段 | 行為（現行，`shell/core/SlotHost.qml`） |
| --- | --- |
| prepare | 非同步編譯與 incubate，`shown: false`：無表面、無保留區、無輸入區；`ready` 後 2 秒內 `healthy()`；載入上限 6 秒（`SlotHost.qml:179-211`、`:309-330`） |
| commit | 舊的 `release()` → 候選 `shown = true`；舊實例成為 retired（`:215-237`） |
| rollback | 釋放新的，恢復**同一個** retired 實例（`:240-261`） |
| retired | 保留到下一次 prepare 或 20 秒（`retireMs`，`:38`）；過期後 rollback 回 `not_restored`。晚於保留期的撤銷是新的 ChangeSet，由版本化套件重建，不是同一實例 |

成功判準：`PanelMount.mounted && visible`（`crates/ditto-core/src/projection.rs:317-337`）；P02 起，`ui.background` 另須回報的 `package`／`version` 與綁定相同（見第 9 節）。

### 2.2 embedded page（多條目 area）（P02 實作中）

- 根是 `Item`，由設定宿主放進自己的內容區；頁面**不**自建視窗、不取得 layer-shell 表面、保留區或輸入區。不得不經適配就把 `Scope` 契約套到頁面。
- 宿主給頁面 `client`、`tokens`、`config`、`pageId`、`entryId`。頁面可宣告 `flickable`（一個 `Flickable`），供捲動與焦點捲入使用。
- 頁面只在設定視窗開著時建立（RUN-07，沿用 `shell.qml:376-403` 的 `LazyLoader`）。

| 階段 | 行為 |
| --- | --- |
| prepare | 只編譯元件到 `Component.Ready`，**不建立實例**；編譯失敗回 `failed` |
| commit | 把綁定註冊進導覽；設定視窗開著時，下一次開啟該頁才建立實例 |
| rollback | 恢復前一個綁定的註冊；退休的是綁定與已編譯元件，不是實例 |
| retired | 同 20 秒規則；設定視窗正顯示被替換頁時的草稿與焦點交接屬 P03 |

因為 prepare 不建立實例，頁面不需要 `ready`、`healthy()`、`release()`。回讀見第 4、9 節。

### 2.3 theme／style（三層）

| 層 | 內容 | 現行或計畫 |
| --- | --- | --- |
| token recipe | `appearance.theme` 選配方，`appearance.tokens` 逐項覆寫；值依 `APPEARANCE_TOKENS` 與 `token_choices` 預檢（`crates/ditto-protocol/src/profile.rs:205-355`）。提交時套用、回復時還原前值（`shell/core/ProviderHost.qml:402-411`、`:456-463`），不需要退休實例 | 現行；token 套件形態屬 P06 |
| 版本化 UI SDK 樣式 | 控制項與材質實作；J1／J2／J3 由 `ui_style` token 選擇（`profile.rs:333-347`）；P02 起以 `root:/sdk/Ditto/Ui` 提供給套件（第 9 節）。屬可信 Shell 程式碼，不是套件 | 樣式現行；SDK 路徑 P02 實作中 |
| 完整組合 | Profile 以精確 `(package, version)` 綁定各 slot 與 area，加上 `appearance`；切換組合走 ChangeSet | 現行機制；新增 slot 的組合屬 P06 |

回讀限制：`appearance` 目前比對的是 Shell 回報的 appearance 物件（`projection.rs:356-360`），不是實際繪製結果。樣式正確性仍須視覺與互動證據（#159 §3.4、§8）。

## 3. 合約欄位對照（#159 §3.1）

| #159 要求的欄位 | 既有位置 | 是否新增 |
| --- | --- | --- |
| `contract_version` | `manifest_version`（固定 `1`）＋`required_protocol_version`（semver 範圍，對 `PROTOCOL_VERSION = "0.3.0"` 預檢，`preflight.rs:300-306`）；UI SDK 主版本在路徑中 | 否 |
| `entry_id` | `EntrySpec.entry_id`、`ShellSlotBinding.entry_id`、`PanelMount.entry_id` | 否 |
| package／version | `EntrySpec.package`／`version`、`Manifest.id`／`version`、`ShellSlotBinding.package`／`version` | `PanelMount.package`／`version` 為**新增選用欄位**（P02） |
| content hash | 套件庫既有的 sha256：整個 `.dittopkg` 的雜湊，安裝於 `packages/sha256/<sha256>/`（[manifest.md](manifest.md)「套件格式」）；匯出的 `PackageLock.sha256`；預檢比對 tree digest（`preflight.rs:272-283`） | 否。**不是新的 manifest 欄位** |
| 支援 slot | `Manifest.slots` | 新增值：`SLOTS += "ui.background"`、`AREAS += "ui.settings_page"`（P02） |
| 宿主模式 | `plugin_kind`／`host_kind`、`EntrySpec.host`；`ui.*` 一律對應 `qml`（`projection.rs:59-77`）。surface 與 page 由 slot／area 區分 | 否 |
| 權限 | `Manifest.permissions`，是請求不是事實 | 否（限制見第 6 節） |
| 熱換等級 | `Manifest.hot_swap`；`hot_swap_level` 取觸及條目的最高值（`projection.rs:251-283`） | 否 |
| 狀態 schema | `config_schema`（描述 Profile 內 `config`）；`data_schema`（插件資料，記錄）。限制：Core 目前**不**依 `config_schema` 驗證，`add_entry`／`set_entry_config` 只檢查 `config` 是物件（`crates/ditto-core/src/docops.rs:154-162`、`:225-230`）；`config_schema` 只由 SDK 在作者端檢查（`packages/host-sdk/src/manifest/rules.ts:202-209`） | 否。UI 暫態不進 manifest，見第 7 節；Core 端驗證是宣告式設定表單的前提，見第 6 節 |
| 預設／備援供應者 | 新 store 的預設由 `crates/ditto-core/src/defaults.rs` 決定；背景與五個內建頁的備援是 Shell 內建實作 | 否 |
| 設定頁 metadata | — | **新增** manifest 選用欄位 `settings_page`；`ShellSlotBinding.settings_page`（自 manifest 投影，無則省略）（P02）。圖示、可用條件與所需能力待定，屬 P03（第 4.1 節） |
| 設定頁回讀狀態 | — | **新增** `PanelMount.page_state: registered | open`（P02） |

新增欄位全部是選用欄位，依 D-39 相容規則與 `artifact_id` 同樣的方式加入：既有 manifest 與 Profile 不含它們，序列化結果與雜湊不變。

## 4. 設定頁契約（P02 基礎宿主；P03a 官方頁套件）

### 4.1 宣告

```json
"slots": ["ui.settings_page"],
"settings_page": { "page_id": "plugins", "title_key": "…", "order": 200, "category": "…" }
```

| 規則 | 內容 |
| --- | --- |
| `page_id` | `^[a-z][a-z0-9_]{0,31}$` |
| `title_key` | 翻譯鍵；第三方套件的譯文來源不在 P02 範圍 |
| `category` | 選用 |
| 缺宣告 | `ui.settings_page` 成員的 manifest 沒有 `settings_page` → `schema_invalid`，`why: settings_page_missing` |
| 重複 | 兩個**未停用**成員宣告同一 `page_id` → `schema_invalid`，`why: duplicate_page_id`；停用的成員不計 |
| 排序 | 依 `(order, page_id)` 排序，確定性；不使用條目在 `entries` 中的順序 |
| 既有 area 規則 | 沿用 `not_a_provider_for_area`、`wrong_host`、`unknown_area`、`placed_twice`（`preflight.rs:215-242`、`:488-510`）與 `diff.area.joined`／`left` |
| 圖示（**待定**，P03） | 提案選用欄位，暫名 `icon`；格式與來源待定 |
| 可用條件（**待定**，P03） | 提案選用欄位，暫名 `available_when`；決定頁面何時出現在導覽，條件語言待定 |
| 所需能力（**待定**，P03） | 提案選用欄位，暫名 `required_capabilities`；列出頁面需要的能力 id。這是請求，是否可用由 Core 判定，宣告本身不授予任何權限 |

後三項不屬於 P02 形狀：P02 的 `settings_page` 只有 `page_id`、`title_key`、`order`、`category`，欄位名稱與語意由 P03 定案。

### 4.2 內建頁與替換

| `page_id` | 官方套件 | 可信內建備援 | 相容命令 |
| --- | --- | --- | --- |
| `composition` | `ditto.settings.composition`（order 10） | `CompositionCenter` | `composition.open` |
| `plugins` | `ditto.settings.plugins`（order 20） | `PluginCenter` | `plugins.open` |
| `history` | `ditto.settings.history`（order 30） | `HistoryCenter` | `history.open` |
| `personalization` | 尚無；仍為內建頁 | `PersonalizationCenter` | `personalization.open` |
| `ai` | 尚無；仍為內建頁 | `AISettings` | `ai_settings.open` |

- P03a 沿用 History 的套件形態抽出組合與插件頁；行為、字串與布局保持相同。三個套件皆為 `source: builtin`、`trust_level: trusted` 的 `qml_provider`，共用 `ui.settings_page` 契約，不依套件名稱增加掛載分支。
- 個人化與 AI 頁分別依賴 `providers`／`conversation`；須先拆分 facade，留待 P03b。設定外框替換、草稿／焦點交接與中心自我升版的整組驗收不在 P03a。
- `GeneratedArtifacts` 由 Shell 擁有，SDK qmldir 以 `../../../centers/GeneratedArtifacts.qml` 引用原檔，供插件套件與內建備援共用，不複製元件。
- P03a 不在新 store 預設文件或既有 Profile 加入綁定；套件採用留待 P06 的明確 ChangeSet。

- 已註冊的套件頁若 `page_id` 等於內建 id，就取代該內建頁；同一 id 只會有一個可見頁。
- 沒有成員提供該 id，或成員載入失敗時，內建頁是可信備援。這是相容投影，回報為 fallback，不回報為套件已載入。
- 內建頁以固定的 `order` 參與同一排序；數值由 P02 以常數定義，現行相對順序（`shell/centers/Centers.qml:37-43`）不變。

### 4.3 捲動、焦點與尺寸

- 宿主**不得**假設頁面是 `Flickable`。現行 `Centers.qml:76` 以 `content.item as Flickable` 取頁面，`:280-294` 的捲軸讀 `contentHeight`／`contentY`；P02 改為讀頁面宣告的 `flickable`，沒有宣告時不顯示捲軸、不做焦點捲入。
- 頁面的尺寸跟隨宿主給的內容區；頁面不得設定視窗大小或位置。
- 鍵盤：PageUp／PageDown 與焦點捲入只作用在 `flickable`；焦點遺失時的回復（`Centers.qml:80-93`）由宿主負責。

### 4.4 回讀

- 註冊即回讀成功：`PanelMount.mounted && visible` 表示「已註冊於導覽」，鍵為 `entry_id`。
- `page_state: open` 只是資訊，**永遠不是**提交判準；尚未開啟的頁面不冒充已呈現。
- 開啟時才建立實例；開啟失敗不改變已提交的回讀。內建 id 改顯示內建頁；非內建 id 顯示產品語言的失敗說明與重試入口。開啟失敗的回報欄位尚未定案。

## 5. 背景契約（P02 實作中）

| 項目 | 內容 |
| --- | --- |
| slot | `ui.background`，單一供應者，QML，根 `Scope`，`reservedEdge: "none"` |
| 視窗 | 每個輸出一個 Background 圖層視窗（同現行內建背景：`shell.qml:352-374` 以 `Variants` 走 `Quickshell.screens`、`WlrLayer.Background`、`ExclusionMode.Ignore`）。不得有 exclusive zone 或輸入區 |
| 熱插拔 | 供應者自己跟隨 `Quickshell.screens` 增減視窗；`SlotHost` 給的 `screen` 只是主輸出，不能只靠它 |
| 內建備援 | 沒有供應者顯示時，Shell 顯示內建背景（`jelly/Backdrop.qml`）；供應者提交且 `shown` 後隱藏內建背景；release 或 rollback 後再顯示 |
| 回讀 | 鍵 `ui.background`；`mounted && visible`，且回報的 `package`／`version` 與綁定相同。沒有綁定時沒有這一項；內建背景不冒充套件 |
| 不在 P02 | 逐輸出的可見回讀、桌布檔案欄位（`Backdrop.qml` 註解：#51 未定）、雙螢幕與縮放證據（UI-AT11） |

## 6. 信任矩陣

| 來源 | 在 Shell 程序載入 | 嵌入設定視窗 | 權限 | 隔離宣稱 | 門檻 |
| --- | --- | --- | --- | --- | --- |
| 官方內建 QML（`source: builtin`、`trust_level: trusted`） | 可 | 可（唯一可嵌入的一類） | 經宿主給的 `client`，以 Shell 身分呼叫 Core，授權仍由 Core 判定。manifest 的 `permissions` 目前只對 Cordis 條目預檢（`preflight.rs:604-623`） | **無**：同程序，無逐插件故障隔離 | 現行預檢已允許 |
| 社群 QML（非 `builtin` 或非 `trusted`） | 不可：預檢 `precondition_failed`（`why: trust_policy`，`preflight.rs:328-352`） | 不可 | — | 無 | #154 獨立宿主＋#155 |
| 生成（固定模板） | 只以固定模板 `shell/generated/GeneratedPanel.qml` 呈現已核准且完整性相符的 artifact；位置限 `ui.generated_panel`（≤8） | 不可 | artifact 以描述資料傳入模板（`projection.rs:104-118`），不提供程式碼 | 模板是可信程式碼；生成內容是資料 | 任意生成 QML 依 #154／#155 |
| 第三方設定擴充 | 不載入其 QML | 只以宣告式表單：可信宿主依條目的 `config_schema` 繪製，寫入經 `set_entry_config` ChangeSet（P03／P07 建置，不在 P02）。前提：Core 須先在預檢依 `config_schema` 驗證寫入的 `config`；現行只檢查是物件（第 3 節），補上前表單不得啟用 | 讀寫 scope 分開；自填 `entry_id` 或 manifest 自述不取得身分 | 表單不執行其程式碼；獨立 surface 的隔離由 #155 定 | 表單待 Core 端 `config_schema` 驗證；獨立 surface 待 #154／#155 |
| 佈景 token 套件 | 不載入程式碼，只有 token 值，經 `APPEARANCE_TOKENS` 預檢 | 不適用 | 無 | 不需要（無程式碼）；帶樣式程式碼的佈景依上方 QML 各列判斷 | P06；第三方樣式程式碼依 #155 |

- 同程序的 facade 是 **API 與架構邊界，不是沙箱**。不得以「只給了 `client`」或隱藏方法宣稱權限隔離。
- 同程序 QML 卡死會阻塞 Shell；`Timer` 不是強制中斷。故障由獨立 supervisor 處理（`ping` 存活檢查），不宣稱逐插件故障隔離。
- 受保護表面不載入一般插件或佈景提供的 QML：approval 視窗、鎖定、救援、試看列的保留／取消入口。

## 7. 狀態所有權

| 狀態 | 擁有者 | 受控切換 renderer | Shell 崩潰或重啟 |
| --- | --- | --- | --- |
| Profile、revision、權限授予、已受理操作（`operation_id`）、會話與 turn | Core | 不受影響 | 不受影響（Core 持久化） |
| 設定草稿（每頁序列化後 ≤64 KiB）、目前頁面 `page_id` | Shell facade（renderer 之外） | 保留 | 遺失 |
| 聊天草稿、未送出附件的引用、串流事件游標、需要交還的焦點目標 | Shell facade（現行在 `shell/chat/ConversationState.qml`） | 保留 | 草稿與未送出附件都遺失：附件內容雖在 Core，但 Shell 的連線結束時 Core 會釋放該連線持有、尚未綁定 turn 的 context（`crates/ditto-core/src/lib.rs:795-800`、`context.rs:459-464`）。已保存的會話與 turn，以及已綁定到已送出 turn 的 context，仍在 Core |
| 捲動位置、hover、動畫插值、IME 組字中的文字 | renderer 本身 | 不保證；IME 組字未完成時延後交接（P05） | 遺失 |

- UI 暫態只在 Shell 程序記憶體，**不寫入** Profile、revision 或匯出；本階段不新增 Core 儲存。
- 跨崩潰保留需要 Core 管理的 UI 暫態儲存與保存期限、隱私政策，列為後續工作，不在 P02。
- 跨程序只傳可序列化資料，不傳 QObject、Context 或函式。
- `ConversationState` 目前也持有 AI 設定回讀（`settings`、`provider`）；設定頁不應取得整個聊天物件，facade 拆分屬 P03／P05。

## 8. 命令路由與相容入口

| 命令 | 在 `CORE_COMMANDS` | 擁有者 | Shell 解析為 |
| --- | --- | --- | --- |
| `composition.open` | 是 | `shell` | `page_id: composition` |
| `plugins.open` | 是 | `shell` | `page_id: plugins` |
| `history.open` | 是 | `shell` | `page_id: history` |
| `personalization.open` | 是 | `shell` | `page_id: personalization` |
| `ai_settings.open` | 是 | `shell` | `page_id: ai` |
| `chat.toggle` | 是 | `shell` | 開關對話 |
| `chat.open` | **否**：只在 Shell 的 `runCommand` 與 `shell.sock` 的 `command` 行 | — | 開啟對話 |

- 擁有者判定見 `crates/ditto-core/src/router.rs:1875-1901`；Core 以 `shell.command` 通知 Shell（`:1962-1972`），Shell 在 `shell.qml:161-205` 執行。
- 這些命令永遠由 `shell` 擁有，不由頁面或 surface 套件擁有。Shell 以 `page_id` 找目前註冊的頁面：有套件成員就開它，否則開內建頁。
- 是否把 `chat.open` 加進 `CORE_COMMANDS`（新增項目，不改既有命令）由 P02 決定；在此之前它不是 Core 命令。
- 候選在提交前不擁有命令、快捷鍵、輸入區或導覽位置：預檢只把目標文件中已放置的條目算作擁有者（`preflight.rs:557-603`），`commands` 只讀作用中文件（`router.rs:1887-1925`）；頁面在 commit 時才註冊進導覽。
- 新增頁面不會自動得到 Core 命令；套件可在 manifest 宣告 `commands`，照既有規則在提交後擁有。是否提供帶 `page_id` 參數的通用開啟命令未定案。

## 9. 回讀與 fallback 語意

| 狀態 | 定義 | 欄位 | 是提交判準 |
| --- | --- | --- | --- |
| 已註冊 | Shell 持有已提交的綁定；設定頁為已編譯且在導覽中 | 設定頁：`mounted && visible`、`page_state: registered` | 是（設定頁） |
| 已掛載 | 實例存在（surface） | `PanelMount.mounted` | 是 |
| 允許顯示 | `shown === true`；area 成員另須放在區域內 | `PanelMount.visible`（現行語意見 [shell/README.md](../../shell/README.md)「交易」） | 是 |
| 實際可見 | 表面真的在某個輸出上，或頁面已開啟 | 角色另有 `avatar_placement`；設定頁為 `page_state: open` | 否；以視覺證據另行驗證 |

- **fallback 一律回報為 fallback**。內建背景與內建頁不出現在 `mounts` 中冒充套件；套件掛載失敗時該條目回讀失敗，交易依既有規則回復。開機時準備失敗的 slot 會被略過（`ProviderHost.qml:391-392`），此時顯示內建備援，條目仍回讀失敗。
- **相同 `entry_id` 升版必須讀回新版本**。P02 起 `check_shell` 在回報含 `package`／`version` 時比對綁定；對 `ui.background` 與 `ui.settings_page` 為必要，對既有 slot 為選用。這兩個值須從 Shell 實際持有的實例或綁定讀出，不得從請求的投影複製（同 `artifact_id`，`participant.rs:201-204`；`projection.rs:323-328`）。
- 新版本的 `qml_url` 位於新的 sha256 目錄，`componentFor` 以 URL 快取元件（`ProviderHost.qml:133-146`），所以升版會載入新檔。同一 URL 內容改變後的熱替換**尚未驗證**。

## 10. UI SDK 取得方式

量測：開發 VM、Quickshell 0.3.1（rev `1a4716c`）、offscreen；以 `Qt.createComponent("file:///…")` 載入，與 `ProviderHost` 相同。這是開發證據，不是登入工作階段或參考機證據。

| 情形 | 結果 |
| --- | --- |
| 套件以絕對 `file://` URL 載入：同目錄型別、相對子目錄 `import "parts"`、非同步 incubate | 可 |
| 套件 import 絕對目錄（含 Shell 自己的 `ui`） | 可 |
| 同一 engine 內兩個套件各 import 不同版本的 SDK 目錄 | 可，各拿到自己的版本 |
| 設定資料夾內的檔案以相對路徑 import 資料夾外的目錄 | 失敗：只解析到第一個型別 |
| 套件 import `"root:/ui"`（無 `qmldir` 的一般目錄） | 失敗：部分解析 |
| 套件 import `"root:/sdk/Ditto/Ui"`（有 `qmldir`，條目指向 `../../../ui/…`） | 可，不需要複製檔案 |
| `import Ditto.Ui 1.0` | 只有 Shell 環境帶絕對 `QML_IMPORT_PATH` 時可 |

決定（D-50）：

- UI SDK 是 Shell 擁有的 qmldir 模組 `shell/sdk/Ditto/Ui/qmldir`，條目引用既有的 `shell/ui`、`shell/change` 原始檔，不複製。套件寫 `import "root:/sdk/Ditto/Ui"`。
- 主版本放在路徑；未來的主版本為 `shell/sdk/Ditto/Ui.2/`。SDK 是可信 Shell 程式碼，隨 Shell 版本發行；套件目前以 `required_protocol_version` 表達相容範圍。
- 套件規則改為量測到的限制：不得用離開套件的相對 import；不得 import Shell 私有相對路徑；SDK 一律經 `root:/` qmldir。`shell/README.md` 的「必須是單一檔案」由 P02 PR 修正。

尚未驗證：真實登入工作階段；同一 URL 檔案內容改變後在同一 engine 的替換；`root:/sdk/Ditto/Ui.2` 與 `Ui` 以路徑 import 並存（量測的是兩個絕對路徑版本目錄，以及 URI 形式的兩個主版本）；原生 QML 插件。

## 11. 舊 Profile 相容

- 不在啟動時遷移，不靜默改寫。沒有 `ui.background` 綁定或沒有 `ui.settings_page` 成員的 Profile，由 Shell 顯示可信內建背景與內建頁。這是相容投影，回報為 fallback。
- 只有新建的 store 綁定官方套件（D-48 的做法，`defaults::default_document`）。既有 Profile 經明確 ChangeSet 採用（P06 提供入口，Core 產生 revision）。
- 移除套件後回到內建備援；清除插件資料是另一項明確操作。
- 新增欄位是選用欄位：不含它們的文件雜湊不變。舊版 Core 的 strict schema 會拒絕含新欄位的文件，Core 與 Shell 同版配送，混版不支援（同 D-48 的降版政策）。

## 12. 實際觸點盤點

| 工作包 | 檔案 | 變更 |
| --- | --- | --- |
| P02 | `crates/ditto-protocol/src/profile.rs` | `SLOTS`、`AREAS` 新增值 |
| P02 | `crates/ditto-protocol/src/manifest.rs` | `settings_page` 宣告型別 |
| P02 | `crates/ditto-protocol/src/participant.rs` | `ShellSlotBinding.settings_page`；`PanelMount.package`、`version`、`page_state` |
| P02 | `crates/ditto-core/src/projection.rs` | 投影 `settings_page`；`check_shell` 比對 package／version |
| P02 | `crates/ditto-core/src/preflight.rs` | `settings_page_missing`、`duplicate_page_id` |
| P02 | `schema/manifest.json`、`schema/profile-document.json`、`schema/participant-projection.json`、`schema/participant-observation.json`、`schema/shell-report-input.json`、`packages/protocol/src/generated/` | 重新產生 |
| P02 | `packages/host-sdk/src/manifest/rules.ts` | `settings_page` 與新 slot 的 SDK 檢查 |
| P02 | `shell/core/ProviderHost.qml` | `areas` 清單（`:50`，與 Rust 同步）；頁面註冊；回報新欄位 |
| P02 | `shell/core/SlotHost.qml` | 頁面只編譯不建立實例；`mount()` 對頁面回報註冊狀態（現行以實例存在判定 `mounted`，`:289-306`） |
| P02 | `shell/shell.qml` | 內建背景的顯示／隱藏；`runCommand` 以 `page_id` 解析 |
| P02 | `shell/centers/Centers.qml` | 導覽來自註冊表；`flickable` 契約 |
| P02 | `shell/sdk/Ditto/Ui/qmldir`（新）、`shell/README.md` | UI SDK；修正單一檔案規則 |
| P03a | `shell/providers/settings_composition/`、`settings_plugins/`；既有 `settings_history/` | 組合、插件、歷史頁已提供官方套件；對應 `centers/` 原頁保留為可信備援 |
| P03a | `shell/sdk/Ditto/Ui/qmldir`、`shell/core/ProviderHost.qml`、`tests/shell-extensions/` | SDK 引用 Shell 自有 `GeneratedArtifacts`；開發目錄映射；三頁註冊、備援與外部套件庫真實載入測試 |
| P03a | `scripts/build-builtin-packages.sh`（沿用目錄探索） | 自動打包上述套件，不改預設文件或 store；綁定採用留待 P06 |
| P03b／後續 P03 | `shell/centers/PersonalizationCenter.qml`、`AISettings.qml`、`Centers.qml` | 個人化／AI 仍僅內建，先拆 `providers`／`conversation` facade；外框替換與自我升版／回復另行驗收 |
| P04 | `shell/shell.qml`（背景、`assistantLoader`）、`shell/jelly/Backdrop.qml` | 背景供應者化 |
| P04 | `shell/assistant/AssistantSurface.qml` | 移除 `ditto.dock.pill` 判斷與私有 `dockMount.object`（`:18-25`），改中立幾何 |
| P05 | `shell/chat/ConversationState.qml`、`ChatWindow.qml`、`ChatPanel.qml`、`ChatBody.qml`、`ChatInput.qml` | 單一會話 facade；草稿、串流、IME 交接 |
| P06 | `crates/ditto-protocol/src/profile.rs`（`Appearance`）、`shell/jelly/Tokens.qml`、`crates/ditto-core/src/defaults.rs` | token 套件、組合遷移入口 |
| P07 | `packages/host-sdk/`、`tests/g3/integration/trust-matrix.mjs` | 作者工具；信任矩陣延伸 |

## 13. PRD／ADR 差異（提案，不在本 PR 修改 PRD）

| PRD 節 | 提案增量 |
| --- | --- |
| §10 桌面與原生應用需求 | 背景為可替換供應者：每輸出實例、Background 圖層、輸入穿透、熱插拔 |
| §11 柔光果凍與預設角色 | 助理入口與角色為供應者；與 Dock 對齊改用中立幾何（P04） |
| §12／§12.1 插件中心與信任分級 | 設定頁擴充種類；第 6 節信任矩陣；第三方設定先採宣告式表單，前提是 Core 端依 `config_schema` 驗證 |
| §13 組合配置、版本與狀態 | 新 slot／area；舊 Profile 的內建 fallback 投影；UI 暫態不進 Profile |
| §14 變更交易、熱換與回復 | 已註冊／已掛載／允許顯示／實際可見；相同 `entry_id` 升版須讀回新版本；20 秒退休不等於任意時間撤銷 |
| §15 架構與服務契約 | UI SDK 模組；Shell facade；以 `page_id` 路由的相容命令 |
| §18 故障恢復 | 官方內建備援、受保護表面不替換、fallback 如實回報 |
| §19 非功能需求 | 沿用 NFR-04 與核定預算，不為插件新增程序；量測條件依 UI-AT12 |

這些差異由 [D-50](../../.agents/notes/decisions/2026-10-22-d50-shell-extension-contracts.md) 記錄為待 owner 檢視的提案；PRD 修訂另以獨立變更處理。

## 14. 不在本契約範圍

- 第三方或社群 QML 嵌入可信設定視窗（任何階段都不做；獨立 surface 待 #154／#155）。
- 跨 Shell 崩潰保留 UI 暫態的儲存，包括聊天草稿與未送出的附件。
- 同程序內的逐插件故障隔離。
- 受保護表面的替換：approval、鎖定、救援，以及試看列的保留／取消入口。
- 第三方應用內部主題（依 #118）。
