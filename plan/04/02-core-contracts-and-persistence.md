# 02｜Core 契約、會話與設定

工作包：CORE-07～10、AGENT-04／13、QA-08。必讀 skills：authority-boundaries、capability-contract、changeset-transaction、failure-and-rescue（完整名稱皆以 `ditto-` 起頭）。

## 1. 所有權與落點

| 資料 | 權威／儲存 | 其他程序可持有 |
| --- | --- | --- |
| Profile、revision、ChangeSet、grants、能力綁定 | 現有 Core／ditto-store | 按 revision／generation 的唯讀快取 |
| 對話、訊息、工具紀錄、任務、模型版本與 usage | Core 新 conversation service；事件檔＋SQLite 索引 | Agent 的 Session 事件模型、Shell 的分頁投影，皆可丟棄重建 |
| Agent 啟動世代、session writer、活動／approval／job 歸屬 | Core runtime manager；必要恢復資料落盤 | Agent 的本地 AbortController 與非權威活動鏡像 |
| 桌面插件設定 | Profile entry；既有 ChangeSet 產生 revision | Core-backed settings 投影 |
| AI 連線、預設模型、token／費用限額、保留政策 | Core 偏好記錄，有獨立 settings revision | Shell 表單草稿；Agent 在 turn 開始拿固定 snapshot |
| 一般 API key 值 | Secret Service；Core 持有 opaque reference | 指定供應者請求短暫解析值，禁止通用秘密工具 |
| Codex 訂閱認證 | Codex 官方登入與 keyring 管理 refresh；Core 只持非秘密 account／connection reference | app-server 必要的認證記憶體；Shell／Agent 不取得 OAuth token |
| Codex thread／turn | Core 對話為權威，app-server ephemeral thread 為可丟棄執行投影 | 本世代 ID 映射；崩潰後由 Core 歷史重建，不另存正式會話 |
| 上下文內容 | Core 授權與擷取 broker；預設臨時內容 | 本 turn 的引用／有界內容，顯式授權後才送模型 |

不得把 AI 偏好硬塞進現有 Profile 假冒 schema 支援。Core 偏好另有 revision，桌面設定仍走 Profile；兩者的 `revision_kind` 在 wire 上區分，絕不把 settings revision 當配置 base_revision。

新增路徑提案：`crates/ditto-protocol/src/agent.rs`、`conversation.rs`；`ditto-store/src/conversations.rs`、`preferences.rs`；`ditto-core/src/agent_manager.rs`、`conversations.rs`、`approvals.rs`、`context.rs`、`credentials.rs`。既有 `session.rs` 保留合成器角色。確切模組拆分可在 PR 調整，所有權不變。

## 2. 協定遷移先於呼叫

現有閉集含 ErrorName 12 項、EventTopic 六項、ChangeOrigin 的 `AgentStandin`；新增 conversation payload、真正 Agent origin 或必填欄位可能讓舊 decoder 拒絕。D-39 提案整體升至 `0.3.0`，M0 先做相容矩陣與共享向量，不能因「新增 API」就假設舊 client 相容。

順序：Rust 型別／enum及目錄 → exporter → JSON schema／TS → router → client／QML／hostd／CLI → 跨語言向量與文檔 → 一起部署。保留舊儲存資料的前向遷移，舊 wire 版本握手明確拒絕；G1 fixture 升級測試，不假冒具備舊版兼容。若選雙版本，另列每一方法與事件的降級策略和成本。

沿用現有 ErrorName，不預設擴張；具體 `reason` 必須使用 Rust 宣告的封閉子碼。建議區分 `approval_unavailable`、`grant_revoked`、`session_owned`、`stale_sequence`、`quota_exceeded`、`keyring_locked`、`storage_full`、`context_expired`、`operation_unknown`。不得塞進任意字串後讓模型依猜測分支。

### 2.1 新 API 提案矩陣

所有列都需 CapabilityDescriptor 的版本、input／output schema、錯誤、scope、取消、冪等、timeout、readback、provider、availability。以下 prefix／scope **待 CORE-09 定案**；內部方法不得全部暴露成模型工具。Definition 均在 Rust，Provider 均為 Core，Consumer 列如下。

