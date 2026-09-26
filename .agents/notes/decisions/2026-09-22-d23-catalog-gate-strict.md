# D-23 能力目錄一致性 gate 採嚴格模式

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-22 |
| 狀態 | 已決定 |
| 決策者 | Core |

## 結論

能力目錄的四項一致性檢查任一失敗即擋合併：每項能力須有 handler、至少一個標記 Consumer、寫操作須有 readback，且沒有可驗證 readback 的能力不得標為 `claimable`。Schema 與生成 TS 產物不新鮮也擋合併。

## 依據

- Rust 目錄、handler 註冊與 Consumer 標記已由 workspace 測試交叉檢查。
- `schema/catalog.json` 與 `packages/protocol/src/generated/` 都由 Rust-first 管線產生；本機完整 CI 等價流程已通過。
- EX-01 實測確認回成功但狀態不一致必須是 `conflict`，不能把 handler 存在等同能力成立。

## 考慮過但沒選的方案

- **警告但允許合併**：漂移會讓 Agent／Shell 看見不能真正執行的能力，拒絕。
- **只檢查 schema 新鮮度**：無法證明執行接線與 Consumer 存在。

## 影響

- D-23 結案；`.github/workflows/contracts.yml` 保持阻擋式 gate。
- 新增能力時必須一次完成 seam triangle 與 readback 語意，不能先放空描述子。
