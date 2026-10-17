# QA-04：秘密與崩潰內容檢查

對應 SEC-07、REC-06、§16、AT-15；鎖定入口見下方 AT-17。所有哨兵都是測試值，不得把真實憑證傳入這些工具。沒有新依賴或 workflow 修改；coordinator 可將以下指令接入 CI。結果是 development 證據，不裁定階段出口。

## 產品流程入口

使用 common.md 的本機工具鏈，於 repository 根目錄執行：

```sh
cargo build --locked --workspace --bins
corepack pnpm -r --filter @ditto/host-runtime --filter @ditto/agent-runtime build
timeout 120 python3 tests/g4/secrets/run.py --output /tmp/qa04-product-positive
timeout 120 python3 tests/g4/secrets/run.py --inject-leak --output /tmp/qa04-product-negative
```

第一個命令預期 exit 0、`ok=true`、`hit_count=0`；負向控制預期 exit 1、`flow.ok=true` 且 `hits` 指向 `intentional-leak.log`。若 `flow.ok=false`，代表流程根本沒完成，不能當成負向控制成功或外洩掃描通過。輸出目錄必須不存在，避免舊產物污染證據。

`manifest.json` 明列注入值與掃描根目錄；此測試輸入及 `driver.json` 位於 product 之外，不冒充產品輸出。產品產物與原始 log 都保留在 `product/`，`result.json` 列出每個範圍、檔案數、命中數及原始路徑，缺少必要分類或 SQLite 不通過。命中報告不複製秘密值或上下文。

注入流程：三種秘密樣式經正式 `agent.credentials.create` 入口送往**刻意不存在的私有 Secret Service**，檢查失敗封閉且秘密沒有落盤。正式 Agent 使用缺失的 credential reference 執行失敗路徑；會話、設定與 turn 由 Core 保存。generation 呼叫正式 create/get 產生固定模板 bundle；匯出與診斷使用正式能力。沒有將秘密放入使用者對話再要求任意文字自動被辨識為秘密。對話的非秘密私人哨兵另掃日誌、匯出與診斷；產品的會話原始檔則應保留使用者文字。

這條入口不證明成功的 keyring 解析、真模型成功回合、Codex app-server、隔離 native validation／preview、Shell 或實際崩潰捕捉。這些範圍在 `flow.not_run` 明列；需另以 G2 direct／codex 與 G3 integration 流程補驗。runner 關閉自己的 coredump，不改產品 crash 政策。

`scan.py` 可接受同格式 manifest 重掃其他 retained 產物。它讀取所有一般檔案的 bytes（含 SQLite WAL／舊頁）、SQLite 邏輯內容（含 UTF-16）及 `.dittopkg` 的解壓成員；掃 literal、JSON escaping、URL encoding、Base64。這是已知哨兵的外洩偵測，不是任意秘密辨識、磁碟鑑識或任意壓縮／加密格式解碼。符號連結、讀取失敗、壞 SQLite 與不存在的範圍均失敗；socket 沒有持久 bytes，另列為 runtime 限制。

## 不依賴 IPC 的掃描器控制

```sh
python3 -m unittest discover -s tests/g4/secrets -p 'test_*.py' -v
python3 tests/g4/secrets/control.py --output /tmp/qa04-control-positive
python3 tests/g4/secrets/control.py --inject-leak --output /tmp/qa04-control-negative
```

控制預期依序 exit 0、0、1；最後一個的 `hit_count` 必須大於 0。這些只有 scanner fixture，不是全產品通過證據。本 runner 的 Unix socket 被 sandbox 以 `Operation not permitted` 拒絕，產品流程因此 **BLOCKED**；原始結果須與控制結果分開保存。

## 崩潰／診斷路徑盤點與缺口

