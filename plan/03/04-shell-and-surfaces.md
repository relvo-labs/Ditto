# 04｜Shell：供應者、管理中心與桌面表面

> 對應工作包：G1-SHELL-01～13。開工前讀 `ditto-qml-shell`（stable）與 `ditto-prose-standard`；變更卡與管理中心另讀 `ditto-changeset-transaction`。
>
> 互動語意沿用凍結原型 `apps/desktop-prototype/` 的已驗證契約（變更卡、試看→保留／取消、基底版本檢查、逐步撤銷），**零行程式碼沿用**。

## 1. 起點與目錄

G0 交付的 Shell：`shell.qml`、`core/DittoClient.qml`、`core/RpcCounter.qml`、`jelly/Tokens.qml`、`avatar/`、`providers/panel_top`、`providers/dock_bottom`。沒有啟動器、沒有 i18n、沒有管理介面。

G1 的目錄：

```
shell/
├─ shell.qml
├─ core/          DittoClient（協定 0.2、參與者方法）、ProviderHost、Tr（翻譯輔助）
├─ jelly/         Tokens、Surface、Material、低效能替代樣式
├─ avatar/        （既有）
├─ providers/     可替換 UI 供應者；每個子目錄一個套件
│   ├─ panel_top/        （既有）
│   ├─ dock_bottom/      Dock A：視窗列式（既有，改寫為供應者介面）
│   ├─ dock_pill/        Dock B：膠囊式，釘選＋執行中
│   ├─ launcher_grid/    啟動器 A：網格式
│   ├─ launcher_search/  啟動器 B：搜尋式
│   ├─ tasks_panel/      tasks 服務的面板
│   └─ notifications/    通知區
├─ centers/       組合中心、插件中心、變更歷史、個人化設定
├─ change/        變更卡、試看列、限時回復倒數
├─ lock/          鎖定客戶端（獨立程序，見 §8）
├─ rescue/        救援介面（獨立設定，見 05 §3）
└─ i18n/          ditto_zh_TW.ts、ditto_en.ts
```

`shell/providers/` 的目錄名沿用 G0 已登記的偏離：QML 模組名不接受連字號，所以用底線。

## 2. UI 供應者裝載與交易參與（G1-SHELL-13）

這是 G1 Shell 最關鍵的一件事。沒有它，AT-04 只能靠重啟 Shell 驗收，而重啟 Shell 不是交易。

### 2.1 供應者介面

每個 slot 定義一個 QML 介面契約，所有供應者都實作它。消費者（`shell.qml`、其他元件）只依賴介面，不依賴具體供應者（DES-10、MOD-03）。

| slot | 介面必備屬性與訊號 | G1 供應者 |
| --- | --- | --- |
| `ui.dock` | `client`（DittoClient）、`screen`、`reservedEdge`、`ready`（bool）、`healthy()`、`release()` | `dock_bottom`、`dock_pill` |
| `ui.launcher` | 同上，另加 `open()`、`close()`、`isOpen` | `launcher_grid`、`launcher_search` |
| `ui.panel_top` | 同 `ui.dock` | `panel_top` |
| `ui.tasks_panel` | 同上 | `tasks_panel` |

`release()` 讓供應者釋放它持有的 layer-shell 表面、exclusive zone 與輸入區。**只有 `release()` 回傳後，新的供應者才能取得同一個 exclusive zone**，否則會出現雙重保留區的一幀。

### 2.2 `ProviderHost`

`core/ProviderHost.qml` 為每個 slot 維護兩個 `Loader`：`active` 與 `candidate`。

| 參與者方法 | Shell 的動作 |
| --- | --- |
| `participant.prepare` | `candidate.source = <供應者 qml_entry>`、`visible: false`；等 `Loader.status === Ready`，再呼叫 `healthy()`（上限 2 秒）；回報 `ready` 或 `failed(reason)` |
| `participant.commit` | `active.item.release()` → 把 candidate 設為可見並取得保留區 → 把原本的 active 卸下（`source = ""`）→ 交換兩個 Loader 的角色 → 回報 |
| `participant.abort` | `candidate.source = ""` |
| `participant.rollback` | 反向執行 commit |
| readback | Shell 在每次掛載變化後以事件回報 `{slot, entry_id, mounted, visible}`，Core 據此回答 `desktop.panels.list` |

readback 來自 Shell 自己的回報，因為「目前哪個元件掛在畫面上」是 UI 宿主擁有的觀測狀態（`ditto-authority-boundaries` 第 3 步）。Core 比對的是 Shell 回報的結果與 ChangeSet 的目標，不是 Shell 對「成功」的自述。

### 2.3 規則

