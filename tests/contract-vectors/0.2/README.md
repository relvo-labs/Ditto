# 協定 0.2 共享契約向量

同一批檔案由兩個 runner 讀取（G1-QA-01、EX1-06）：

- Rust：`crates/ditto-core/src/tests.rs` 的 `contract_vectors_*`（程序內 Core）
- TS：`packages/protocol/src/vectors.test.ts`（對 `target/debug/ditto-core` 開發模式）

兩種向量：

| 種類 | 形狀 | 兩邊各做什麼 |
| --- | --- | --- |
| `shape` | `{kind:"shape", description, type, valid, value}` | Rust：以 `type` 對應的型別反序列化，`valid` 為真者必須成功、再序列化後與 `value` 相等；TS：以 `schema/<type>.json` 驗證 |
| `scenario` | `{kind:"scenario", description, client, steps:[{send, expect}]}` | 兩邊都對一個真的 Core 送出 `send`，檢查 `expect` |

`expect` 可用的鍵：`error_name`、`error_reason`（`error.data.reason`）、`result_path`＋`equals`（以 `/` 分隔的路徑）、`result_has`（結果含這些鍵）。步驟中的 `"$head"` 會代換成目前 head revision，`"$prev.<path>"` 代換成上一步結果的欄位。

任何一邊新增欄位而另一邊沒跟上，向量就會失敗。
