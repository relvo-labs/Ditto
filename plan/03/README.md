# G1 執行計畫（plan/03）

**階段狀態（2026-10-07）：G1 已完成，依 owner 實際使用裁定 [D-38](../../.agents/notes/decisions/2026-10-07-d38-g0-g1-owner-acceptance.md)。** 本文保留原執行計畫，逐項接受與剩餘追蹤見 [G1 評審 §8](../../.agents/notes/gate-reviews/G1-exit.md#8-2026-10-07-owner-階段接受)，下一開發階段為 G2。

| 文件屬性 | 內容 |
| --- | --- |
| 文件編號 | DITTO-PLAN-003 |
| 版本 | 1.0.0 |
| 日期 | 2026-09-27 |
| 狀態 | 待評審；工期與人力為建議值，增補項、加嚴項與估算修正須經決策程序核定 |
| 上位文件 | [milestones/01](../../milestones/01/README.md)（實作順序權威）、[PRD v0.4.0](../../docs/product/Ditto-PRD-v0.4.0.md)（需求權威） |
| 前一階段 | [plan/02](../02/README.md)（G0 執行計畫）與 [G0 出口預檢](../../.agents/notes/gate-reviews/G0-exit.md) |
| 移植來源 | `../deepseek-harness`，盤點時 HEAD `477b4f420553e8a52c2fbccc464d7561b239c443`（2026-09-24，`dsh-0.1.7-rc.2`） |
| 範圍 | 僅 G1。G2 只定義「可開工點」，G3～G5 不在本計畫內 |

本目錄把 [milestones/01/03 的 G1 階段](../../milestones/01/03-phases.md#g1組合底座)從 41 行工作分解與 7 條出口門檻，細化成可以直接開工的執行計畫。每個工作包都寫清楚五件事：做什麼、依賴誰、做完怎麼證明、卡住時退到哪裡、哪一天前必須做出決策。

## 這份計畫的定位

**權威順序：PRD > `milestones/01` > 本計畫。** 本計畫不新增需求，也不改變階段邊界。它只回答一件事：G1 這 14–18 週要怎麼執行，才能在**完全沒有模型**的情況下，讓組合、替換、保存與回復在真實桌面上成立。

與 `milestones/01` 不一致的地方沿用 plan/02 的三分法，全部登記於 [§4](#4-對-milestones01-的增補加嚴與回饋登記)：

| 種類 | 允許嗎 | 處理 |
| --- | --- | --- |
| **增補**（新增工作項） | 允許 | 登記理由與人週成本，納入估算修正提案 D-31 |
| **加嚴**（把門檻寫得更嚴、更可判定） | 允許 | 登記原門檻與加嚴後的判準 |
| **放寬**（降低門檻、縮小範圍） | **不允許** | 走 `ditto-decision-record` 並附數據提案，本計畫不自行裁決 |

## 1. 現況盤點（2026-09-27）

G1 從哪裡起步，決定了前四週的工作量。以下是倉庫與 harness 的實際狀態，逐項可查：

| 資產 | 狀態 | 對 G1 的意義 |
| --- | --- | --- |
| G0 出口 | **尚未出口**。EX-01／03／04／06／07 條件通過（待進版重跑）；EX-02（C-08）、EX-05（D-06a）、EX-08、EX-09 未通過 | G1 正式開工以 G0 出口為前提。出口前只能做**預備期**工作，範圍見 [01 §2](01-scope-and-exit-criteria.md#2-開工條件與預備期) |
| `crates/` | 5 個 crate，共 6,231 行 Rust。std 執行緒加 mpsc，**沒有 tokio，也沒有 SQLite** | G1 需要新增儲存層與交易協調器。執行緒模型要先定案（D-26），否則每個工作包各自引入非同步執行期 |
| 契約 | `PROTOCOL_VERSION = 0.1.0`；13 項能力；`CATALOG_REVISION = 2`；11 個封閉錯誤；`resource_scope` 全為空集合；`permission_denied` 保留未用 | G1 把能力擴充到約 55 項並升為協定 `0.2.0`。**空的 `resource_scope` 正是 G0 刻意留給 G1 權限分級的位置** |
| 身分 | 受控啟動器經 fd 3 交付一次性 token，綁定 PID 與 `/proc/<pid>/exe`；自述 `plugin_id` 回 `identity_rejected` | hostd 與 Agent 替身都經同一個啟動器取得身分，不另建機制 |
| 事件 | `EventBroker`：快照＋`seq`，每訂閱佇列 1024，溢位即 `resync_required` | hostd 的事件橋直接對接這套語意，不另定一套 |
| `shell/` | 面板、**一個** Dock（`dock_bottom`）、角色、DittoClient、RpcCounter；**沒有啟動器**；字串直接寫死繁中，**沒有 i18n** | DES-10 需要第二個 Dock 與兩個啟動器；供應者裝載機制本身尚不存在 |
| 持久化 | **完全沒有**（G0 禁則 1） | Profile、revision、ChangeSet、權限全部從零建立 |
| 監督 | 全部是 `systemd-run` 的 transient scope；**沒有常駐 unit 檔** | G1-PLAT-02 要改成可監督、可重啟、有重啟風暴上限的 user unit |
| `packages/` | 只有 `@ditto/protocol`（產生型別＋TS client） | host-runtime、host-sdk、plugins 從零建立 |
| harness vendor | `@deepseek-ai/cordis` **4.0.4**（上游 4.0.0-rc.7，commit `56b3d4f`），**本地修改集 22 項** | `milestones/01/02` 記載的是 4.0.2 與 21 項，已經落後；D-04 定案時必須重新鎖定，見 [§4.3](#43-回饋登記) |
| harness loader | `class Loader extends EntryTree` 在記憶體中運作，`write()` 是 no-op；`ctx.loader.create/update/remove` 可程式化推送條目 | Core 推送條目列表**不需要** `cordis-plugin-include` 的檔案路徑，這條路可行 |
| harness 資源回報 | **沒有**每插件的記憶體回報；`plugin-inventory` 只有 fiber 階段 | RUN-08 的「同程序不冒充獨立 RSS」要自建，只能誠實回報宿主層級的數字 |

推論有兩條：

1. G1 的前四週不是寫桌面服務插件，而是把**儲存、交易與宿主交易層**這三根柱子立起來。`milestones/01` 的 R2 推論（交易層先於任何桌面服務插件）在這裡具體化為關鍵路徑。
2. G0 仍有四項門檻未過，其中 EX-05（PSS 基線）與 EX-09（nightly）直接影響 G1 的量測工作。**G1 不得以 G0 已出口為前提**，排程上把依賴它們的工作放在 W8 以後，並在 [07 §3](07-workplan.md#3-關鍵路徑與並行) 標出。

## 2. G1 的一句話目標

**不靠模型，使用者只用 GUI 就能在真實桌面上替換 Dock、啟動器與布局，保存成不可變版本、比較差異並撤銷；兩個真的在跑的 Cordis 服務插件在任何客戶端消失後照常提供資料；任何程序死在交易中途，桌面都停在可說明的狀態。**

成立條件有四個，缺一不可：

| # | 條件 | 反面（做到了但不算成立） |
| --- | --- | --- |
| A | 替換是交易，不是重新載入 | 換 Dock 的方式是寫一個設定檔再重啟 Shell；失敗時沒有候選、沒有回讀、沒有回復 |
| B | Cordis 真的是桌面服務宿主 | hostd 啟動了，但兩個「服務」只回傳寫死的假資料，或 Shell 關掉就跟著停 |
| C | 故障有明確結果 | 在 `applying` 中途終止 Core，重啟後資料庫裡有一筆永遠停在 `applying` 的變更 |
| D | 權威只有一份 | hostd 自己保存一份條目列表，重啟時從那份檔案恢復，而不是向 Core 要 |

## 3. 文件導讀

| 文件 | 內容 | 誰要讀 |
| --- | --- | --- |
| [01-scope-and-exit-criteria.md](01-scope-and-exit-criteria.md) | 範圍界線、開工條件與預備期、**十五項可判定的出口門檻**、G1 能主張與不能主張什麼 | 全體，開工前 |
| [02-core-state-and-transactions.md](02-core-state-and-transactions.md) | 儲存層、Profile 與 revision、ChangeSet 狀態機、預檢、能力目錄 0.2、權限、熱換執行器、崩潰恢復、套件來源 | CORE |
| [03-host-and-cordis.md](03-host-and-cordis.md) | Cordis 取用與移植紀錄、hostd 架構、Core↔hostd 協定、交易層的候選策略、租約、事件橋、兩個服務插件、host-sdk、manifest | HOST |
| [04-shell-and-surfaces.md](04-shell-and-surfaces.md) | 供應者裝載與交易參與、兩個 Dock 與兩個啟動器、四個管理中心、變更卡、鎖定、i18n | SHELL |
| [05-platform-supervision-and-rescue.md](05-platform-supervision-and-rescue.md) | systemd user unit、監督與重啟風暴、`dittoctl` 救援、無 Node 救援模式、雙螢幕、布局策略與快捷鍵的 Wayfire 路徑 | PLAT |
| [06-verification-and-measurement.md](06-verification-and-measurement.md) | 測試分層、L-01～L-10 的實作方式、故障注入框架、清理壓力、NFR-03／04／07／08／09 與分層資源量測、CI 擴充 | QA |
| [07-workplan.md](07-workplan.md) | 54 個工作包、依賴、週序、五個內部里程碑、G2 可開工點、人力與估算 | 全體 |
| [08-decisions-and-risks.md](08-decisions-and-risks.md) | G1 必須落定的 7 項既有決策、10 項新提案（D-26～D-35）、G1 專屬風險與預先承諾的備案 | 產品、管理 |
| [09-exit-review-and-handoff.md](09-exit-review-and-handoff.md) | 出口評審程序與範本、交付物清單、G2／G3 開工前置條件、未解決事項的攜帶方式 | 全體，收尾 |

建議閱讀順序：`01`（要做到什麼）→ `07`（誰在哪一週做什麼）→ 各工作流的 `02`～`06` → `08`（什麼時候要決定）→ `09`（怎麼結案）。

## 4. 對 milestones/01 的增補、加嚴與回饋登記

### 4.1 增補的工作項（＋16.5 人週）

| ID | 工作項 | 為什麼 milestones/01 沒有它不行 | 人週 |
| --- | --- | --- | --- |
| G1-CORE-15 | 協定 0.2 與能力目錄擴充 | `milestones/01/01 §2.3` 列出 17 組能力，但 G1 工作分解沒有「把它們變成描述子、handler 與 consumer」的工作項。沒有它，G0 的目錄一致性 gate（D-23）會在第一個新能力擋下合併 | 2 |
| G1-CORE-16 | Core 執行緒與儲存架構 | G0 的 Core 是單純的 std 執行緒服務迴圈。G1 同時要序列化提交（CHG-05）、長時間的宿主交易、限時回復計時器與崩潰恢復；不先定架構，這些會各自發明鎖 | 2 |
| G1-CORE-17 | 系統轉接 `ditto-system`（通知、logind、桌面項目索引） | `milestones/01/01 §4` 有 `ditto-system` crate，但 G1 工作分解沒有對應項。DES-02 的應用搜尋、DES-05 的通知、DES-06 的登出與電源都需要它 | 3 |
| G1-HOST-12 | vendor 同步守門與移植紀錄自動化 | harness 以 `scripts/check-vendor-manifest.sh` 擋下「改了 vendor 原始碼卻沒更新修改集」。Ditto 沒有對應守門，24.1 的來源義務就只能靠 review 維持 | 1 |
| G1-SHELL-13 | UI 供應者裝載與交易參與 | G1-SHELL-03 要求「兩個 Dock、兩個啟動器」，但沒有工作項負責**怎麼換**：Profile 如何宣告供應者、Shell 如何準備候選、如何回報已掛載。沒有它，AT-04 只能靠重啟 Shell 驗收，而那違反 CHG-02 | 2.5 |
| G1-PLAT-05 | 布局策略與全域快捷鍵的 Wayfire 路徑 | DES-04 的「基本平鋪」與 CHG-03 的「不重複快捷鍵」都要在 Wayfire 上落地。G0 差異表顯示已平鋪的視窗移動會回 `unsupported`、C-05 是固定 3×3 格線，這兩件事都要先探測再實作 | 2 |
| G1-QA-06 | NFR-03／04／09 量測夾具 | `milestones/01/04 §2.2` 把 NFR-03、NFR-04 標為 G1 量測，但 G1 工作分解只有 QA-05 的資源量測 | 2 |
| G1-QA-07 | AT-16／17／20 腳本與 Agent 替身 | 見 §4.2 第一列。另外 AT-30 要求「終止 Agent 後服務仍有效」，而 G1 沒有 Agent；需要一個以 `agent` 身分經啟動器連線的替身，才能在 G1 驗證這條存活規則 | 2 |

### 4.2 加嚴的門檻

| 原門檻（milestones/01/03） | 加嚴後 | 成本落在 |
| --- | --- | --- |
| G1 出口列出 AT-04／05／08／09／19／23／27／30／31／32 | 另加 **AT-16（救援）、AT-17（鎖定）、AT-20（持久故障）**。`milestones/01/04 §1` 的驗收矩陣把這三項的首次通過階段標為 G1，但 03 的出口門檻漏列。依「矛盾時取較嚴者並登記回饋」處理 | G1-QA-07 |
| 「AT-01 完整」在 04 標為 G1，03 未列 | 列為 EX1-13 的一部分，同時涵蓋 AT-12、AT-13 的 G1 基礎部分 | 既有 SHELL／PLAT 工作包 |
| 「Cordis 啟用／Agent 退出的資源基線完成量測並符合核定預算，或附數據提出調整」 | 「或附數據提出調整」改為：**提案須在出口評審前核定**。未核定的提案不構成通過 | 無額外成本 |
| NFR-04（插件切換 p95 ≤2 秒）與 NFR-03 在 04 標為 G1 量測，03 無門檻 | 列為 EX1-11：以有效證據量測，達標或核定調整 | G1-QA-06 |
| L-01～L-10「必須通過」 | 每項測試須在 PR 快檢與 nightly 各跑一次，且**每項都要有故障注入點的負例**（例如 L-03 要證明候選在 commit 前嘗試發布正式能力會被拒絕，而不只證明正常路徑沒有重複） | G1-QA-02 |

### 4.3 回饋登記

以下矛盾或過時資訊依 [plan/02/07 §5](../02/07-decisions-and-risks.md#5-對權威文件的回饋) 的程序，已於 2026-09-27 記入 [`plan/01/05` 的回饋紀錄](../01/05-authoring-roadmap.md#回饋紀錄)，由產品裁決；**本計畫不自行改寫上位文件**：

| # | 情形 | 來源位置 | 本計畫的暫行處理 |
| --- | --- | --- | --- |
| F-1 | 03 的 G1 出口門檻漏列 AT-16／17／20，04 的矩陣標為 G1 首次通過 | `milestones/01/03` §G1、`04 §1` | 取較嚴者，列為 EX1-09、EX1-12 |
| F-2 | 02 §1 記載 Cordis 4.0.2、修改集 21 項；harness 目前為 4.0.4、22 項（新增第 22 項 volatile config） | `milestones/01/02 §1` | D-04 定案時以實際鎖定的 harness commit 為準，並回寫 02 §1 |
| F-3 | 03 的 G1 工期 14–18 週與 05 §3.1 的人力（Core 2、Host 2、Shell 2）在 124 人週下不一致：8 名工程人力 18 週、有效投入 75% 只能完成約 108 人週 | `milestones/01/03`、`05 §3` | 見 [07 §5](07-workplan.md#5-人力估算與差異說明) 的三個選項，由 D-31 裁決 |
| F-4 | 02 §3.2 假設候選在 isolate realm 健康檢查後，commit 時「發布正式能力」即可。實際上 `ctx.isolate()` 讓候選與現役能並存（同一 isolate key 重名才會被 `reflect.provide()` 拒絕），但 isolate 內提供的服務**對主 realm 的消費者不可見**，而 Cordis 沒有「把候選升格進主 realm」的操作。升格只能重新實例化（健康檢查結果不直接適用於新實例），或改成先卸下現役再掛上候選 | `milestones/01/02 §3.2`；harness `vendor/cordis/src/{context,reflect}.ts` | 以預先承諾判準在兩種策略間選擇（D-32），見 [03 §4](03-host-and-cordis.md#4-交易層ditto-host-loaderg1-host-02) |

### 4.4 估算

| 工作流 | milestones/01 | 本計畫 | 差 | 主要來源 |
| --- | --- | --- | --- | --- |
| CORE | 40 | 47 | ＋7 | CORE-15／16／17 |
| HOST | 26 | 27 | ＋1 | HOST-12 |
| SHELL | 32 | 34.5 | ＋2.5 | SHELL-13 |
| PLAT | 10 | 12 | ＋2 | PLAT-05 |
| QA | 16 | 20 | ＋4 | QA-06／07 |
| **合計** | **124** | **140.5** | **＋16.5** | |

這是**提案**（D-31），依 `ditto-decision-record` 於 G1 啟動評審核定，核定結果回寫 `milestones/01/05 §3.3`。未核定前，`milestones/01` 的 124 人週仍是有效的上位建議值。

## 5. 開工前的 skill 對應

每個工作包的第一步都是讀對應 skill，不是打開編輯器。G1 會讓三個 `draft` skill 具備轉 `stable` 的條件，對應工作包完成後必須回頭核對：

| 工作包群 | 必讀 | 併讀 | 會觸發的 skill 狀態核對 |
| --- | --- | --- | --- |
| G1-CORE-01／02／09／11 | `ditto-authority-boundaries` | `ditto-failure-and-rescue` | — |
| G1-CORE-03／04／07／08 | `ditto-changeset-transaction` | `ditto-capability-contract` | — |
| G1-CORE-05／15 | `ditto-capability-contract` | `ditto-authority-boundaries` | — |
| G1-CORE-06 | `ditto-permission-and-secrets` | `ditto-authority-boundaries` | 權限入口落地後核對第 4 步（完整轉 stable 待 G2-CORE-02） |
| G1-CORE-10／11、G1-PLAT-02～04 | `ditto-failure-and-rescue` | `ditto-process-budget` | **PLAT-03／04 完成後核對第 3 步能力表並轉 stable** |
| G1-CORE-12、G1-HOST-01／12 | `ditto-upstream-port` | `ditto-release-audit` | — |
| G1-HOST-02～11 | `ditto-cordis-plugin` | `ditto-changeset-transaction` | **HOST-02／03 完成後核對實際 API 並轉 stable** |
| G1-CORE-14、G1-HOST-10／11 | `ditto-process-budget` | `ditto-verification-evidence` | — |
| G1-SHELL-01～13 | `ditto-qml-shell` | `ditto-prose-standard` | SHELL-03 完成後依 plan/01/05 W3-03 核對供應者可替換段落 |
| G1-QA-01～07、G1-PLAT-01 | `ditto-verification-evidence` | `ditto-failure-and-rescue` | — |
| 任何文件、UI 字串與 PR 描述 | `ditto-prose-standard` | — | — |
| 任何決策落定或出口評審 | `ditto-decision-record` | — | — |

## 6. 維護規則

1. 工作包狀態只在 [07-workplan.md](07-workplan.md) 的進度紀錄更新，不散落在各文件。
2. 量測數字只寫進出口評審紀錄（`.agents/notes/gate-reviews/G1-exit.md`）與 `milestones/01/04`，本計畫不保存第二份數字。
3. 決策落定時寫 `.agents/notes/decisions/`，並回寫 `milestones/01/05` 的對應列；只做其中一邊不算完成。
4. 本計畫的任何門檻都不得因為做不到而改寫。做不到的正確處理是附數據提案，見 [08 §4](08-decisions-and-risks.md#4-決策程序)。
5. 契約細節（協定 0.2、Core↔hostd 協定、manifest、Profile 文件格式）的權威位置是 G1 建立的 `docs/contracts/`，不是本計畫。本計畫給的是設計判準與初版形狀；實作定案後以 `docs/contracts/` 與 `schema/` 為準，本計畫不同步維護第二份。
