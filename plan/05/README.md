# G3 執行計畫｜受限生成與移植

| 文件屬性 | 內容 |
| --- | --- |
| 文件編號 | DITTO-PLAN-005 |
| 日期 | 2026-10-13 |
| 狀態 | 功能整合實作與開發驗證中；出口未評審 |
| 上位權威 | [PRD v0.4.0](../../docs/product/Ditto-PRD-v0.4.0.md) §9、12.1、14～17、19、21；[milestones/01 G3](../../milestones/01/03-phases.md#g3受限生成與移植) |
| 追蹤 | [#34](https://github.com/relvo-labs/Ditto/issues/34)，子 issue #15～#33（2026-10-13 已逐項閱讀，均無補充留言） |
| 分支／基底 | `codex/g3-restricted-generation`；開工基底為 `codex/g2-agent-foundation@a88bce89b8976d546497345777c642d9f2b7de59`。PR #13 已合併，PR #40 現以 `main` 為基底 |
| 前置 | G1 依 D-38 已完成；G2 功能由 owner 依 [D-46](../../.agents/notes/decisions/2026-10-13-d46-g2-functional-acceptance-and-g3-integration.md) 接受；原量測缺口繼續追蹤 |

目標是透過對話產出兩種原先未安裝、可運作且可繼續修改的新插件，失敗時桌面維持可用。這份計畫不宣告 G2 或 G3 出口，不更改資源門檻。

## 導讀

| 文件 | 用途 |
| --- | --- |
| [01 範圍與出口](01-scope-and-exit-criteria.md) | 程式碼盤點、十九項 G2 交接、G3 五項出口 |
| [02 隔離與受限模板](02-isolation-and-templates.md) | OS 邊界、完整性回報、模板格式與能力代理 |
| [03 契約與生成流程](03-contracts-and-pipeline.md) | 產物治理、正式能力、驗證、修復、版本與資料回退 |
| [04 驗證與量測](04-verification-and-measurement.md) | AT-06／07／18／22／26／29、故障矩陣與證據分類 |
| [05 工作包與順序](05-workplan.md) | 全部子 issue、依賴、相對週序、估算與分批提交 |
| [06 決策與交接](06-decisions-risks-and-handoff.md) | 提前開工、待決策、上游取用、風險與 G4 交接 |
| [07 實作與完成缺口盤點](07-completion-audit.md) | 對照 #15～#33 的實作、此次修正、驗證入口與出口剩餘工作 |

順序固定：**隔離基礎設施 → 受限模板 → 生成管線 → 版本升級與回退**。隔離建立前僅產出固定模板引用與受限描述；模板外的程式碼不得執行。開發 CLI 不是正式能力，沒有權限寫入 Profile、授權、安裝表或正式生成紀錄。

先提交本計畫（#15 的文件交付），再提交獨立宿主與宣告式 SDK。owner 後續以 D-46 裁定 G2 功能完成並要求繼續實完 G3，正式 Core／Store／協定／Agent／Shell 接線依此進行。不得拿本分支的提交當作 G2 的量測證據。

2026-10-13 首批獨立實作與兩種核心的 VM 證據已整理於 [G3-exit](../../.agents/notes/gate-reviews/G3-exit.md)。正式生成能力、五關原生驗證／預覽、啟用交易、版本及資料回退已有實作與開發證據；真實模型及參考機出口仍須逐項記錄，不能由 fixture 取代。生產政策見 [generated-template-boundary](../../docs/platform/generated-template-boundary.md)。

2026-10-14 已完成使用者明確授權的[實體座位驗收](../../.agents/notes/gate-reviews/G3-reference-seat-2026-10-14.md)：真訂閱四回合、可見預覽／雙預覽鍵盤取消、schema 回退、故障存活與三態信任矩陣；實測揭露的逾時關卡遺失與失敗文案亦已修正。逐 issue 交付見 [07](07-completion-audit.md)，五項出口交由 owner 依證據裁定，不代替 D-38／D-46 量測及 G4 發行工作。
