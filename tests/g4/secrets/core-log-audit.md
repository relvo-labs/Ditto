# #73：Core 日誌欄位盤點

對應 SEC-07、REC-06、AT-15。基底 `25c0b726ef3c3bc7c8e00232514604cc0498007e`；用以下指令盤點 `crates/` 中全部 58 個呼叫；初版欄位共 42 種，repair1 加入 `reason_code/subject_kind` 後共 44 種（不含 logger 自動加入的欄位）。沒有 `log::warn/error/info` 呼叫，結果全是 Core 的 `log::event`。

```sh
git grep -n 'log::event\|log::warn\|log::error\|log::info' -- crates/
```

`crates/ditto-core/src/log.rs::CONTENT_KEYS` 保持內容遮蔽。repair1 在呼叫點選擇 `reason_code`，只接受封閉代碼或型別化錯誤分類；沒有文字猜測代碼的 heuristic、儲存或能力變更。`coordinator.rs` 的 `change.draft` 與 router 的 `change.dropped_before_acceptance` 同時記錄封閉 `subject_kind`，原 subject 仍由共用 logger 遮蔽。

| 欄位鍵 | 分類 | 來源與內容判斷 | 結論 |
| --- | --- | --- | --- |
| `already_visible` | 診斷資料 | outputs rescue 的數量 | 保留 |
| `app_id` | 診斷資料 | stranded window 的應用識別，不是視窗標題 | 保留識別 |
| `bytes` | 診斷資料 | context 的位元組數，未記 context 內容 | 保留 |
| `capability_id` | 診斷資料 | host 註冊的能力識別 | 保留識別 |
| `change_id` | 診斷資料 | Core 建立的 ChangeSet 識別 | 保留追溯 |
| `checked` | 診斷資料 | outputs rescue 檢查數量 | 保留 |
| `command` | 診斷資料 | shortcut 綁定的 command ID，不是命令參數 | 保留識別 |
| `component` | 封閉分類 | 啟動時固定的系統元件名稱 | 保留 |
| `compositor` | 封閉分類 | adapter 的合成器標籤 | 保留 |
| `connection_id` | 診斷資料 | Core 建立的連線識別 | 保留追溯 |
| `context_id` | 診斷資料 | Core 建立的 context 識別 | 保留識別 |
| `count` | 診斷資料 | retention／tool reconciliation 數量 | 保留 |
| `credential_ref` | 診斷資料 | Secret Service 引用，沒有秘密值 | 保留引用 |
| `decision` | 封閉分類 | participant sync 的固定結果分類 | 保留 |
| `entry_id` | 診斷資料 | Core 指派的插件實例識別 | 保留識別 |
| `error` | 內容 | `jobs.finished` 的 `job.error_key`；jobs_pool 會直接接收 worker JSON 的 `error` 字串，截成 64 字仍可能含私人內容 | **新增遮蔽** |
| `from_rescue_ui` | 封閉分類 | 布林狀態字串 | 保留 |
| `generation` | 診斷資料 | host generation 計數 | 保留 |
| `job_id` | 診斷資料 | Core 建立的 job 識別 | 保留追溯 |
| `kind` | 診斷資料 | job 類型、連線種類；拒絕 handshake 時由 `connection_kind` 限為 `subject_for_kind` 允許集合或 `unknown` | 保留診斷分類；未知 peer 種類不記原文 |
| `lease_id` | 診斷資料 | Core 建立的 lease 識別 | 保留識別 |
| `mode` | 封閉分類 | `rescue`／`normal` | 保留 |
| `moved` | 診斷資料 | outputs rescue 搬移數量 | 保留 |
| `note` | 封閉分類 | `core.development_mode` 的固定提示字串 | 保留 |
| `operation_id` | 診斷資料 | 尚未接受 proposal 時的操作識別 | 保留追溯 |
| `outcome` | 封閉分類 | recovery 的狀態分類 | 保留 |
| `outputs` | 診斷資料 | 合成器提供的輸出接頭識別清單 | 保留識別 |
| `package` | 診斷資料 | builtin manifest 的 package ID，沒有 description | 保留識別 |
| `path` | 診斷資料 | builtin 套件目錄／archive 路徑 | 沿用 HOME 路徑遮蔽 |
| `pid` | 診斷資料 | peer PID | 保留 |
| `point` | 封閉分類 | fault-injection 的靜態呼叫位置 | 保留 |
| `reason` | 內容 | 原 27 個呼叫分成 4 個封閉代碼與 23 個自由文字來源；詳見下表 | 自由文字仍遮蔽；4 個封閉來源改用 `reason_code` |
| `reason_code` | 封閉分類 | 4 個既有封閉來源與 22 個型別化錯誤來源；只取固定 literals、enum 變體／ErrorKind，不取 payload | 保留安全原因分類，共 26 個呼叫 |
| `role` | 封閉分類 | participant 的固定角色 | 保留 |
| `rule_id` | 診斷資料 | region rule 的識別，不是 matcher 或使用者需求文字 | 保留識別 |
| `socket` | 診斷資料 | Core socket 路徑 | 沿用 HOME 路徑遮蔽 |
| `spec` | 內容 | `launch.exited/failed` 的完整啟動規格，包含 executable 與任意 args | **新增遮蔽** |
| `status` | 診斷資料 | OS exit status／wait 的 I/O 錯誤，或 `applied/failed`；沒有 worker stderr／輸出內容 | 保留 |
| `stranded` | 診斷資料 | outputs rescue 遺留數量 | 保留 |
| `subject` | 內容 | Core 綁定的 caller identity；不是 proposal 自由文字參數 | 保持遮蔽，作為防禦措施 |
| `subject_kind` | 封閉分類 | 兩處 proposal 日誌的固定 caller 類別；不含 host entry 尾碼或未知原文 | 保留封閉分類 |
| `unit` | 診斷資料 | worker 的 systemd unit 名稱 | 保留識別 |
| `url` | 封閉分類 | 僅 test provider；`agent_backend::parse_test_provider` 嚴格限制 `http://127.0.0.1:<非零 u16>/v1`，沒有 userinfo／query／任意路徑 | 保留 |
| `window_id` | 診斷資料 | 合成器視窗識別 | 保留識別 |