- **所有可信 QML 供應者都在同一個 Shell 程序**。不為供應者開新程序；信任等級在插件中心顯示為「同宿主、無隔離」。
- 供應者只能透過 `client` 取得資料與呼叫能力，不得直接使用 Quickshell 的視窗或合成器 API（G0 的第二條邊界案例延續）。
- 候選載入期間 `visible: false` 且不取得輸入區，所以候選載入不影響點擊穿透（AVA-05）與幀時。
- Shell 在交易中途死掉 → Core 視為參與者失敗，走回復；Shell 重啟後依**已提交的** revision 掛載，不會看到半套的 UI。
- 供應者的 QML 在 `ditto-plugin pack` 時一併打包，Shell 從套件庫路徑載入；開發期允許 `DITTO_SHELL_DEV_PROVIDERS` 指向來源樹，但這個開關**不會出現在 release 的登入工作階段**。

## 3. 柔光果凍 token（G1-SHELL-01）

- `Tokens.qml` 從 G0 的 42 行擴充為完整 token 系統：顏色、圓角、材質（模糊半徑、透明度）、陰影、字級、間距、動畫時長與曲線。
- token 的值來自 Profile 的 `appearance`，由 `desktop.appearance.get` 提供；Shell 不自行保存任何外觀設定。
- 每個 token 都有兩組替代值：**降低透明度**（材質改為不透明、提高對比）與**減少動畫**（時長 0 或淡入淡出取代位移）。系統層的減少動畫偏好也要尊重。
- **低效能替代樣式**：關閉模糊與陰影，量測時另列一組（NFR-05 的 G1 回歸）。

## 4. 桌面表面（G1-SHELL-02）

