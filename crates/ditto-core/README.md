# ditto-core

G0 的桌面服務：Unix socket 上的換行分幀 JSON-RPC、能力路由、觀測事件流，以及啟動工作階段客戶端的受控啟動器。Core 只路由，能力由 [`ditto-compositor`](../ditto-compositor/README.md) 提供。

## 執行

```sh
cargo build --locked --workspace --bins

# 正式路徑：Core 啟動客戶端，身分由啟動器綁定
target/debug/ditto-core serve --compositor sway \
  --launch "dittoctl 0.1.0 $PWD/target/debug/dittoctl probe windows"

# 沒有合成器時：以 fixture 後端跑協定
target/debug/ditto-core serve --compositor fixture --development
```

`--development` 使用單一共用 token、接受客戶端自稱的 kind，只用於測協定；**不是 EX-07 的身分證據**，日誌也會這樣說。沒有 `--development` 時，只有這個 Core 啟動的程序能連上來。

## 這個服務目前保證什麼

| 事項 | 行為 |
| --- | --- |
| 握手 | 版本不相容明確拒絕並關閉連線；握手前的其他方法一律拒絕 |
| 身分 | 一次性 token 經已開啟的描述子交付，先綁 PID 與執行檔再釋放；訊息中自填的 `plugin_id`／`client_id` 一律拒絕 |
| 寫操作 | 執行後以 `readback` 能力回讀；不一致回 `conflict`，回應的 `_meta.readback_verified` 說明是否已確認 |
| 不支援 | 合成器做不到的操作回 `unsupported`，能力目錄的 `availability` 事前就標明 |
| 事件 | 訂閱先給快照再給事件，`seq` 單調遞增；佇列滿或合成器斷線送 `resync_required`，不靜默丟棄 |
| 取消與逾時 | `$/cancel` 對不可取消的能力**不假裝取消成功**，回應標記未取消；逾時且可能已生效者標記 `outcome: "unknown"` |
| 持久化 | 沒有。G0 不寫任何配置 |

## 測試

```sh
cargo test --workspace --locked
cargo run --locked -p ditto-protocol --bin export-schema -- --check
pnpm --filter @ditto/protocol check:generated
pnpm --filter @ditto/protocol test
bash tests/g0/run-in-container.sh window-matrix
bash tests/g0/run-in-container.sh identity-negative
```

`dittoctl probe` 是診斷與契約消費工具，**不是救援 CLI**：它需要 Core 在跑。救援模式是 G1 的交付物。各工作包現況見 [G0 工作包紀錄](../../plan/02/06-workplan.md#7-進度紀錄)。