Logger 自動欄位 `ts`、`event`、`session_id` 分別是時間、程式碼固定事件名、Core session 識別，均保留。既有 `title/summary/body/clipboard/text/content/window_title` 繼續遮蔽。`description/message/prompt` 沒有出現在這批呼叫的欄位鍵；`CoreError.message` 是以 `reason` 鍵送出，已涵蓋。

識別欄位與 HOME 以外的路徑仍屬診斷資料；本次不是任意字串秘密辨識器，也沒有保證呼叫者故意把內容塞進識別字時都會被辨識。未更改 panic hook、audit 儲存與 wire response；它們不屬上述一般日誌呼叫出口。

## repair1：原 27 個 reason 呼叫的來源分類

下表行號固定於 repair1 起點 `39f5cfe2fe2b6fb59b45a83ba3f9efbc2026c427`，檔名相對 `crates/ditto-core/src/`。分類依原 `reason` 值的來源；增加安全錯誤分類不會把原自由文字改稱封閉代碼。

| 呼叫點 | 事件 | 原值來源 | 分類 | repair1 的 reason_code |
| --- | --- | --- | --- | --- |
| `agent_manager.rs:171` | `agent.backend_refused` | `Refusal::as_str()` | 封閉代碼 | 原 as_str 值：`backend_binary_mismatch/backend_catalog_unavailable/isolation_unavailable/backend_launch_failed` |
| `coordinator.rs:196` | `retention.failed` | StoreError Display | 自由文字 | StoreError 變體分類 |
| `coordinator.rs:267` | `jobs.recovery_cleanup_failed` | StoreError Display | 自由文字 | StoreError 變體分類 |
| `coordinator.rs:282` | `boot.profile_failed` | StoreError Display | 自由文字 | StoreError 變體分類 |
| `coordinator.rs:298` | `agent.tools_reconcile_failed` | StoreError Display | 自由文字 | StoreError 變體分類 |
| `coordinator.rs:340` | `boot.builtin_refused`（insert） | StoreError Display | 自由文字 | StoreError 變體分類 |
| `coordinator.rs:349` | `boot.builtin_refused`（unpack） | StoreError Display | 自由文字 | StoreError 變體分類 |
| `coordinator.rs:798` | `generation.journal_failed` | StoreError Display | 自由文字 | StoreError 變體分類 |
| `coordinator.rs:1516` | `change.commit_write_failed` | StoreError Display | 自由文字 | StoreError 變體分類 |
| `coordinator.rs:1731` | `change.timed_revert_failed` | CoreError.message | 自由文字 | `ErrorName::as_str()` 的 snake_case wire 名稱 |
| `coordinator.rs:2120` | `recovery.read_failed` | StoreError Display | 自由文字 | StoreError 變體分類 |
| `core.rs:163` | `host.lost` | production detach 僅傳兩個固定 literals | 封閉代碼 | `connection_closed/heartbeat_timeout`；呼叫點明確 match，其餘為 `unknown` |
| `core.rs:479` | `lock.start_failed` | io::Error Display | 自由文字 | `io_error_code(error.kind())` 的 snake_case 代碼 |
| `generation.rs:557` | `generation.journal_recovery_failed` | StoreError Display | 自由文字 | StoreError 變體分類 |
| `hosts.rs:276` | `host.start_refused` | io::Error Display | 自由文字 | `io_error_code(error.kind())` 的 snake_case 代碼 |
| `lib.rs:236` | `connection.identity_rejected` | 固定分支 literals | 封閉代碼 | `binding_mismatch/unknown_kind` |
| `main.rs:191` | `compositor.unreachable` | io::Error Display | 自由文字 | `io_error_code(error.kind())` 的 snake_case 代碼 |
| `main.rs:330` | `system.component_unavailable` | RealSystem.problems 的 String，可能來自 D-Bus 錯誤 | 自由文字 | 無型別化原因可取；reason 遮蔽，保留 component |
| `main.rs:351` | `core.store_refused` | StoreError Display | 自由文字 | StoreError 變體分類 |
| `main.rs:396` | `shortcut.command_failed` | CoreError.message | 自由文字 | `ErrorName::as_str()` 的 snake_case wire 名稱 |
| `main.rs:427` | `launch.failed` | io::Error Display | 自由文字 | `io_error_code(error.kind())` 的 snake_case 代碼 |
| `main.rs:454` | `connection.ended` | io::Error Display | 自由文字 | `io_error_code(error.kind())` 的 snake_case 代碼 |
| `outputs.rs:263` | `outputs.rescue_failed` | AdapterError 的含 payload Debug | 自由文字 | 既有 `error_kind` 只 match enum 變體 |
| `outputs.rs:287` | `outputs.window_stranded` | rescue_windows 的 literals／error_kind，不是視窗文字 | 封閉代碼 | `no_geometry/unsupported/not_found/unavailable/readback/internal` |
| `outputs.rs:302` | `outputs.notice_failed` | SystemError 的含 payload Debug | 自由文字 | 呼叫點 match：`unavailable/not_found/invalid/failed` |
| `shell.rs:87` | `shell.start_failed` | io::Error Display | 自由文字 | `io_error_code(error.kind())` 的 snake_case 代碼 |
| `shell.rs:244` | `shell.rescue_ui_failed` | io::Error Display | 自由文字 | `io_error_code(error.kind())` 的 snake_case 代碼 |