| 候選方法 | Consumer／scope | 取消；冪等；default／max timeout | 回讀與主要拒絕 |
| --- | --- | --- | --- |
| `agent.runtime.ensure/get` | Shell／CLI；`agent.interact` | ensure 等待可取消，單例自然冪等；2s／10s | get；unavailable、timeout、permission_denied |
| `agent.turns.submit/get/cancel` | Shell／Agent；session resource＋`agent.interact` | submit受理前可取消；client_message_id冪等；2s／10s | get含task與accepted watermark；conflict、not_found、cancelled |
| `agent.sessions.create/open/stat/list` | Shell／Agent；`agent.sessions.read/write`＋owned session | 讀可取消；create keyed／open natural；2s／10s | stat；conflict、invalid_params、permission_denied |
| `agent.sessions.read/append/flush/close` | Agent；writer lease＋generation＋session scope | append/flush只在寫入前取消，close不可取消；batch key／seq 冪等；2s／10s | durable_seq／read；conflict、unavailable、internal |
| `agent.sessions.export/delete` | Shell／CLI；`agent.sessions.export/delete` | export可取消、delete tombstone後不可；keyed；2s／10s | stat；不能模型自授權匯出／刪除 |
| `agent.settings.describe/patch` | Shell／trusted settings adapter；`agent.settings.read/write` | patch受理前可取消；expected revision＋key；2s／10s | describe；conflict、invalid_params |
| `agent.providers.list/probe` | Shell／Agent；`agent.settings.read`／指定provider connect | probe可取消、無副作用重播；natural；10s／30s | 脫敏連線結果；keyring或network unavailable |
| `agent.providers.login/cancel_login/logout/status` | Shell／Core-mediated backend；指定 connection 管理 scope，不暴露模型 | login start keyed、cancel/logout自然冪等；受理2s／10s，瀏覽器等待另設 expiry | 僅 auth URL／登入狀態／非秘密帳號摘要；晚事件與錯世代拒絕，無 token 回傳 |
| `desktop.approvals.request/get/decide` | Agent request；Shell decide；由 Core 判 principal | 等待可取消；request key／一次決定；2s／10s，人的等待期限另列 | get；permission_denied、conflict、unavailable |
| `desktop.context.acquire/read/release` | Shell／Agent；具體 file／clipboard／capture grant | acquire可取消、token一次使用或TTL；keyed；5s／30s | metadata/hash；context_expired、permission_denied |
| `desktop.operations.get`（僅既有查詢不能覆蓋的種類） | Shell／Agent／CLI；原 operation owner或diagnostic reader | 讀可取消；natural；2s／10s | accepted／terminal／unknown，not_found不是重試授權 |
| `desktop.events.unsubscribe` | 訂閱者；原subscription owner | 自然冪等；2s／10s | subscription removed；不得替別人取消 |
| `desktop.jobs.submit`（限定 kind）及既有 get/list/cancel 擴充 | trusted consumer；每job resource與kind scope | 按狀態取消；keyed；2s／10s，工作期限另列 | jobs.get；不接受模型任意 executable／argv |

submit/ensure 的超時是**受理或等待超時**，不是模型整個 turn 的 deadline。短 RPC 不持有 router 鎖等使用者或 provider；pending 工作返回持久 ID，由事件與 get 查看。權限不明、提供方不存在或 keyring 無法用時 fail-closed，available=false 的方法不給模型使用。

既有 `desktop.changes.get` 已接受 `operation_id`，配置變更的恢復先沿用它；jobs沿用`desktop.jobs.get`。CORE-10先盤點非ChangeSet副作用的紀錄與查詢缺口，只有確有必要才新增通用operations.get，並投影**同一份**既有操作紀錄，不另建第二份結果權威。

### 2.2 事件與流量

提案新增 conversations／agent／approvals／jobs topics，按 topic 和 session／request／job 的可見範圍授權。沿用 seq／prev_seq／resync_required，加入 generation、防止舊 Agent 串流覆蓋新 turn。桌面快照不能充當聊天快照：新 topic 回對應 snapshot＋watermark，Core 保證快照與之後事件無空窗。

串流合併建議每 50ms 或 4KiB 一批；每訂閱沿用 1024 事件上限並增 byte cap（提案 4MiB），溢出明確 resync，不排無限 token。QML 對隱藏視窗停止非必要渲染；Core 仍儲存進度，重開從 snapshot 補齊。移除上下文 grant 即撤銷相關讀取與訂閱；unsubscribe 落實 Core 端，不只 TS 本地丟 callback。

## 3. Core-backed 會話

### 3.1 儲存與並發

提案在既有 Core state root 下建立 `conversations/<uuid>/header.json` 與 append-only `events.jsonl`；不接受 caller 傳任意資料路徑。目錄 0700、檔案 0600、拒絕 symlink／path traversal，Core 唯一打開 writer。SQLite 新表索引 session、format_version、next_seq、durable_seq、header hash、tombstone；turn/task關聯另表，事件檔是對話內容的權威，索引可重建。

SessionEvent 用 pinned Harness vocabulary，但 wire 使用 Rust 的驗證 envelope＋已審查 event union，不讓 unvalidated JSON 原封落盤。上游 ts schema 與 Rust 映射共用正反向測試向量；未知事件／格式拒絕，不能安靜忽略工具事件。會話格式版本與 protocol version 各自管理。

