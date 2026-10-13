# G3 受限宣告式 SDK

#22 的第一批實作：產生固定模板引用與有界描述的**可檢視候選**，沒有安裝、啟用、正式 `GeneratedArtifact` 或 Agent 工具。正式契約與治理紀錄待 #20／19 依 Rust-first 管線接入 Core。

```sh
cargo run --locked -p ditto-generation -- inspect < crates/ditto-generation/examples/tasks-summary.json
cargo run --locked -p ditto-generation -- inspect < crates/ditto-generation/examples/workspace-actions.json
bash tests/g3/run.sh
```

輸入限 16 KiB；拒絕未知欄位／模板／enum、無界尺寸、重複工作區、任意程式碼或權限欄位。輸出有獨立的描述與固定模板 SHA-256、需要的既有能力引用、只驗證描述的狀態及 `activation_available:false`。這個工具不產生可安裝套件，不把描述驗證冒充五關驗證。

QML 原始碼固定並以版本鎖定，顯示文字僅作 `Text.PlainText` 資料，從不插值為原始碼或動態 import。待辦模板使用目前 `Task` 的 `task_id/text/done/source` 欄位；工作區模板只發出固定的 workspace ID 動作 signal，正式能力代理尚未接線，預設顯示資料／操作不可用。測試資料以文字標明。

QtTest 只載入可信固定模板，以明示的 fixture 驗證資料、文字、操作不可用、鍵盤與健康／釋放；不是隔離真實預覽，也不構成 AT-06。兩種例子採 D-17 預設做開發，沒有核定最終選型。自由 QML／Node／原生入口都不在 SDK 格式內。
