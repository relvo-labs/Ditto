# D-13 契約型別採 Rust-first

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-22 |
| 狀態 | 已決定 |
| 決策者 | Core |

## 結論

能力與 RPC 型別以 `ditto-protocol` 的 Rust 型別為唯一來源，經 schemars 匯出 JSON Schema，再產生 TypeScript；不維護第二份手寫 TS 契約。

## 依據

- `crates/ditto-protocol`、`schema/` 與 `packages/protocol/src/generated/` 已形成可重跑管線。
- `export-schema --check`、`check:generated`、跨語言 round-trip 與錯版拒絕測試均通過。
- `schema/catalog.json` 與 Core 的 handler／consumer／readback gate 共用同一份描述子。

## 考慮過但沒選的方案

- **TS-first**：Rust Core 仍需另一套產生或手寫型別，會產生雙重權威。
- **兩側手寫**：短期簡單，但無法以 freshness gate 阻止漂移。

## 影響

- G1 新增能力先改 Rust 契約並重新產生 schema／TS；直接修改 generated TS 會被 CI 拒絕。
- 契約版本與封閉錯誤集仍由 Rust 契約控制。