合計 **4 個封閉代碼、23 個自由文字**。4 個封閉來源移除原 reason 欄位，改記 reason_code。23 個自由文字中，11 個 StoreError、7 個 io::Error、2 個 CoreError、1 個 AdapterError、1 個 SystemError 共 22 個取得安全分類；只有 RealSystem.problems 沒有型別化原因。每個自由文字的 reason 仍保持 `[redacted]`。

StoreError 分類由 `log::store_error_code` 對 8 個 enum 變體逐一 match：`storage_full/storage_io/store_corrupt/store_locked/not_found/conflict/invalid/sqlite`，不讀取 Display、String 或 SQLite message。`io_error_code` 將 io::ErrorKind 轉為固定 snake_case 代碼，未列舉與未來的種類一律為 `other`；ErrorName 日誌字串由 protocol crate 的 inherent `ErrorName::as_str()` 提供，與 serde wire 名稱一致。compositor connect 已將 adapter 錯誤包成 io::Error::other 的情況只會得到 `other`，不推測原文原因。

`subject_kind` 只輸出 9 個固定類別：`shell/cli/cli_rescue/rescue_ui/agent/lock/core/host/unknown`。Core 的 `subject_for_kind`、host entry 綁定與內部 core proposal 是來源；`hostd`／`host:<entry>` 只記 `host`，未知值只記 `unknown`。這是診斷分類，不是身分驗證或授權入口。issue 初始的「RPC proposal subject 可帶自然語言」假設不符合現有契約；原 RED 證明的是直接 logger 的防禦缺口，不能據此宣稱發生過產品 RPC subject 原文外洩。

