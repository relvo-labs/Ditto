# Agent 與對話（協定 0.3 增補）

型別來源：`crates/ditto-protocol/src/agent.rs`、`lib.rs`；欄位形狀以 `schema/*.json` 為準。本文只寫 G2 起新增、且程式碼已落地的語意。設計背景見 [plan/04/02](../../plan/04/02-core-contracts-and-persistence.md)、[plan/04/10](../../plan/04/10-codex-app-server.md)。

## 1. 後端與隔離

- `agent.runtime.ready` 的輸入是空物件。帶 `backend_pid`、`isolation_verified` 等欄位一律 `invalid_params`：後端身分與隔離只來自 Core 自己的啟動（[codex-backend-boundary](../platform/codex-backend-boundary.md)）。
- `agent.runtime.get` 的 `isolation_verified` 為真，表示本世代的後端由 Core 經 `ditto-confine` 啟動、仍在執行。後端退出即轉為假並讓世代 drain。
- `failure_reason` 新增：`backend_binary_mismatch`、`backend_catalog_unavailable`、`isolation_unavailable`、`backend_launch_failed`、`backend_exited`。拒絕啟動後端時 controller 仍會啟動（設定、會話可讀），模型 turn 以 `backend_unsupported` 結束。
- `--agent-backend-test-provider http://127.0.0.1:<port>/v1` 只在 fixture compositor，或環境 `DITTO_TEST_FIXTURE=1` 時接受；Core 記錄 `agent.test_provider` 事件，`agent.providers.status` 的 `account_label` 為 `loopback test model`。登入工作階段兩者皆不設定。

## 2. `conversations` 事件主題

`desktop.events.subscribe` 新增主題 `conversations`，需要 `agent.sessions.read`（Shell、CLI、Agent 預設允許）。酬載：

```json
{"type":"conversation_updated","session_id":"ses-…","next_seq":8,
 "turn_id":"turn-…","turn_state":"succeeded"}
```

- 只帶 id、Core 的游標與 turn 狀態，**不帶訊息文字**；內容仍經 `agent.sessions.read`，受其 scope 約束。
- 發出時機：建立會話、Agent append、送出／取消／claim／完成 turn、工具 intent 與工具結果寫入之後。刪除會話發出 `deleted: true`、`next_seq: 0`。
- `next_seq` 大於已讀位置時重讀；鏈斷（`prev_seq` 不符或 `resync_required`）就重新訂閱並從 Core 重讀，不推測遺失內容。
- `turn_state: succeeded` 是 Core 依工具與 ChangeSet 紀錄重新判定後的結果，不是模型自述（見 `ditto-store::turns::complete`）。

## 3. Shell 對話（最小入口）

`shell/chat/ConversationState.qml` 是唯一的對話投影：開啟聊天後才訂閱、才讓 Core 啟動 Agent。草稿只在記憶體；送出用固定 `client_message_id`，失敗時保留文字、重試不會被 Core 接受兩次。角色七態由 Core turn 狀態與工具紀錄導出，`starting` 是 Core 生命週期狀態。登入只把官方授權網址交給系統瀏覽器；Shell 從不接觸 token。登入等待期間每 3 秒讀一次 provider 狀態，直到完成或到期（沒有登入完成事件）。

Shell 控制 socket 新增：`chat`（唯讀 JSON：狀態、事件種類、變更 id、最後回答）、`chat-send <text>`（等同在欄位輸入並按 Enter）。

## 4. 互動授權（approval）

- Shell 在 `shell.report` 帶 `approval_responder: true` 才算可回應。沒有可回應的 Shell 或工作階段鎖定時，`desktop.approvals.request` 立即記為 `unavailable`，不讓 turn 空等。
- 待決期間 turn 為 `awaiting_approval`（角色「待確認」）；決定後回到 `running`。重複請求同一 intent 回傳同一筆 approval。
- Core 以 `desktop.approval_requested` 通知 Shell。Shell 顯示的內容來自 Core 紀錄的能力與 resource scope；Agent 填的 `purpose` 只放在診斷並標示「未經驗證」。鍵盤預設焦點在「拒絕」，Esc 與關閉視窗都等於拒絕。
- 刪除設定檔（`desktop.profiles.delete`）無法復原，另有 `profiles.delete` 範圍：Agent 預設沒有這項授予，所以每一次刪除都要問。請求須附上該次呼叫的 `arguments`；Core 核對它們的雜湊等於 `intent_hash`，讀出設定檔名稱放進 approval 的 `target` 給 Shell 顯示，`arguments` 本身不保存。
- `allowed-once` 只讓 Core 在共用授權路徑放行**同一 turn、同一能力、同一參數雜湊**的一次呼叫（`approvals::consume`）；不建立持久 grant。
