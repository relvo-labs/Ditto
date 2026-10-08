# 05 — 分波撰寫路線圖

**交付狀態（2026-09-19）**：**15／15 全部交付**，lint 與 CI 就緒（`15 skills · 0 error · 0 warn`）。

Wave 1 的五項前置交付與六個 skill 依原訂順序完成。Wave 2、Wave 3 的九個 skill 應使用者要求一次寫完，**早於本文件原訂的觸發時機**——處理方式與風險見 [回饋紀錄](#回饋紀錄) 2026-09-19 的第五、六筆。

skill 的價值取決於**寫的時機**：太早寫會憑空猜測還不存在的程式碼，太晚寫則原則已被違反。本文把 15 個 skill 分成三波，對齊 [milestones/01](../../milestones/01/03-phases.md) 的階段。

## 分波原則

| 原則 | 說明 |
| --- | --- |
| 原則先於程式碼 | 規範「怎麼判斷」的 skill 必須在對應程式碼開工前就位 |
| 機制後於機制 | 規範「怎麼用某個機制」的 skill 等該機制成形後再寫，避免寫出與實作不符的步驟 |
| 一波一交付 | 每波結束時，索引、關聯與 lint 必須同時通過，不留半成品 |

## Wave 1｜隨 `.agents` 建立，**先於 G0 開工**

G0 會同時寫下契約管線、程序邊界與量測工具——這三樣一旦定型，後續全部沿用。Wave 1 的六個 skill 必須在那之前就位。

### 前置交付

| # | 項目 | 說明 |
| --- | --- | --- |
| W1-00 | `.agents/skills/` 目錄與 `.gitignore` | — |
| W1-01 | `.claude/skills -> ../.agents/skills` 符號連結 | 使 skill 生效 |
| W1-02 | 根目錄 `AGENTS.md`（＋`CLAUDE.md` 符號連結） | 只做導覽，≤60 行，界線見 [04 §6](04-index-and-relationships.md#6-導覽入口根目錄-agentsmd) |
| W1-03 | `.agents/skills/AUTHORING.md` | [03](03-authoring-standard.md) 的速查版 |
| W1-04 | `scripts/lint-skills.mjs` | 見 [06](06-acceptance-and-validation.md#3-lint-腳本設計) |

### skill 交付

| # | Skill | 對應階段 | 撰寫要點 |
| --- | --- | --- | --- |
| W1-05 | `ditto-authority-boundaries` | G0 起 | 一張歸屬決策表（狀態種類 → 擁有者 → 禁則）；四條禁則各附一組校準正反例 |
| W1-06 | `ditto-capability-contract` | G0-CORE-02 | 描述子欄位清單＋`readback` 缺席時的處理；型別產生管線的實際指令 |
| W1-07 | `ditto-process-budget` | G0-QA-01／03 | 常駐 vs 按需的判定樹；熱路徑禁令；PSS 計費規則（不得與 RSS 相加） |
| W1-08 | `ditto-prose-standard` | 立即 | 產品語言／診斷語言分層表；「未驗證不得寫成已達成」的改寫例 |
| W1-09 | `ditto-changeset-transaction` | G1-CORE-03 前 | 狀態機圖＋每個轉換的前置條件；「部分完成 vs 失敗」的校準例 |
| W1-10 | `ditto-verification-evidence` | G0 出口前 | 量測流程逐步；AT／NFR 查找表指向 milestones/01/04；「不得靜默調高門檻」的處理程序 |

**為何 `ditto-changeset-transaction` 在 Wave 1**：它規範的是 G1 的核心程式碼，但 G0 的最小 IPC 已經要決定 `operation_id`、取消與逾時語意。等 G1 才寫會晚一步。

**Wave 1 出口**：六個 skill 通過 [06](06-acceptance-and-validation.md) 的 DoD；`README.md` 與 `RELATIONSHIPS.md` 產生完成；lint 在 CI 上綠燈。

## Wave 2｜G1 中段（宿主與救援成形後）

這五個 skill 描述的機制需要先有實作形狀，否則步驟會寫錯。

| # | Skill | 觸發時機 | 撰寫要點 |
| --- | --- | --- | --- |
| W2-01 | `ditto-cordis-plugin` | `ditto-host-loader` 與租約協定可運行後（G1-HOST-02／03） | 依賴／effect／fiber 的實作慣例；waterfall `next()` 紀律；`isolate` 非安全邊界的警告；指向 L-01～L-10 契約測試 |
| W2-02 | `ditto-failure-and-rescue` | 監督與 `dittoctl` 成形後（G1-PLAT-03／04） | 無 Node 救援的能力界線表；部分完成的回報格式；日誌串聯欄位 |
| W2-03 | `ditto-permission-and-secrets` | approval seam 移植後（G2-CORE-02） | 分項授權矩陣；外部內容視為資料的判準；秘密引用檢查清單 |
| W2-04 | `ditto-agent-changeset` | Agent 骨架可跑後（G2-AGENT-01） | 能力目錄動態取得的實際呼叫；含糊處理判準；多輪修正的目標定位 |
| W2-05 | `ditto-decision-record` | G0 出口評審前（**提前於本波其餘項**） | `.agents/notes/` 結構；D-xx 落定格式；階段出口五項記錄 |

**`ditto-decision-record` 的時機例外**：G0 出口就要做合成器決策（D-02）與資源預算核定（D-06），紀錄格式必須先存在。若 Wave 2 尚未啟動，單獨提前交付。

**Wave 2 出口**：`.agents/notes/` 已有至少一則真實決策紀錄（不是範例）；五個 skill 通過 DoD。

## Wave 3｜G3 前

| # | Skill | 觸發時機 | 撰寫要點 |
| --- | --- | --- | --- |
| W3-01 | `ditto-generation-safety` | 隔離測試宿主可運行後（G3-HOST-01） | 執行優先序判定樹；隔離就緒判定；`partial` 強制執行的處理；三輪預算的收尾 |
| W3-02 | `ditto-upstream-port` | 首次移植發生時（G2-AGENT-02，可提前） | 移植紀錄欄位範本；四種移植類型判定；授權義務清單 |
| W3-03 | `ditto-qml-shell` | 第二組 UI 供應者完成後（G1-SHELL-03，可提前） | State/Transition 對應；命中區與 input region；無障礙檢查清單 |
| W3-04 | `ditto-release-audit` | G4 開始時 | 盤點清單；交付物清單；已知限制的誠實陳述格式 |

**可提前項**：`ditto-upstream-port` 與 `ditto-qml-shell` 的觸發時機實際落在 G1～G2。若該工作先發生，就先寫，不必等到 Wave 3；分波是下限而非上限。

## 逐 skill 待辦範本

每個 skill 的撰寫任務拆成六步：

1. 從 [02](02-skill-taxonomy.md) 抄出單一職責句與 Owns／NOT 邊界，寫成 `>` 定位句與 `## When to Use` 的邊界段。
2. 蒐集權威來源與需求 ID，寫 `## Authority`。**此時驗證每個 ID 在 PRD 中存在。**
3. 從 [02 §4 觸發矩陣](02-skill-taxonomy.md#4-觸發矩陣)取該 skill 的情境，寫成英文 `description` 的 "Use when ..." 句。
4. 寫 `## Workflow`：第一步指向權威章節，其後為判準與檢查點，收尾為可執行驗證。
5. 有灰色地帶者補 `## Calibrated Examples`。
6. 更新 `metadata.related` 與雙方的 `## Related Skills`，跑 `node scripts/lint-skills.mjs --write-index`，確認 CI 綠燈。

## 回饋清單

撰寫過程中若發現下列情形，**不得自行在 skill 內裁決**，改記入本節並由對應負責人處理：

| 情形 | 處理 |
| --- | --- |
| PRD 兩處需求互相矛盾 | 記入本清單 → 產品裁決 → 更新 PRD 版本紀錄 |
| `milestones/01` 的安排與 PRD 需求不符 | 記入本清單 → 更新 milestones/01 並註明理由 |
| 某原則無法寫成可判斷的判準（過於抽象） | 記入本清單 → 與需求擁有者釐清；不得寫成空泛提醒充數 |
| 某情境找不到對應 skill | 評估是否需新增 skill；若屬通用工程問題，明確標為不覆蓋 |
| my-skills 標準無法容納的需求 | 登記為 [03 §6](03-authoring-standard.md#6-與-my-skills-標準的差異登記) 的新差異，並寫出回饋建議 |

清單維護在本文件末尾，格式：`日期｜情形｜來源位置｜處理狀態｜結論`。

### 回饋紀錄

| 日期 | 情形 | 來源位置 | 處理狀態 | 結論 |
| --- | --- | --- | --- | --- |
| 2026-09-19 | `ditto-decision-record` 的權威是 `milestones/01`，其決策清單用 `D-xx` 而非 PRD 需求 ID，原訂 `requirement-ids-resolve` 只查 PRD 會擋下合法引用 | [06 §2](06-acceptance-and-validation.md#2-lint-規則) | 已處理 | 規則擴充為同時解析 `milestones/01/05` 的 `D-xx`；該 skill 另以 NFR-06、NFR-12、AT-25 為 PRD 錨點（PRD §19.1 要求預算以「有紀錄的決策」核定） |
| 2026-09-19 | 關係類型與方向若從 `## Related Skills` 的散文解析，遇到「reviews 本 skill 的產出」這類反向敘述會判錯 | [04 §3](04-index-and-relationships.md#3-relationshipsmd關聯地圖) | 已處理 | 改以 [02 §3 關係摘要](02-skill-taxonomy.md#3-關係摘要) 為關係的單一事實來源，新增 `related-matches-plan` 規則驗證 `metadata.related` 與之一致 |
| 2026-09-19 | `trigger-coverage` 原述「每個情境至少被一個 description 覆蓋」，關鍵字比對過於模糊不可靠 | [06 §2](06-acceptance-and-validation.md#2-lint-規則) | 已處理 | 改為兩項可判定的檢查：矩陣中的名稱皆須在 `plan/01/02` 名冊內；每個已交付 skill 至少是一個情境的首要 skill |
| 2026-09-19 | 撰寫 Wave 1 期間未發現 PRD 與 `milestones/01` 的矛盾 | — | 無需處理 | 七個 skill 的 `## Authority` 共引用 40 個相異的 PRD 需求 ID，全部解析成功 |
| 2026-09-19 | 使用者要求一次寫完全部 skill，與本文件「機制後於機制」的分波原則衝突：Wave 2／3 的六個 skill 描述的宿主、救援、授權鏈、Agent 工具介面、測試宿主與 QML Shell 皆尚未實作 | 本文件 [分波原則](#分波原則) | 已處理（帶條件） | 依使用者決定一次交付。為避免寫出與實作不符的步驟被當成事實，六個依賴未建實作的 skill 標記 `metadata.status: draft`，並在定位句下方註明「對應子系統落地後須回頭核對哪一步」。純流程性的 `ditto-upstream-port` 與 `ditto-release-audit` 不依賴實作形狀，維持 `stable` |
| 2026-09-19 | `draft` skill 的核對時機需要有人追蹤，否則會一直停在 draft | 各 draft skill 的 `## Authority` 上方註記 | 待處理 | 每個 draft skill 註明了對應的階段工作項（如 G1-HOST-02／03、G2-CORE-02、G3-HOST-01）；該工作項完成時一併核對並改為 stable，列入對應階段的出口檢查 |
| 2026-09-19 | `milestones/01/03` 的 G0 工作分解沒有真機 runner 工作項，但 `04-verification §4` 要求 G0 的效能與動畫數字必須在實體參考機量測；該需求只出現在風險 R-19 與待決策 D-19 | [milestones/01/03 G0 工作分解](../../milestones/01/03-phases.md)、[milestones/01/04 §4](../../milestones/01/04-verification.md) | 待處理 | [plan/02](../02/README.md) 以增補工作項 G0-PLAT-05 補上並登記人週成本；是否併入 `milestones/01` 的 G0 工作分解由產品裁決（見 [plan/02/07 §1.1](../02/07-decisions-and-risks.md#11-本計畫新增的待決策提案) 的 D-21） |
| 2026-09-27 | `milestones/01/03` 的 G1 出口門檻未列 AT-16（救援）、AT-17（鎖定）、AT-20（持久故障），但 `04 §1` 的驗收矩陣把三者的首次通過階段標為 G1 | [milestones/01/03 G1 出口門檻](../../milestones/01/03-phases.md)、[milestones/01/04 §1](../../milestones/01/04-verification.md) | 待處理 | [plan/03](../03/README.md#43-回饋登記) 暫取較嚴者，列為 EX1-09 與 EX1-12（F-1）；是否回寫 `milestones/01/03` 由產品裁決 |
| 2026-09-27 | `milestones/01/02 §1` 記載 `@deepseek-ai/cordis` 4.0.2 與 21 項本地修改；harness 目前（`477b4f4`，2026-09-24）為 4.0.4 與 22 項（新增第 22 項 volatile config） | [milestones/01/02 §1](../../milestones/01/02-cordis-adoption.md) | 待處理 | D-04 定案時以實際鎖定的 harness commit 為準並回寫 02 §1（plan/03 F-2） |
| 2026-09-27 | `milestones/01/03` 的 G1 工期 14–18 週與 `05 §3.1` 的建議人力不一致：8 名工程人力 18 週、有效投入 75% 約完成 108 人週，低於 124 人週 | [milestones/01/03](../../milestones/01/03-phases.md)、[milestones/01/05 §3](../../milestones/01/05-risks-decisions.md) | 待處理 | [plan/03/07 §5](../03/07-workplan.md#5-人力估算與差異說明) 提出兩個選項，由 D-31 裁決（plan/03 F-3） |
| 2026-09-27 | `milestones/01/02 §3.2` 假設候選在 isolate realm 健康檢查後，commit 時即可發布正式能力；但 isolate 內的服務對主 realm 不可見，Cordis 沒有升格操作 | [milestones/01/02 §3.2](../../milestones/01/02-cordis-adoption.md) | 待處理 | [plan/03/03 §4.2](../03/03-host-and-cordis.md#42-候選策略d-32) 以預先承諾判準在兩種候選策略間選擇（D-32）；裁決後回寫 02 §3.2（plan/03 F-4） |
| 2026-10-07 | G2 出口漏列驗收矩陣指定 G2 首次通過的 AT-15／21 | [milestones/01/03](../../milestones/01/03-phases.md)、[04](../../milestones/01/04-verification.md) | 待評審 | [plan/04](../04/README.md) F2-01 暫取較嚴者，列 EX2-09／10；上位出口未自行改寫 |
| 2026-10-07 | G2-SHELL-02 寫「六態」，但列舉與 PRD AVA-04 實為七態 | [milestones/01/03](../../milestones/01/03-phases.md)、[PRD](../../docs/product/Ditto-PRD-v0.4.0.md) | 待回寫來源 | plan/04 F2-02 依 PRD 設計七態；不刪任何狀態 |
| 2026-10-07 | G2 盤點發現 Core 會話、偏好、durable barrier、布局／原生上下文、契約與驗證缺獨立工作包；NFR-12 調整提案不能當達標 | [plan/04 盤點與回饋](../04/README.md) | 待核定 | F2-03～08、D-39～43 已登記；原缺口增13包／33人週，連同 Codex 3包後44包／125人週為提案，預算與成功率不自行放寬 |
| 2026-10-07 | 使用者要求 Codex 個人訂閱登入＋app-server，改變模型執行與實際程序模型 | [D-09a](../../.agents/notes/decisions/2026-10-07-d09a-codex-subscription-app-server.md)、[plan/04/10](../04/10-codex-app-server.md) | 方向已決；D-44 技術與配額待 probe | F2-09：1 controller＋≤1後端，Core 工具與會話權威保留，官方 keyring 登入；新增3包／8人週待重估，不靜默改 RUN-02 或排除後端 PSS |
