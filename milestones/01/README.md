# Milestone 01｜Ditto 分階段實作計畫

| 文件屬性 | 內容 |
| --- | --- |
| 文件編號 | DITTO-PLAN-001 |
| 版本 | 1.0.0 |
| 日期 | 2026-09-19 |
| 狀態 | 待評審；工期與資源為建議值，須於 G0 結束後核定 |
| 對應需求 | [Ditto PRD v0.4.0](../../docs/product/Ditto-PRD-v0.4.0.md) 全文 |
| 對應底座 | `../../deepseek-harness`（Cordis 4.0.0-rc.7 vendored fork） |

本目錄是把 PRD v0.4.0 的 116 項需求與 32 組驗收情境，轉為可執行、可驗收、可追溯的工程計畫。計畫不重述 PRD，只回答「先做什麼、由誰做、做到什麼程度算過、失敗時退到哪裡」。

PRD 是需求的唯一權威；本計畫是實作順序的權威。兩者衝突時以 PRD 為準，並在本目錄留下決策紀錄。

**目前進度（2026-10-07）**：owner 依實際使用接受 G0、G1 完成（[D-38](../../.agents/notes/decisions/2026-10-07-d38-g0-g1-owner-acceptance.md)），下一開發階段為 G2。逐項證據與剩餘工作見 [G0 評審](../../.agents/notes/gate-reviews/G0-exit.md)、[G1 評審](../../.agents/notes/gate-reviews/G1-exit.md)；下列工期仍是原計畫估算。

## 文件

| 文件 | 內容 | 主要讀者 |
| --- | --- | --- |
| [00-findings.md](00-findings.md) | 三方研究結論：PRD 硬性約束、原型可沿用資產、Harness／Cordis 底座機制與落差 | 全體 |
| [01-architecture.md](01-architecture.md) | 目標架構：程序邊界、契約與型別產生、狀態所有權、倉庫結構、待凍結選型 | Core／Host／Shell |
| [02-cordis-adoption.md](02-cordis-adoption.md) | Cordis 沿用對照表、`ditto-host-loader` 交易層設計、橋接契約、生命週期契約測試清單 | Host／Core |
| [03-phases.md](03-phases.md) | **核心**：G0～G5 分階段工作分解、交付物、出口門檻、驗收對應、估算 | 全體 |
| [04-verification.md](04-verification.md) | AT-01～32 驗收矩陣、NFR 量測方法、測試分層與 CI／真機 runner | QA／全體 |
| [05-risks-decisions.md](05-risks-decisions.md) | 風險登記、待決策清單與最晚時點、團隊與估算假設 | 產品／管理 |

建議閱讀順序：00 →（01、02）→ 03 → 04 → 05。只想知道「做什麼」的讀者可直接看 03 的階段總表。

G2 的可實作細分見 [plan/04](../../plan/04/README.md)：沿用已完成的 G0／G1 底座，依 D-09a 加入 Codex 個人訂閱＋app-server，保留原28包，增補到44包與十九項出口；契約選型、125人週估算、D-44程序架構與加嚴項為提案，沒有改動下列上位階段門檻與估算。

G3 的可實作細分見 [plan/05](../../plan/05/README.md)：完整對應 issue #15～#34、十九項 G2 待評審交接與原五項出口。依 D-45 開始獨立基礎設施，後續 [D-46](../../.agents/notes/decisions/2026-10-13-d46-g2-functional-acceptance-and-g3-integration.md) 接受 G2 功能完成並授權完整 G3 接線；原量測缺口仍追蹤，64 人週維持提案。

## 階段總覽

| 階段 | 主題 | 一句話目標 | 建議工期 | 主要出口門檻 |
| --- | --- | --- | --- | --- |
| G0 | 原生可行性 | 確認 Wayland／Quickshell／Rust 地基真的能管理原生應用，並量到第一組資源數字 | 6–8 週 | 原生應用可用；合成器缺口表成立；UI 重啟不終止應用；初始 PSS 預算與工具配額核定 |
| G1 | 組合底座 | 不靠模型，就能以確定性流程完成跨插件替換、保存與回復 | 14–18 週 | AT-04／05／08／09／19／23／27／30／31／32 通過；無資源殘留 |
| G2 | 對話垂直整合 | 真實模型產生 ChangeSet，經 Rust 驗證後改變真實桌面 | 10–12 週（與 G1 後段交錯） | AT-02／03／08／10／11／14／24／28 通過 |
| G3 | 受限生成與移植 | 對話能產出兩種真的新插件，且失敗不傷桌面 | 8–10 週 | AT-06／07／18／22 通過 |
| G4 | MVP 整合 | 可安裝、可發行、達成核定資源與效能目標 | 10–12 週 | AT-25／26／29、全部 P0、核定預算通過 |
| G5 | 生態擴展 | 第三方隔離、自助安裝與更自由的生成 | 另立 | 獨立發行門檻 |

累計至 MVP：約 12–15 個月（假設見 [05-risks-decisions.md](05-risks-decisions.md#3-團隊與估算假設)）。G1 與 G2 可交錯，G3 不得繞過 G1 的變更與救援基礎。

## 本計畫的五條不可違反原則

1. **權威只有一份。** Rust Core 持有配置 revision、權限授予與能力綁定的權威寫入。Cordis 宿主管宿主內依賴與插件實例，不保存第二份正式 Profile；Agent 只提出計畫。
2. **Agent 退出不得中斷桌面。** Cordis 桌面服務的存活由 Profile 與服務需求決定，不套用 Agent 的閒置退出規則。
3. **模型輸出不是配置。** 自然語言與模型輸出一律先成為結構化 ChangeSet，經確定性驗證後才進入執行；完成判斷一律以系統回讀為準。
4. **可生成不等於可執行。** 生成物先在隔離測試宿主驗證；隔離未就緒前只允許受限宣告式模板輸出。
5. **量測不得自我放寬。** 資源與效能門檻以實測核定；達不到時提出數據與調整提案，不得靜默改變程序範圍或調高門檻。

## 與既有資產的關係

- `docs/product/Ditto-PRD-v0.4.0.md`：需求來源，本計畫每項交付物都回指其需求 ID。
- `apps/desktop-prototype/`：**凍結為互動契約參考**，不作為實作起點。可沿用與不可沿用的界線見 [00-findings.md](00-findings.md#3-前端原型的可沿用資產)。
- `../deepseek-harness`：Cordis 底座與 Agent 能力的移植來源。沿用範圍、鎖定 commit 與修改集見 [02-cordis-adoption.md](02-cordis-adoption.md)；設計啟發與署名見 [DeepSeek Harness 參考與啟發紀錄](../../docs/upstream/deepseek-harness.md)。

## 維護規則

階段出口評審後更新本目錄：出口門檻的實際結果（通過／未通過／條件通過）寫入 03；量測數字寫入 04；決策結果與日期寫入 05。不得回填「已達成」而無對應量測紀錄。
