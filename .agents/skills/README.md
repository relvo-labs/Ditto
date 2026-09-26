# Ditto Agent Skills

> 專案內生效的 agent skills。撰寫標準見 [AUTHORING.md](AUTHORING.md)；建置計畫見 [plan/01](../../plan/01/README.md)。

這些 skill 把 [PRD v0.4.0](../../docs/product/Ditto-PRD-v0.4.0.md) 與 [milestones/01](../../milestones/01/README.md) 的開發原則，轉成 agent 在動手前會讀到的判斷程序。

**skill 不複製權威內容。** 有疑義時，一律以各 skill `## Authority` 段落列出的來源為準。

下方表格由 `node scripts/lint-skills.mjs --write-index` 產生，請勿手改。

<!-- BEGIN GENERATED lint-skills.mjs — do not edit between markers -->

已交付 15 個，計畫共 15 個。

## Category: architecture

> 所有權、契約、程序與資源邊界

| Skill | Status | 交付 | 職責 |
|---|---|---|---|
| [ditto-authority-boundaries](ditto-authority-boundaries/SKILL.md) | stable | Wave 1 | 判定一項狀態、寫入路徑或決策歸誰所有，以及跨層禁則。 |
| [ditto-capability-contract](ditto-capability-contract/SKILL.md) | stable | Wave 1 | 新增或修改 `desktop.*` 能力時的契約設計與型別產生。 |
| [ditto-permission-and-secrets](ditto-permission-and-secrets/SKILL.md) | draft | Wave 2 | 權限分項授權、信任分級、外部內容視為資料，以及秘密只存引用。 |
| [ditto-process-budget](ditto-process-budget/SKILL.md) | stable | Wave 1 | 程序數、常駐決策、熱路徑與資源計費。 |

## Category: runtime

> Core／Cordis 宿主的執行期行為

| Skill | Status | 交付 | 職責 |
|---|---|---|---|
| [ditto-changeset-transaction](ditto-changeset-transaction/SKILL.md) | stable | Wave 1 | 任何會改變桌面狀態的操作的交易流程：預檢、準備、套用、回讀、提交或回復。 |
| [ditto-cordis-plugin](ditto-cordis-plugin/SKILL.md) | draft | Wave 2 | 在 Cordis 桌面宿主內撰寫或審查插件：依賴、可逆註冊、fiber 生命週期與跨宿主租約。 |
| [ditto-failure-and-rescue](ditto-failure-and-rescue/SKILL.md) | draft | Wave 2 | 故障路徑、監督、救援模式與可觀測性。 |

## Category: agent

> 意圖理解、規劃與生成

| Skill | Status | 交付 | 職責 |
|---|---|---|---|
| [ditto-agent-changeset](ditto-agent-changeset/SKILL.md) | draft | Wave 2 | Agent 從自然語言到結構化 ChangeSet 的規劃行為。 |
| [ditto-generation-safety](ditto-generation-safety/SKILL.md) | draft | Wave 3 | 受限生成與隔離執行：模板優先、限制能力、隔離驗證、預算與回復。 |

## Category: shell

> QML／Quickshell 桌面呈現

| Skill | Status | 交付 | 職責 |
|---|---|---|---|
| [ditto-qml-shell](ditto-qml-shell/SKILL.md) | stable | Wave 3 | QML／Quickshell 元件與角色：本機動畫、命中區、可替換供應者與無障礙。 |

## Category: quality

> 驗收、量測與測試

| Skill | Status | 交付 | 職責 |
|---|---|---|---|
| [ditto-verification-evidence](ditto-verification-evidence/SKILL.md) | stable | Wave 1 | 任何「完成」宣稱所需的證據，以及量測怎麼跑、報告怎麼寫。 |

## Category: process

> 文件、決策、移植與發行

| Skill | Status | 交付 | 職責 |
|---|---|---|---|
| [ditto-decision-record](ditto-decision-record/SKILL.md) | stable | Wave 2 | 待決策落定、階段出口結果與計畫回饋的紀錄格式與存放。 |
| [ditto-prose-standard](ditto-prose-standard/SKILL.md) | stable | Wave 1 | 產品文案與專案文件的語氣分層與誠實要求。 |
| [ditto-release-audit](ditto-release-audit/SKILL.md) | stable | Wave 3 | 發行前的來源與授權盤點、交付物清單與已知限制陳述。 |
| [ditto-upstream-port](ditto-upstream-port/SKILL.md) | stable | Wave 3 | 從 Cordis、Harness 或其他上游取用程式碼時的分類、紀錄與義務。 |

## 觸發速查

| 我正在… | 首要 | 併發 |
|---|---|---|
| 新增一項 `desktop.*` 能力 | `ditto-capability-contract` | `ditto-authority-boundaries` |
| 決定某份狀態存哪裡、誰能寫 | `ditto-authority-boundaries` | — |
| 實作會改變桌面狀態的操作 | `ditto-changeset-transaction` | `ditto-capability-contract` |
| 撰寫或審查 Cordis 桌面服務插件 | `ditto-cordis-plugin` | `ditto-upstream-port` |
| 決定要不要開新程序／常駐／輪詢 | `ditto-process-budget` | `ditto-authority-boundaries` |
| 處理熱路徑、動畫或拖曳效能 | `ditto-qml-shell` | `ditto-process-budget` |
| 設計權限提示、授權範圍或秘密存取 | `ditto-permission-and-secrets` | — |
| 實作 Agent 的意圖解析或工具呼叫 | `ditto-agent-changeset` | `ditto-capability-contract` |
| 實作或審查插件生成、模板、測試宿主 | `ditto-generation-safety` | `ditto-permission-and-secrets` |
| 設計失敗、逾時、崩潰或救援行為 | `ditto-failure-and-rescue` | `ditto-changeset-transaction` |
| 宣稱某項需求完成／撰寫測試／跑量測 | `ditto-verification-evidence` | — |
| 階段出口評審 | `ditto-verification-evidence` | `ditto-decision-record` |
| 待決策清單落定 | `ditto-decision-record` | — |
| 從 Harness／Cordis 取用程式碼 | `ditto-upstream-port` | `ditto-cordis-plugin` |
| 撰寫 UI 文案、錯誤訊息或專案文件 | `ditto-prose-standard` | — |
| 發行前檢查 | `ditto-release-audit` | `ditto-upstream-port` |
| 撰寫 QML 元件、角色動畫或無障礙 | `ditto-qml-shell` | `ditto-prose-standard` |

<!-- END GENERATED lint-skills.mjs -->
