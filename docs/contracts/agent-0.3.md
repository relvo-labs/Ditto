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

生成寫入與啟用進入 coordinator 的序列化接受點時，再檢查工作階段鎖定與當前 grant，避免排隊期間撤銷後仍寫入。已消耗的同次 `allowed-once` 由 Core 內部 receipt 維持；它不是 wire 欄位，不能由模型、參數或 caller metadata 自行聲明，也不給下一次呼叫使用。

## 5. G3 Shell 掛載回讀的相容增補

依 D-39 的明確相容規則，`PanelMount` 新增選用 `artifact_id: string | null`，由 Rust 匯出至 `participant-observation`、`participant-state-output` 與 `shell-report-input`。普通供應者仍省略該欄位；舊格式在新 Core 上可解碼，普通插件的判定保持相容。

G3 固定模板由 Shell **實際掛載物件的 config** 回報 artifact id。Core 只有在 id 與預期生成版本相同、元件已掛載可見時，才承認啟用成功。缺 id 或仍回報舊 id，會進入既有 readback 失敗與補償路徑。升版不能只憑不變的 entry id 判定成功。

舊 Core 的 strict schema 不接受此新增欄位，故新增欄位只由配對的 G3 Core／Shell build 使用；混用舊 Core 會明確拒絕，不忽略欄位。新 Core 配舊 Shell 可以維持普通桌面；生成啟用因缺少版本證據而失敗，不宣告成功。此增補不新增事件、錯誤列舉或 approval 類型。三個共用向量涵蓋舊格式、新格式及錯誤型別拒絕。

## 6. Codex 訂閱可用性與錯誤原因

`agent.providers.status` 的 `available: false` 表示這次執行無法提供 Codex 訂閱連線，可能未配置支援版本，也可能初始化失敗；不能據此宣稱只是尚未登入。Shell 只在 `available: true` 且未登入時提供訂閱登入入口。AI 設定仍保留 API 金鑰選項；API 連線以 `agent.credentials.status` 確認金鑰引用可用，不要求 Codex 登入，也不讀取金鑰值。這是本機配置就緒狀態，不代表遠端模型已通過網路驗證。桌面啟動不要求 Codex。

Shell 也讀取 `agent.runtime.get`：已確認的啟動故障或 ready 世代的空 `backend_pid` 會優先於過時的 provider 狀態，阻止登入。只有回讀到存在且隔離已驗證的 backend，`backend_unsupported` 才提示改選模型；其他情況顯示可用性或復原步驟。

`failure_reason` 在 wire schema 是選用字串；目前 Core 的封閉產生值為 `backend_binary_mismatch`、`backend_catalog_unavailable`、`isolation_unavailable`、`backend_launch_failed`、`launch_failed`、`backend_exited`、`startup_timeout`、`drain_timeout`。Shell 分別提示核對檔案、核對模型清單、檢查核心與隔離、重新登入或重新開啟對話；未知值沿用通用文案，不顯示原始字串。runtime 回覆也以讀取序號作廢晚到訊息，斷線或設定讀取失敗會清除舊世代投影。

登入等 provider 請求沿用既有 `unavailable` 錯誤及 `data.reason: system_unavailable`，在選用的 `data` 物件內帶 `reason_code`；不新增 `UnavailableReason` 或 schema 欄位。Runtime 與 Core 僅傳遞以下原因碼：

| reason_code | 意義 |
| --- | --- |
| `backend_unsupported` | 訂閱連線無法提供所需操作 |
| `provider_unavailable` | 模型連線不可用 |
| `provider_timeout` | 模型連線逾時 |
| `rate_limited` | 訂閱額度限制 |

Core 不轉送任意遠端錯誤資料或原始訊息。Shell 用原因碼選擇 i18n 文案，診斷另行呈現；有明確原因碼的失敗不當作啟動中自動重試。

參考工作階段安裝程式會在找不到釘選 Codex 時提示安裝、重新安裝工作階段與重新登入，或改用 API 金鑰。登入後的 `$XDG_RUNTIME_DIR/ditto/session.env` 有 `DITTO_CODEX_STATUS=available|backend_unsupported|isolation_unavailable` 與 `DITTO_CODEX_LANDLOCK_ABI`，只記錄安裝時是否配置釘選檔案與當時的 ABI 相容性，不代表執行期健康；執行期以 `agent.providers.status` 回讀為準。

開發回歸入口：`python3 tests/g4/codex-availability/test.py`（設 `TMPDIR` 為 lane scratch）、`cargo test -p ditto-core provider_route`、`corepack pnpm --filter @ditto/agent-runtime test`、`tests/g4/visual/run.sh <evidence-dir>`。安裝測試只執行原安裝程式的選擇與 session 環境區段，不執行安裝或啟動桌面。