`kind` 在身分拒絕事件中只保留 `subject_for_kind` 允許的 `quickshell/dittoctl/dittoctl-rescue/rescue-shell/agent/lock/hostd`，其餘一律記 `unknown`；不記任意 peer 字串。沒有新增 config flag、retention 或 opt-in。

## 回歸與產品覆蓋

- `log::tests::draft_subject_is_redacted_while_change_id_remains_traceable`：私人 subject 含中文；基底 RED 直接印出 `change.draft` JSON 原文，修正後只留 `[redacted]` 與原 `change_id`。
- `log::tests::free_text_errors_and_launch_arguments_never_reach_the_log`：覆蓋 `reason/error/spec`，保留 `operation_id`。
- `log::tests::classified_reason_sites_keep_closed_causes_and_redact_text`：表格逐列覆蓋原 27 個 reason 呼叫，驗證封閉原因保留、私人文字遮蔽、追溯 ID 保留。
- `log::tests::store_error_codes_ignore_all_variant_payloads`：8 個 StoreError 變體，包含 SQLite 私人 payload，只留下固定原因分類。
- `log::tests::subject_categories_are_closed_and_never_expose_identity_payloads`：兩個 proposal 事件、11 個身分輸入組合（含 host entry 與未知私人字串），輸出固定 subject_kind，subject 保持遮蔽。
- `log::tests::code_shaped_reason_text_is_still_content`：看起來像代碼的 reason 仍遮蔽；logger 不會自動推斷或新增 reason_code。
- `driver.test.mjs` 執行正式 `runFlow`，以 catalog 的 input schema 驗證全部 17 種能力參數，包含 proposal／readback；驗證 profile ID、base revision 都來自回讀，並拒絕自填 `subject`、缺少必填參數與錯誤 ops 型別。
- `test_scan.py` 讓私人 proposal 哨兵只存在保存的 readback 時通過，另注入到日誌時由 `default_privacy_scan` 拒絕；這是 runner 退出政策的 fixture 證據。

`desktop.changes.propose` 的合法輸入沒有 `subject`。Core 的 `subject_for_kind`／`origin_for`／router 綁定 subject，CLI 為 `cli`；不新增或偽造身分輸入。產品 driver 的私人哨兵放在 `idempotency_key`，用空 ops 建立 ChangeSet 並以 `desktop.changes.get` 回讀確認保存，覆蓋真正的 `change.draft` 路徑。它不是產品 RPC 注入任意 subject 的證據；任意 subject 的遮蔽由 logger 回歸測試覆蓋。

產品 `run.py` 需 socket，依 runner 合約交 coordinator 在 sandbox 外執行；預期 `flow.ok=true`、`hit_count=0`、`default_privacy_scan.hit_count=0`。本機不宣稱產品掃描已通過。
