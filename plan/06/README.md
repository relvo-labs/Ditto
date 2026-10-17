# G4 執行計畫｜MVP 整合

| 文件屬性 | 內容 |
| --- | --- |
| 文件編號 | DITTO-PLAN-006 |
| 版本／日期 | 0.1.0／2026-10-17 |
| 狀態 | 執行提案；尚未實作。D-18、D-11、人力與硬體待 owner 決定 |
| 上位權威 | [PRD v0.4.0](../../docs/product/Ditto-PRD-v0.4.0.md) §19～24；[milestones/01 G4](../../milestones/01/03-phases.md#g4mvp-整合)；[04 驗收矩陣](../../milestones/01/04-verification.md) |
| 追蹤 | [#42](https://github.com/relvo-labs/Ditto/issues/42)，子 issue #43～#61；承接 #35～#39、#41 |
| 開工基線 | `main@39da2977fa1a819033b4a68a3cdf350e2b32f808`（PR #40 合併） |
| 前置 | G0／G1 依 [D-38](../../.agents/notes/decisions/2026-10-07-d38-g0-g1-owner-acceptance.md)、G2 功能依 [D-46](../../.agents/notes/decisions/2026-10-13-d46-g2-functional-acceptance-and-g3-integration.md)、G3 依 [D-47](../../.agents/notes/decisions/2026-10-17-d47-g3-exit-vm-evidence.md) |

**G4 的目標：把三條改造路徑、預設體驗、系統整合、效能與診斷收斂成可安裝、可發行的 MVP。G4 出口就是 MVP 發布門檻。**

本計畫以 `39da297` 的實際程式碼為起點，不重開前階段出口，也不改寫任何門檻或預算。G3 依 VM 證據通過的裁定只適用 G3；G4 的效能、動畫與資源指標仍須在實體參考機量測。

## 1. 文件導讀

| 文件 | 用途 |
| --- | --- |
| [01 範圍與出口](01-scope-and-exit-criteria.md) | 六項出口、範圍與非範圍、現況盤點 |
| [02 交接](02-handoff.md) | G3 交接、D-38 後續、G2 follow-up 與既有決策盤點 |
| [03 驗證與量測](03-verification-and-measurement.md) | 證據環境、量測條件、AT 回歸與 nightly |
| [04 工作包與順序](04-workplan.md) | 19 個子 issue、依賴、寫入範圍、估算與分批 PR |
| [05 決策與風險](05-decisions-and-risks.md) | 待決策、風險與發布判定方式 |

## 2. 順序

1. **文件**：本計畫、D-47、D-17 補錄與狀態回寫（#43）。功能 issue 等本計畫合併後開工。
2. **並行功能**：寫入範圍互不重疊時並行；共用檔案依 [04 §3](04-workplan.md#3-寫入範圍與共用檔案) 指定單一寫入者。
3. **功能凍結**：所有出口量測與完整回歸在同一個凍結 commit 上取得。
4. **出口**：完整回歸、交付物、G4-exit 評審，交 owner 裁定。

不得因曆時壓力跳過量測、隔離或人工驗收；Agent 執行時間不換算為人週。

**pending-visual-contract**：#45／#46 的視覺研究與設計交接另線進行，待契約確認後由各 issue 承接。本 #43 不主導設計、不改 UI；視覺研究不阻擋本文件 PR 或不依賴該契約的 G4 主線。
