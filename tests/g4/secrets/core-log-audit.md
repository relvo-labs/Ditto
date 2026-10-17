# #73：Core 日誌欄位盤點

對應 SEC-07、REC-06、AT-15。基底 `25c0b726ef3c3bc7c8e00232514604cc0498007e`；用以下指令盤點 `crates/` 中全部 58 個呼叫，欄位共 42 種（不含 logger 自動加入的欄位）。沒有 `log::warn/error/info` 呼叫，結果全是 Core 的 `log::event`。

```sh
git grep -n 'log::event\|log::warn\|log::error\|log::info' -- crates/
```

只擴充 `crates/ditto-core/src/log.rs::CONTENT_KEYS`，不新增遮蔽機制、儲存或能力。`coordinator.rs` 的 `change.draft` 呼叫不變，由共用 logger 遮蔽；同時涵蓋 router 的 `change.dropped_before_acceptance`。

| 欄位鍵 | 來源與內容判斷 | 結論 |
| --- | --- | --- |
| `already_visible` | outputs rescue 的數量 | 保留 |
| `app_id` | stranded window 的應用識別，不是視窗標題 | 保留識別 |
| `bytes` | context 的位元組數，未記 context 內容 | 保留 |
| `capability_id` | host 註冊的能力識別 | 保留識別 |
| `change_id` | Core 建立的 ChangeSet 識別 | 保留追溯 |
| `checked` | outputs rescue 檢查數量 | 保留 |
| `command` | shortcut 綁定的 command ID，不是命令參數 | 保留識別 |
| `component` | 啟動時固定的系統元件名稱 | 保留 |
| `compositor` | adapter 的合成器標籤 | 保留 |
| `connection_id` | Core 建立的連線識別 | 保留追溯 |
| `context_id` | Core 建立的 context 識別 | 保留識別 |
| `count` | retention／tool reconciliation 數量 | 保留 |
| `credential_ref` | Secret Service 引用，沒有秘密值 | 保留引用 |
| `decision` | participant sync 的固定結果分類 | 保留 |
| `entry_id` | Core 指派的插件實例識別 | 保留識別 |
| `error` | `jobs.finished` 的 `job.error_key`；jobs_pool 會直接接收 worker JSON 的 `error` 字串，截成 64 字仍可能含私人內容 | **新增遮蔽** |
| `from_rescue_ui` | 布林狀態字串 | 保留 |
| `generation` | host generation 計數 | 保留 |
| `job_id` | Core 建立的 job 識別 | 保留追溯 |
| `kind` | job 類型、連線種類；拒絕 handshake 時也是 peer 提供的種類標籤 | 保留診斷識別；不是文字載荷欄位，不能據此宣稱所有任意識別字均已匿名化 |
| `lease_id` | Core 建立的 lease 識別 | 保留識別 |
| `mode` | `rescue`／`normal` | 保留 |
| `moved` | outputs rescue 搬移數量 | 保留 |
| `note` | `core.development_mode` 的固定提示字串 | 保留 |
| `operation_id` | 尚未接受 proposal 時的操作識別 | 保留追溯 |
| `outcome` | recovery 的狀態分類 | 保留 |
| `outputs` | 合成器提供的輸出接頭識別清單 | 保留識別 |
| `package` | builtin manifest 的 package ID，沒有 description | 保留識別 |
| `path` | builtin 套件目錄／archive 路徑 | 沿用 HOME 路徑遮蔽 |
| `pid` | peer PID | 保留 |
| `point` | fault-injection 的靜態呼叫位置 | 保留 |
| `reason` | 27 個呼叫混用固定代碼、`error.to_string()`、`CoreError.message`、adapter Debug／宿主錯誤；不能當成封閉錯誤集 | **新增遮蔽**，固定代碼也一併遮蔽；事件名與追溯 ID 保留 |
| `role` | participant 的固定角色 | 保留 |
| `rule_id` | region rule 的識別，不是 matcher 或使用者需求文字 | 保留識別 |
| `socket` | Core socket 路徑 | 沿用 HOME 路徑遮蔽 |
| `spec` | `launch.exited/failed` 的完整啟動規格，包含 executable 與任意 args | **新增遮蔽** |
| `status` | OS exit status／wait 的 I/O 錯誤，或 `applied/failed`；沒有 worker stderr／輸出內容 | 保留 |
| `stranded` | outputs rescue 遺留數量 | 保留 |
| `subject` | proposal 的字串欄位；現有 RPC 由 caller 綁定，但 logger 不應依賴所有來源永遠是固定身分 | **新增遮蔽** |
| `unit` | worker 的 systemd unit 名稱 | 保留識別 |
| `url` | 僅 test provider；`agent_backend::parse_test_provider` 嚴格限制 `http://127.0.0.1:<非零 u16>/v1`，沒有 userinfo／query／任意路徑 | 保留 |
| `window_id` | 合成器視窗識別 | 保留識別 |

Logger 自動欄位 `ts`、`event`、`session_id` 分別是時間、程式碼固定事件名、Core session 識別，均保留。既有 `title/summary/body/clipboard/text/content/window_title` 繼續遮蔽。`description/message/prompt` 沒有出現在這批呼叫的欄位鍵；`CoreError.message` 是以 `reason` 鍵送出，已涵蓋。

識別欄位與 HOME 以外的路徑仍屬診斷資料；本次不是任意字串秘密辨識器，也沒有保證呼叫者故意把內容塞進識別字時都會被辨識。未更改 panic hook、audit 儲存與 wire response；它們不屬上述一般日誌呼叫出口。

## 回歸與產品覆蓋

- `log::tests::draft_subject_is_redacted_while_change_id_remains_traceable`：私人 subject 含中文；基底 RED 直接印出 `change.draft` JSON 原文，修正後只留 `[redacted]` 與原 `change_id`。
- `log::tests::free_text_errors_and_launch_arguments_never_reach_the_log`：覆蓋 `reason/error/spec`，保留 `operation_id`。
- `driver.test.mjs` 執行正式 `runFlow`，以 catalog 的 input schema 驗證全部 17 種能力參數，包含 proposal／readback；驗證 profile ID、base revision 都來自回讀，並拒絕自填 `subject`、缺少必填參數與錯誤 ops 型別。
- `test_scan.py` 讓私人 proposal 哨兵只存在保存的 readback 時通過，另注入到日誌時由 `default_privacy_scan` 拒絕；這是 runner 退出政策的 fixture 證據。

`desktop.changes.propose` 的合法輸入沒有 `subject`。Core 的 `subject_for_kind`／`origin_for`／router 綁定 subject，CLI 為 `cli`；不新增或偽造身分輸入。產品 driver 的私人哨兵放在 `idempotency_key`，用空 ops 建立 ChangeSet 並以 `desktop.changes.get` 回讀確認保存，覆蓋真正的 `change.draft` 路徑。它不是產品 RPC 注入任意 subject 的證據；任意 subject 的遮蔽由 logger 回歸測試覆蓋。

產品 `run.py` 需 socket，依 runner 合約交 coordinator 在 sandbox 外執行；預期 `flow.ok=true`、`hit_count=0`、`default_privacy_scan.hit_count=0`。本機不宣稱產品掃描已通過。
