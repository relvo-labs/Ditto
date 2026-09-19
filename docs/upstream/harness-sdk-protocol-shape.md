# Harness SDK protocol 形狀參考紀錄

| 欄位 | 內容 |
| --- | --- |
| package | `@deepseek-ai/dsh-sdk-protocol` `0.1.6-alpha.2`，`packages/sdk/protocol/` |
| upstream_repo | `https://github.com/deepseek-ai/deepseek-harness` |
| upstream_commit | `ddefc45fbc7f8e46dd73185e68295696d1297887`（本機參考 checkout） |
| port_kind | 薄轉接：僅參考「每行一則 JSON-RPC 2.0 訊息」的協定形狀；**零行上游程式碼複製**，沒有引入上游套件 |
| modifications | 不適用於上游原始碼。Ditto 在 [Rust 契約](../../crates/ditto-protocol/src/rpc.rs)、[Core](../../crates/ditto-core/src/lib.rs)與 [TS client](../../packages/protocol/src/client.ts)獨立實作；加入 `params._meta`、版本握手、封閉錯誤集、身分檢查與 1 MiB 行長上限。後續事件、取消及身分綁定仍未完成 |
| host_contract | G0 Rust Core 透過 Unix socket 對本機 TS／Rust 診斷 client 提供能力；目前是開發模式，受控啟動器信任綁定未完成 |
| trust_level | Core 與診斷 client 為專案自有程式；開發 token 不構成獨立插件身分或沙箱 |
| license | 上游套件與根目錄 `LICENSE` 為 MIT；本次未散布上游程式碼。若未來複製實作，需重新盤點並保留 MIT 版權與授權文；本紀錄保留來源追溯 |
| test_matrix | `cargo test --workspace` 的握手、錯版、自述身分與能力目錄測試；`pnpm --filter @ditto/protocol test` 的 Rust Core ↔ TS client socket 測試；`dittoctl probe capabilities` 開發煙霧測試。事件／重連／取消尚無通過證據 |

## 沿用邊界

| 直接沿用 | Ditto 新增橋接 | Rust 原生能力 | 尚未支援 |
| --- | --- | --- | --- |
| 換行分幀 JSON-RPC 的訊息形狀（概念）；無上游套件或程式碼 | TS client 的 G0 診斷呼叫 | Unix socket、能力目錄、版本拒絕與錯誤映射 | 事件序號與快照重連、取消、受控啟動器身分綁定 |

上游以 stdio 傳輸；Ditto 的 Unix socket、桌面能力與權限語意是本專案定義，不能描述為 Harness 已提供的功能。
