# D-39｜G2 協定 0.3 凍結

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-09 |
| 狀態 | 已決定 |
| 決策者 | 使用者／專案 owner Lei-k（採 [G2 評審](../gate-reviews/G2-exit.md) §5 提案） |

## 結論

協定 0.3 以 2026-10-09 分支 `codex/g2-agent-foundation` 上的形狀凍結：wire 型別、閉集原因、`conversations` 主題、approval 綁定（同一 turn、同一能力、同一參數雜湊，只用一次）與 `agent.turns.trace` 都列入契約。之後的變更走新版本或明確相容規則，不在 0.3 內悄悄改形狀。

## 依據

- 契約文件：[docs/contracts/agent-0.3.md](../../../docs/contracts/agent-0.3.md)、[protocol-0.2.md §7](../../../docs/contracts/protocol-0.2.md)；欄位以 `schema/*.json` 為準。
- Rust 與 TS 共享向量通過；`tests/g2/run.sh` 十組（confine、foundation、codex-run／faults／crash／injection／races、jobs、lifecycle、cold-start）在開發機通過。
- 凍結前最後一項變更（同日，`66fcadb`）：`profiles.delete` 範圍與 approval 的 `arguments`／`target`，為了讓 Agent 刪除設定檔時逐次詢問並顯示 Core 讀出的名稱（D-43 的判定決定）。凍結包含它。

## 考慮過但沒選的方案

- 讓 trace 留在診斷、不進契約：語意集與 Agent 的變更歸屬都依賴它，不列入契約等於讓評分建立在非契約介面上。
- 延到 G3 再凍結：G3 的生成工作會疊在這些型別上，延後只會讓之後的不相容改動更多。

## 影響

- `milestones/01/05` 的 D-39 列改為已決定。
- 舊 wire（0.2 client）仍依 0.3 相容矩陣明確拒絕，不降級執行。
- 之後新增 approval 類型或事件主題要走版本流程；`ditto-capability-contract` 的判準不變。