| 元件 | G1 內容 | 依賴 |
| --- | --- | --- |
| 工作區 | Wayfire 為固定 3×3 格線（G0 C-05）；工作區指示依格線顯示，至少兩個工作區可切換（DES-04） | `desktop.workspaces.*` |
| 布局策略 | 浮動（Wayfire 預設）與基本平鋪；**策略本身是 `layout.strategy` slot 的供應者**，由 Core 轉接到 Wayfire（見 [05 §6](05-platform-supervision-and-rescue.md#6-布局策略與全域快捷鍵g1-plat-05)）。Shell 只顯示目前策略與切換入口 | `desktop.layout.get`、ChangeSet |
| 已平鋪視窗 | G0 已知已平鋪的視窗移動回 `unsupported`；Shell 依 `availability` 隱藏會失敗的操作，不顯示後才報錯 | 能力目錄 |
| 角色 | 沿用 G0；新增位置、縮放、隱藏（寫入 Profile 的 `avatar`）；雙螢幕時跟隨主輸出 | `desktop.outputs.list` |

## 5. 兩個 Dock 與兩個啟動器（G1-SHELL-03、SHELL-04）

這四個供應者要證明的是**可替換性**，不是視覺多樣性。所以它們必須在資料來源、互動方式與版面上真的不同，且替換後既有設定與索引保留（5.3 節）：

| 供應者 | 形態 | 資料 | 鍵盤 |
| --- | --- | --- | --- |
| `dock_bottom`（A） | 底部置中、執行中視窗列 | `client.windows` | Super＋數字聚焦第 N 個 |
| `dock_pill`（B） | 可停靠於左／下的膠囊；釘選應用＋執行中指示 | `desktop.launcher.list_apps` ＋ `client.windows`；釘選清單在 entry `config` | 同上 |
| `launcher_grid`（A） | 全螢幕網格、依類別分頁 | `desktop.launcher.list_apps` | 方向鍵、Enter、Esc |
| `launcher_search`（B） | 中央搜尋框、即時結果 | `desktop.launcher.search`（模糊比對在 Core 的索引） | 輸入即搜、上下選擇、Enter |

- 應用啟動一律經 `desktop.launcher.launch`（DES-02）；啟動器本身不 `exec` 任何程式。
- 替換啟動器後，應用索引（Core 的快取）不重建；釘選清單若新供應者支援則遷移，不支援則保留在舊 entry 的 config 中並在變更卡說明（「新的啟動器不支援釘選，原本的釘選已保留」）。
- 喚出啟動器的時間戳記錄進 RpcCounter 同一套紀錄機制，供 NFR-02 在 G2／G4 量測；G1 只確保量得到。

## 6. 通知、快捷鍵、音量與網路（G1-SHELL-05）

| 項目 | 做法 |
| --- | --- |
| 通知區 | `providers/notifications`：訂閱 Core 的通知事件；顯示、合併、關閉（`desktop.notifications.dismiss`）；策略不可用時顯示提示 |
| 快捷鍵 | 快捷鍵的權威在 Profile，綁定由 Core 經 Wayfire 路徑完成（05 §6）；Shell 只在個人化設定顯示與編輯，衝突由預檢擋下並以產品語言呈現 |
| 音量 | 優先使用 Quickshell 的 PipeWire 整合（15.5：優先重用既有能力）；只顯示與簡單調整，詳細設定啟動 `pavucontrol` |
| 網路 | 讀取 NetworkManager 的 D-Bus 狀態；詳細設定啟動 `nm-connection-editor` |
| 決定點 | W1 探測 Quickshell 0.3.1 在凍結發行版上的 PipeWire 與 NetworkManager 整合是否可用；不可用則經 `ditto-system` 提供唯讀狀態能力，並記錄於 D-28 的「影響」欄 |

音量與網路狀態是 UI 的讀取，不經 ChangeSet；它們不是 Ditto 的配置（使用者的系統音量不進 Profile 匯出）。

## 7. 四個管理中心（G1-SHELL-06～09）

所有中心都是 Shell 內的表面，只經能力讀寫。一般畫面使用產品語言；契約 ID、程序資訊、原始錯誤放在可展開的「診斷」區（6 節）。

### 7.1 組合中心（G1-SHELL-06）

| 功能 | 能力 | 互動 |
| --- | --- | --- |
| 已存組合清單 | `profiles.list` | 顯示名稱、最後修改、目前使用中 |
| 建立、複製、命名、刪除 | `profiles.create／duplicate／rename／delete` | 刪除使用中的組合被拒並說明 |
| 差異 | `profiles.diff` | 任兩個版本；與變更卡同一元件 |
| 預覽 → 保留／取消 | `changes.propose`（`mode: preview`） | 沿用原型的三態：試看時顯示「保留」「取消」與倒數（非必要時不倒數） |
| 套用 | `changes.propose` | 顯示變更卡後確認 |
| 版本 | `profiles.get` 的 revision 鏈 | 每個版本顯示來源（GUI 哪個畫面、CLI、救援） |
| 匯入／匯出 | `profiles.export／import_validate／import` | 匯入先顯示驗證結果（缺少的套件、不相容的版本），**不立即執行**（CFG-04） |

**預覽的語意**：「試看」是一個走到 `committed` 但標為 `pending_confirmation` 的 ChangeSet（與限時回復共用機制）。按「保留」→ `changes.confirm`；按「取消」或逾時 → 自動回復。這讓預覽也有回讀與歷史，不是 Shell 單方面的假畫面。

### 7.2 插件中心（G1-SHELL-07）

MOD-01 與 RUN-08 的欄位：ID、版本、來源、作者、授權、執行狀態、相容性、宿主、信任等級、啟動原因、活動工作、資源。

- 資源欄依 [03 §10](03-host-and-cordis.md#10-資源回報g1-host-10)：hostd 顯示程序層級數字；每個插件顯示「與 N 個插件共用宿主，無法單獨計量」。
- fiber 狀態 `PENDING` 顯示為「等待『任務資料』服務」這類說明，**不顯示成錯誤，也不含糊成「載入中」**（`ditto-cordis-plugin` 第 4 步）。
- 安裝與啟用分開：安裝顯示 job 進度；啟用另外產生一張變更卡。
- 被監督停用的插件顯示原因、最後一次診斷與「重新啟用」。
- 權限：列出插件請求與已授予的範圍；授予與撤銷經 `permissions.grant／revoke`，撤銷後即時反映。

### 7.3 變更歷史（G1-SHELL-08）

每筆顯示：需求（GUI 動作的產品語言描述）、實際差異、結果類別、來源、回復條件。

- 逐步撤銷：`changes.undo`；撤銷非最新且與後續變更衝突時，顯示「請先撤銷較新的變更」（原型政策，Core 判定）。
- 部分完成的變更逐項列出已生效與未回復的項目。
- 結果未知的變更顯示「無法確認是否已生效」與目前的實際狀態，不提供「重試」按鈕。
- 崩潰恢復處理過的變更標示「上次中斷，已於 HH:MM 處理」。

### 7.4 個人化設定（G1-SHELL-09）

外觀（token、材質、降低透明度）、快捷鍵（含衝突提示）、角色（位置、縮放、隱藏、停用動畫）、動畫（減少動畫）、語言（繁中／英文）、無障礙（鍵盤焦點可見、螢幕閱讀）。每一項修改都是 ChangeSet；主要快捷鍵與語言以外的顯示設定走限時回復（[02 §10](02-core-state-and-transactions.md#10-回讀提交與限時回復g1-core-08)）。

螢幕閱讀：所有互動元件設定 `Accessible.role`、`Accessible.name`；以 Orca 在參考機上走一次組合中心的主要流程，結果記入人工驗收清單。

## 8. 變更卡、鎖定、登出與電源（G1-SHELL-10、SHELL-11）

### 8.1 變更卡

沿用原型契約：`kind`、`title`、逐項 `before → after`、`footnote`。資料全部來自 Core 的 `diff_json`；Shell 只依語系呈現翻譯鍵，不自己計算差異。狀態文字依真實的 ChangeSet 狀態更新（準備中、套用中、確認中、完成、已回復、部分完成、無法確認），**不用動畫表示不存在的進度**。

### 8.2 鎖定（D-30）

| 需求 | 做法 |
| --- | --- |
| 使用已驗證的系統機制（DES-06） | `ext_session_lock_v1`（G0 C-10 已在 Wayfire 上完成最小流程）＋PAM 驗證 |
| 不隨插件更新被替換（SEC-08） | 鎖定客戶端是**獨立程序** `ditto-lock`（`shell/lock/` 的獨立 Quickshell 設定），由 Core 啟動，不是 slot，不經 ProviderHost |
| Shell 崩潰不解鎖（SEC-08、AT-17） | 由協定保證：鎖定客戶端或 Shell 死掉時，合成器必須維持鎖定並不顯示桌面內容。**這在 Wayfire 0.11 上要實測**，G0 只測了正常流程 |
| 鎖定時的變更 | 預檢第 12 項 `session_unlocked`；鎖定期間的 ChangeSet 被拒或延後 |
| 觸發 | 面板電源選單、快捷鍵、logind `Lock` 訊號、閒置（`ext_idle_notify_v1`，G0 C-14 已列舉） |

若 Wayfire 在鎖定客戶端死亡時會暴露桌面，這是阻斷缺陷，依 [08 G1-R6](08-decisions-and-risks.md#3-g1-專屬風險) 處理，不以「Shell 很少崩潰」接受。

### 8.3 登出與電源

`desktop.session.logout／suspend／poweroff` 經 Core 呼叫 logind。登出前若有進行中的 ChangeSet，先等它到終態（上限 5 秒），否則在歷史記錄為中斷並交由下次開機的恢復流程處理。

## 9. i18n、剪貼簿與開檔（G1-SHELL-12）

- 所有 Ditto 自有字串改為 `qsTr()`，以 `lupdate`／`lrelease` 產生 `ditto_zh_TW.qm`、`ditto_en.qm`；語言來自 Profile 的 `appearance.locale`。
- CI 新增一條 lint：`shell/` 下的 QML 不得出現未包在 `qsTr()` 內的中日韓字元字串（EX1-13 ④）。
- Core 產生的使用者可見文字（變更卡標題、預檢原因）以**翻譯鍵**傳給 Shell，由 Shell 翻譯；Core 不輸出寫死的語系字串。
- 文字剪貼簿：Shell 內的文字欄位支援複製貼上；跨應用剪貼簿依合成器的標準協定，不經 Core。
- 預設應用開檔：經 `desktop.launcher.launch` 的 `open_uri` 參數，Core 以 `xdg-mime` 查詢預設應用後啟動。

## 10. 熱路徑與幀時

G1 不得讓 G0 的 EX-04 結果退步：

- 管理中心的資料更新走事件，不輪詢；隱藏時停止訂閱或停止渲染（RUN-07）。
- ProviderHost 的候選載入在隱藏狀態進行；切換瞬間允許一次重新配置，但角色與拖曳的熱路徑 RPC 仍必須為 0。
- nightly 保留 G0 的 hotpath 腳本，並新增「Dock 替換期間」一段的幀時取樣；替換期間的幀時結果單獨列出，不混入待命段。

## 11. 驗證清單

| # | 驗證 | 對應門檻 |
| --- | --- | --- |
| 1 | Dock A↔B、啟動器 A↔B 各替換 100 次，無雙重保留區、無殘留表面 | EX1-01、EX1-04 |
| 2 | 候選載入失敗（故障夾具：QML 語法錯誤、`healthy()` 回 false、永不 Ready）→ 現役不受影響 | EX1-03 |
| 3 | 交易中途 `SIGKILL` Shell → 重啟後掛載的是已提交 revision 的供應者 | EX1-09 |
| 4 | 語言切換後無寫死字串；中文輸入在組合中心命名欄位可用 | EX1-13 |
| 5 | 鎖定時終止 Shell 與鎖定客戶端，工作階段保持鎖定 | EX1-12 |
| 6 | 熱路徑 RPC 仍為 0；Dock 替換段的幀時另列 | G0 EX-04 回歸 |
| 7 | Orca 走完組合中心主要流程 | EX1-13（人工） |