一個 session 只容許一個 writer lease，綁 Core launcher generation 和 authenticated principal；多個 Shell 只能提交輸入與讀取。Agent 世代失效時 Core 撤 writer，舊 handle 的 append 一律拒絕。每批 `(session_id,batch_id,expected_next_seq,content_hash)`，同 key 同內容返回原 ack，同 key 不同內容 conflict；連續序號不可跳躍。create/open/write ownership 與 close 皆對應上游語意；export 是 Ditto 的擴充，不是 upstream abstract class 已有的方法。

### 3.2 crash consistency 與屏障

1. create 寫暫存 header，fsync檔案，rename，fsync目錄，再建立可重建索引；回應前空會話也完成 materialize。crash留下孤立檔由啟動 reconciler辨識。
2. append 在該 session 序列化，驗證完整 contiguous batch 後寫事件。可批次持久，但 ack 區分 accepted_seq 與 durable_seq，不把兩者混稱保存。
3. flush fdatasync事件檔，再 SQLite transaction 更新 durable watermark／hash；只有两者完成才回 durable ack。檔案較新時重建索引；索引絕不宣告檔案尚未 durable 的尾端。
4. 每批有batch ID、完整長度／hash與結束標記，事件仍逐seq驗證；讀取只回完整已提交批次的有效前綴。crash recovery隔離整個未完成batch，首次寫前截斷並留診斷；同key重送可查完整批次或重新接受未提交批次。中段corruption不默默跳過、不能回復成另一段對話。實體batch envelope與上游logical SessionEvent分開，adapter只回event。
5. flush失敗停止接受新副作用，UI保留未存草稿與「尚未保存」提示；已被Core受理的ChangeSet由交易層完成／回復。磁碟滿不能退回Agent自己存檔。

上游 Session.append 是同步記憶體事件，`session/event` feed 是非同步觀察；不能把 observer發出RPC當成 durable完成。AGENT-13負責 drain queue＋`session/flush`屏障。使用者訊息accepted、工具dispatch前intent、工具result與turn終了各有flush；純token delta可合批。Core在受理變更時再原子寫入turn/tool/operation關聯，不依賴Agent最後一句一定寫成功。

### 3.3 任務與刪除

Core持久turn/task狀態提案：queued／running／awaiting_approval／cancelling／succeeded／failed／partial／unknown／cancelled。工具operation與ChangeSet保持原狀態機，不能拿turn「cancelled」覆寫已committed change。恢復讀turn與operation，修復未終了事件，不重跑歷史。

刪對話：先阻止新turn，要求取消或等活動結束，再tombstone、撤讀取／writer、刪內容、重建索引；中斷可續做。revision因果關聯保留匿名session ID／change ID，不保留對話文本，不 cascade 刪Profile／ChangeSet。預設不自動expiry（待D-41），可顯式清除；大小达到限額返回可理解錯誤，不靜默刪歷史。匯出對話需顯式選擇，Profile匯出不包含對話／附件／絕對私人路徑。

## 4. 設定與因果關聯

桌面 settings adapter 把 describe投影到entry.config／appearance／layout，patch轉ChangeSet並攜base_revision；不得沿用Harness settings寫YAML或loader.write。AI偏好patch以expected settings revision做CAS，含 provider／backend ID、model ID、帶 tag 的 auth union（`codex_subscription` 非秘密 connection reference 或 `api_key` credential_ref）、request/token/cost限額與retention選項；schema禁止raw secret。訂閱配額不以 API 費率換算；限額的 enforcement 能力依後端明示。turn保存當時settings revision與非秘密模型fingerprint，正在執行的請求不被後續表單無聲改寫。Codex 外部 wire 從 pinned CLI 產生並獨立管理，再映射到 Rust-first 的 Ditto wire，不能用外部 TS 反向取代 Core 契約；詳見 [10](10-codex-app-server.md)。

真正 Agent origin 提案含session_id、turn_id、tool_call_id；Core從受控身分验證並補齊，不信caller自述身份。operation_id由Core持久映射到client intent key、change_id、job_id與event_seq；同key不同內容拒絕。CFG-02需要能由卡片跳對話，也能由對話查revision；刪對話後顯示「對話已刪除」仍能查桌面變更。

## 5. 實作驗證

單元／故障測試覆蓋：兩writer、舊generation、重複batch、跳seq、unknown event、flush未完成崩潰、header rename後crash、檔案／索引各先一步、磁碟滿、torn tail、中段腐敗、刪除中斷、v1→新schema失敗rollback。既有Store backup／migration policy沿用；新表不可令G1重啟復原回歸。跨語言同向量、來源型別重新產生無diff，見 [07](07-verification-and-measurement.md)。
