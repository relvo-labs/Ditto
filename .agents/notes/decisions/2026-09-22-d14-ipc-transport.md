# D-14 IPC 傳輸與佇列細節

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-22 |
| 狀態 | 已決定 |
| 決策者 | Core |

## 結論

Core 使用 `$XDG_RUNTIME_DIR/ditto/core.sock` 的 Unix domain socket，權限 0600，以換行分幀 JSON-RPC 2.0 傳輸；自訂信封置於 `params._meta`／`result._meta`。事件 replay 與每訂閱者佇列容量固定為 1024，溢位回 `resync_required`，不得丟事件後繼續假裝同步。

身分由受控啟動器綁定 peer PID、執行檔與一次性 token；訊息中的 client kind 或 plugin id 不構成身分。

## 依據

- 實作：`crates/ditto-core/src/main.rs`、`session.rs`、`events.rs`、`identity.rs` 與 `crates/ditto-protocol/src/rpc.rs`。
- Rust／TS 契約測試涵蓋握手、錯版拒絕、亂序、重連、溢位、取消與逾時。
- 三項身分負例會拒絕自填身分、未綁 token 與同 UID 錯程序。

## 考慮過但沒選的方案

- **TCP localhost**：擴大不必要的網路面，且不如 Unix socket 直接取得 peer credentials。
- **WebSocket／D-Bus 作主通道**：增加 G0 不需要的執行期與契約形狀；D-Bus 只留給平台上無替代路徑的服務。
- **無界佇列或靜默丟事件**：前者可耗盡記憶體，後者會讓 Shell 在未知狀態上繼續操作。

## 影響

- 所有 client 必須先握手並遵守 1 MiB 行長上限、版本與 `_meta` 信封。
- G1 的 Cordis bridge 與租約事件沿用同一溢位／重新同步語意，不另建第二條桌面 RPC。