| 路徑 | 本地可確認範圍 | 結論與待補證據 |
| --- | --- | --- |
| Quickshell 0.3.1／cpptrace | `packaging/systemd/user/ditto-core.service` 的 `--shell`／`--rescue-ui`／`--lock` 啟動規格；`docs/platform/dependency-inventory.md` 釘選 cpptrace | 本地沒有 Quickshell 執行檔、上游 handler source 或 crash 樣本。**未執行**；不能猜測 dump 實際位置或宣稱未包含記憶體內容。VM 須記錄該釘選版本實際產生的報告位置、內容及同意介面。 |
| Core panic | `crates/ditto-core/src/main.rs`、`lib.rs` 未安裝自訂 panic hook；一般日誌遮蔽在 `log.rs`，不涵蓋標準 Rust panic hook | 程序 stderr 由工作階段收集；panic payload 的內容安全尚無保證。OS dump 是另一層（本機 core_pattern 為 apport），不能當成 Core 的遮蔽輸出。實際 panic／OS dump **未執行**。 |
| hostd | `src/main.ts` 的 `describe(error)`、`unhandledRejection`；`src/log.ts` 的 Cordis exporter → HostLog → stderrSink／journald | **已重現缺口**：Error.message 與 stack 未遮蔽私人內容；不是已通過。修正需改 `packages/host-runtime/src/log.ts`，超出本 lane 寫入範圍，交 coordinator 處理。 |
| Core 診斷回應 | `diagnostics.rs::plugins`／`rescue_status`，沒有獨立「診斷壓縮包」或 opt-in 上傳實作 | 回應含插件、依賴、註冊、狀態；`supervisor_note` 讀 audit `redacted_detail`，欄位名不是通用遮蔽器。現有生產 disable reason 為固定代碼（hosts.rs）；未實證此路徑缺口，因此沒有修改 diagnostics.rs。 |
| 範圍可見的選擇加入 | 原始日誌／崩潰內容沒有正式範圍選擇與上傳介面 | **未提供／BLOCKED**；手動複製檔案不是選擇加入機制。不得據此宣稱 §16 全項通過。 |

重現 hostd 真正的 exporter（不啟動宿主、不造成真 crash）：

```sh
node --experimental-transform-types tests/g4/secrets/crash-audit.mjs /tmp/qa04-crash-audit.json
```

目前預期 exit 1，四類私人測試內容命中 4 項。此為 RED 與交接證據；沒有在可寫範圍內找到可完整修補的出口，因此沒有虛構 GREEN。

## AT-17：VM／參考機補跑

在有 verification relay、foot、grim、jq 的**可拋棄 Ditto Wayfire 登入座位**執行，輸出目錄另行保留；兩次各使用新的登入，避免原鎖定 client 被殺後影響後續：

```sh
DITTO_ARTIFACTS=/tmp/qa04-lock-bypass timeout 240 bash tests/g1/lock/bypass.sh
DITTO_ARTIFACTS=/tmp/qa04-lock-original timeout 240 bash tests/g1/lock/run.sh
```

`bypass.sh` 覆蓋 Shell SIGKILL、替換 Dock UI、`upgrade_entry` 插件升版嘗試、啟動正式 rescue service；每次檢查 Core locked、全部像素沒有可見綠色標記。UI／升版必須含 `session_locked` 拒絕且 revision／hash 不變。升版目標刻意未安裝，測的是鎖定拒絕，不宣稱成功升版生命週期已執行。`run.sh` 原情境另殺 lock client 與 Shell。capture 失敗只能標 environment，不能當作黑屏通過。取樣不能排除兩幀之間的閃露，仍須**全程錄影、人工檢查所有螢幕及密碼解鎖**。operator 項目待補時整體 exit 3，不計通過。

本機只執行 `bash -n`、像素 oracle 單元與 Core 缺少 lock/UI 時的鎖定狀態測試；四個合成器情境及密碼錄影均為 **未執行（需 VM／參考機）**。

```sh
python3 -m unittest discover -s tests/g1/lock -p 'test_*.py' -v
cargo test --locked -p ditto-core tests::lock_without_a_client_stays_locked_during_shell_and_rescue_supervision -- --exact
cargo test --locked -p ditto-core tests::rescue_core_does_not_clear_a_requested_lock_when_the_ui_is_missing -- --exact
```

刪除對話的邏輯遮蔽限制沿用 [既有已知限制文件](../../../docs/platform/codex-backend-boundary.md#5-已知限制未宣稱完成)，不建立第二份限制清單。
