# G1 驗證腳本（平台負責的門檻）

VM 非圖形開發回歸可用 `bash tools/dev-vm/run-g1.sh` 一次執行，或把 suite 名稱列在指令後。它會保存每項 log、原始 JSON 與 `vm-test-status.png`；用法與證據界線見 [開發 VM](../../tools/dev-vm/README.md)。完整 suite 遇到真機、Shell 或人工項目會如實回 `incomplete`，不能把其餘子檢查通過當作整項出口通過。

每個腳本都寫出一份 `artifacts/g1/<name>-<run_id>.json`（`run_id` 格式同 G0：`<UTC 時間>-<commit 前 3 碼>`），旁邊附平台指紋 `…fingerprint.json`，必要時再附原始回讀目錄 `…d/`。文件逐項列出子檢查，每項的狀態是下列之一：

| 狀態 | 意思 |
| --- | --- |
| `pass` | 已執行，回讀的實際狀態符合判準 |
| `fail` | 已執行，不符合 |
| `not_implemented` | 所需的 Core／Shell／hostd 功能還不存在；腳本偵測到並停在這裡，不假裝執行 |
| `environment` | 這個環境跑不了（沒有登入的 Ditto 工作階段、沒有第二螢幕、不是參考機…） |
| `operator` | 需要人（實體拔插、輸入密碼、錄影），尚待完成 |

整份文件只有在**每一項都是 `pass`** 時才是 `pass`；沒有任何子檢查的結果永遠不是 `pass`。結束碼：`0` 通過、`1` 失敗、`3` 其他（未完成、未實作、環境不足）。不在參考機上（未設 `DITTO_REFERENCE_MACHINE=1` 並通過 `packaging/reference-image/preflight.sh`）的結果一律標為開發證據，不進出口評審。

| 腳本 | 門檻 | 在哪裡能判定 |
| --- | --- | --- |
| `rescue-supervision/run.sh` | EX1-12 ①②③ | 登入的「Ditto (Wayfire)」工作階段。其他環境改跑 headless 夾具，只量 supervisor 從 `SIGSTOP` 到終止 Shell 的時間（開發證據，不含救援介面）。③ 會真的終止 Core，需另設 `DITTO_ALLOW_CORE_STORM=1` |
| `lock/run.sh` | EX1-12 ④⑤ | 登入的 Ditto 工作階段。合成器本身的行為是差異表 C-19（`tools/compositor-probe/g1`，headless 開發證據）；以密碼解鎖與錄影由操作者完成 |
| `output-hotplug/run.sh --automated` | EX1-13 ⑤ | 接第二螢幕的登入工作階段，以 `wlr-randr --off` 停用第二輸出。沒有工作階段時跑 headless 替代版：以 Wayfire IPC 建立再刪除一個 headless 輸出（C-18） |
| `output-hotplug/run.sh --physical` | EX1-13 ⑤ | 同上，由腳本引導操作者實際拔線。plan/03/05 §7 要求兩個變體都通過 |
| `rescue-no-node/run.sh` | EX1-05 | 隔離的 headless 夾具；救援 Core 以 `--mode rescue --development` 啟動，⑥ 另以受控的正常模式 Core／hostd 驗證；④ 的 Shell 文字仍需登入工作階段 |
| `preflight-negative/run.sh` | EX1-02 | ①②③ 由 Rust 契約測試判定（也在 `rust.yml` 阻擋合併），另以真實 `ditto-core` 對內建套件能表達的負例（缺套件、單一供應者衝突）回讀 head、內容雜湊與已存變更；④ 的產品文字由人在參考機的插件中心確認（`operator`） |
| `rollback/run.sh` | EX1-03 | Rust 情境測試；另寫 `rollback-<run_id>.jsonl`，每個情境一行結果類別。③ 由合成器參與者負責：切換布局策略時記下切換前的視窗位置（工作階段狀態，只在記憶體，不進 Profile），撤銷時放回；已關閉的視窗列為 `not_restored`、原因 `window_closed`，變更仍提交但結果為 `partial`。Core 重啟後的撤銷沒有位置可放回，也不會列出視窗 |
| `persistence-faults/run.sh` | EX1-09 | `fault-injection` build 的真實二進位（`crates/ditto-core/tests/persistence_faults.rs`）。真正寫滿的檔案系統需要 root 先掛好：設 `DITTO_G1_SMALL_FS=<已掛載、可寫的小 tmpfs>`，否則該項記為 `environment` |
| `contract-vectors/run.sh` | EX1-06 | Rust 與 TS 兩側共享向量、0.1 拒絕、缺口重訂、`operation_id` 重連、`on_behalf_of` 偽造、目錄 gate；加上 Agent 替身的身分路徑（經啟動器以 `agent` 受理；同一程式拿偽造 token 被 Core 拒絕） |
| `cordis-independent/run.sh` | EX1-07 | headless 桌面夾具（`lib/shell-fixture.sh`）：Wayfire 與夾具自己的工作階段匯流排，正常模式 Core 監督的真實 Shell、hostd、Agent 替身與回讀 relay；Core 以 `DITTO_SYSTEM=no-logind` 在夾具的匯流排上擁有通知伺服器。① 面板內容取自 Shell 的 `tasks` 控制行，2 秒以用戶端單調時鐘量「檔案寫入 → 面板顯示」（每 20 ms 輪詢，QML 面板沒有 Core 時間戳）；通知以 `gdbus` 送出，決定經 Core 讀回（規則：專注模式、允許清單為空；緊急通知是對照）。② Shell 不在時（socket 拒絕且 Core 回報無 Shell 連線）改檔並送通知，重啟後的面板內容與策略紀錄經回讀判定。③ hostd PID 三個時點相同 |
| `cleanup-stress/run.sh` | EX1-04 | 夾具中 ② tasks 服務停用／啟用真的跑 100 次，每 10 次以 `desktop.plugins.diagnostics` 取快照，`judge.py` 比對首尾計數、PSS 中位數增幅與 Mann-Kendall。① 需要 Shell，③ 需要 HOST 的 realm 夾具 |
| `latency/run.sh` | EX1-11 | 兩個夾具。② 另列的 Cordis 服務數字：fixture 合成器＋hostd，`change_updated` 的 `updated_at`。①②③：headless 桌面夾具（真實 Shell、hostd、foot 與 Kate；參考機另加 Firefox），由 Core 啟動的 driver 執行。① 工作區與聚焦取 Core 回應的 `_meta.handled_us`（Core 單調時鐘，從讀到請求到回讀確認後寫出結果）；外觀 token 是 ChangeSet，取 `created_at` 到最後一次 readback 操作的 `ended_at`（皆為 Core 寫入，毫秒）；每種先暖機 5 次，保留但不判定。② 取 `prepared`／`committed` 的 `updated_at`，每次切換後另以 `desktop.panels.list` 確認 Shell 掛上對的 Dock。③ 合成器對應的 PID 每 0.5 秒檢查，Kate 未儲存緩衝雜湊前後比對。driver 的往返時間只並列參考。樣本寫到 `latency-<run_id>.jsonl` |

## 共用函式（`lib/common.sh`）

沿用 `tests/g0/lib/session.sh` 的 headless 合成器、開發模式 Core、`run_id` 與環境標籤，另加：

- `g1_capabilities`：以 `dittoctl --json probe capabilities` 列出 Core 目前提供且可用的能力。所需能力缺席或不可用時，子檢查記為 `not_implemented`，並寫出缺少哪些 `capability_id`。
- `g1_call`：一般能力呼叫。G0 的 `dittoctl` 只有固定的 probe 子命令，這些腳本需要 **`dittoctl probe call <capability_id> <params-json>`**（以 `--json` 印出與其他 probe 子命令相同格式的紀錄）。它不存在時，所有需要呼叫能力的步驟都是 `not_implemented`。
- `screen_fraction`：以 `grim` 截圖並計算某個顏色占畫面的比例，用來判斷鎖定時是否露出桌面。
- `g1_cargo`／`g1_run`：把一個 Rust 測試（或任一測試命令）記成一項子檢查，完整輸出存到 `<name>-<run_id>.d/`；篩選沒有跑到任何測試時是 `fail`，不是 `pass`。
- `g1_fixture_core`／`g1_fixture_stop`／`g1_head`：開發模式 Core（fixture 合成器、自己的 runtime 與 store，路徑夠短以符合 `sun_path`）；`g1_head` 回 head revision 與內容雜湊。

### 有真實 Shell 的 headless 桌面（`lib/shell-fixture.sh`）

`manual-switch` 的夾具抽成共用：`start_compositor` 之後以 `shell_fixture_start [--hostd] [serve 參數…]` 啟動正常模式 Core、受 Core 監督的 Shell、（選用）hostd 與回讀 relay；`relay` 經 relay 呼叫 Core，`shell_line` 寫一行到 Shell 的控制 socket，`core_child` 找 Core 底下的程序，`fixture_reference_apps` 起參考應用，`shell_fixture_stop` 收掉一切並刪除 runtime 目錄。Core 以 `DITTO_SYSTEM=no-logind` 執行：通知伺服器是真的、在夾具自己的匯流排上，logind 不連，所以不碰旁邊的登入工作階段。

### 由 Core 啟動的驗證 driver

帶 hostd 或 Agent 替身的夾具必須以非開發模式啟動 Core（開發模式的共用 token 不能與受控啟動的客戶端並用），所以外面的 `dittoctl` 連不上。這些腳本改讓 Core 以 `--launch "dittoctl 0.2.0 <node> <driver.mjs> …"` 啟動一支觀察用 driver（`lib/core-client.mjs`），它只呼叫能力並記錄；**終止程序一律由 `run.sh` 在外面做**，兩邊以工作目錄中的檔案交接。

Agent 替身（`fixtures/agent-standin/standin.mjs`，G1-QA-07）不含任何模型或模型 SDK，只做三件事：訂閱 tasks 事件、送出 ChangeSet、以 `operation_id` 查詢結果（外加 `hold`，連上後等著被終止）。報告中一律稱「Agent 替身」。

## 各工作流要提供什麼，腳本才能往下跑

| 誰 | 什麼 | 用在 |
| --- | --- | --- |
| Shell | `shell.sock` 上的 `ping <n>` → `pong <n>`（格式見 [crates/ditto-supervisor/README.md](../../crates/ditto-supervisor/README.md)） | rescue-supervision ① |
| Shell | 救援介面 `shell/rescue/shell.qml`，表面可操作時在 stdout 印一行 `ditto-rescue ready` | rescue-supervision ① 的計時終點 |
| Shell | 鎖定客戶端 `shell/lock/shell.qml`，由 Core 以 `--lock` 啟動，scope 為 `ditto-lock.scope` | lock ④ |
| Core／dittoctl | `dittoctl probe call`；`dittoctl rescue restart shell`；`dittoctl --offline rescue restore-last-good` | lock、rescue-supervision ①③、rescue-no-node ②③ |
| Core | 熱插拔後把視窗移回剩餘輸出的可見範圍（plan/03/05 §7）；角色位置的回讀 | output-hotplug |
| HOST | 會連續崩潰的測試插件 `tests/g1/fixtures/crashing-plugin` | rescue-supervision ② |

## 開發機上的第一次執行（2026-09-27，headless，開發證據）

- `rescue-no-node`：Core 以 `--mode rescue` 啟動，原生視窗的聚焦、移動（回讀一致）與關閉請求成功；所有依賴 hostd 的能力都標為不可用且原因是 `rescue_mode`；Ditto 啟動的程序中沒有 Node。歷史讀取與恢復最近可用配置因缺少 `dittoctl probe call` 而未執行。
- `output-hotplug`（headless 替代版）：以 `configure-view` 的 `output_id` 把 foot 視窗移到 IPC 建立的第二輸出，再刪除該輸出；Core 回讀視窗回到 `HEADLESS-1` 的目前工作區（100,100），與 C-18 一致，所以 `windows-visible` 是 `pass`。這個 `pass` 只說明 Wayfire 自己搬了視窗、且 Core 的回讀看得到，不代表 Ditto 做了任何搬移。角色位置沒有回讀，記為 `not_implemented`。
- 同一次執行暴露一個回讀限制：`desktop.windows.list` 的 x／y 是視窗所在輸出、相對於其目前工作區的座標，而且不帶輸出名稱；`desktop.outputs.list` 的 x／y 卻是全域排列中的位置。兩者不能直接比較，所以 `visible.py` 只在剩一個輸出時判定，否則把視窗列為 `unmapped`。多輸出時要判定，Core 的視窗回讀需要帶上所在輸出。
- `rescue-supervision`（夾具）：目前的 Shell 不回 `ping`，所以 supervisor 不武裝，記為 `not_implemented`。以加上 `ping` 分支的 Quickshell 0.3.1 另測，`SIGSTOP` 後約 6.6 秒被終止。
- `lock`：此環境沒有登入的 Ditto 工作階段，三項都未判定。

## Core／QA 腳本的第一次執行（2026-09-27，開發機，fixture 合成器，開發證據）

工作樹未提交，所以這些結果依 plan/03/06 §11 不能當出口證據，只用來確認腳本與被測路徑本身成立。

- `persistence-faults`：①②③④ 的真實二進位測試通過；真正寫滿的檔案系統因沒有 root 掛載而記為 `environment`。同一次執行暴露並修掉兩個測試本身的問題：`ditto-store` 的離線救援測試會因其他測試執行緒 spawn `tar` 時繼承鎖的描述元而偶發 `Locked`（只影響測試：Core 整個生命期都持有鎖），以及斷言失敗時 fault 測試會留下孤兒 Core（改為 drop 時終止）。
- `preflight-negative`：Rust 的六個負例與雜湊不符通過；真實二進位上的缺套件與單一供應者衝突在 `validated` 之前被拒、存為 `rejected`、head 與內容雜湊不變。④ 待人工。
- `rollback`：①② 與 ③ 的機制通過；③ 的原情境記為 `not_implemented`（見上表）。
- `contract-vectors`：11 項全部通過，包含 Agent 替身經啟動器以 `agent` 受理、偽造 token 被 Core 以 `identity_rejected` 拒絕。
- `cordis-independent`：以 `SIGKILL` 終止 Agent 替身後，外部改寫 todo.txt 的 tasks 事件在 51 ms 內到達、`desktop.tasks.list` 列出新行；hostd PID 不變。
- `latency`：Cordis 服務（tasks 停用／啟用各 100 次）`prepared`→`committed` p95 為 9／8 ms。
- `cleanup-stress` ②：**未通過。** 100 次（另試 400 次）停用／啟用後，Core 與 hostd 的所有計數首尾完全相同，但 hostd PSS 由約 41 MB 升到 52 MB（400 次時 65 MB，中途一次回落到 36 MB），中位數增幅 13.7%，Mann-Kendall p=0.012。同期 hostd 回報的 JS heap 穩定在約 12 MB、external 2.1 MB，所以增長在 JS heap 之外（模組／realm 的程式碼與原生配置是候選）。依原則 5 不調整門檻；交 HOST 查明，查明前 EX1-04 ② 記為未通過。

## 救援夾具更新（2026-09-27，開發證據）

`rescue-no-node/run.sh` 先前只隔離 socket，沒有指定專用 `DITTO_DATA_DIR`，因此在本機曾開啟預設 Ditto store。三次舊執行不作出口證據；沒有執行資料回滾。現在使用專用暫存 store 並在結束後清理。`artifacts/g1/rescue-no-node-2026-09-27T13:05:42Z-effb.json` 的隔離重跑：啟動、原生視窗操作、歷史讀取、恢復受保護文件（head 與雜湊回讀）、Cordis 能力標為 `rescue_mode`、無 Ditto Node 程序、正常模式重建 tasks 並讀回救援前的待辦，七項通過。Shell 產品文字仍需登入工作階段，因此 EX1-05 仍未通過。

## EX1-11 與 EX1-07 移到有真實 Shell 的 headless 桌面（2026-10-04，開發機，開發證據）

環境：開發機的 headless Wayfire（pixman、Qt 軟體繪製）、debug build、參考應用只有 foot 與 Kate（Firefox 只在參考機跑）。不是參考機，數字只說明腳本與被測路徑成立，不進出口評審。以下是 `8ea29d8`（工作樹乾淨）上各三次的結果。

- `latency` ①：200 次（工作區 66、聚焦 67、外觀 token 67，另各暖機 5 次不判定）受理到回讀完成 p95 為 10／12／12 ms，最大 12～15 ms。分項 p95：工作區約 2.2 ms、聚焦約 3.2 ms（`_meta.handled_us`），外觀 token 11～13 ms（`created_at` 到最後一次 readback 的 `ended_at`，毫秒解析度）。UI 首幀時間沒有記錄。
- `latency` ②：Dock A↔B 100 次 `prepared`→`committed` p95 為 11／12／10 ms，最大 13 ms，每次切換後 Shell 都掛上了對的 Dock。另列的 Cordis 服務替換 p95 為 7～10 ms。plan/03/06 §6 另要求的啟動器替換 30 次還沒做。
- `latency` ③：300 次操作期間 foot 與 Kate 的 PID 不變，Kate 未儲存緩衝雜湊相同。
- `cordis-independent`：以 `SIGKILL` 終止 Agent 替身後，外部寫入 todo.txt 到 QML 面板顯示 63～64 ms（含 svc-tasks 的 50 ms 去抖；用戶端時鐘、20 ms 輪詢）；專注模式在終止前後都靜默一般通知、顯示緊急通知，決定都在策略紀錄裡、沒有退回顯示；Shell 被終止期間的檔案變更與通知，在重啟後的面板與策略紀錄都讀得到；hostd PID 三個時點相同。

這兩支腳本跑出四個產品缺陷，都已修正，沒有放寬任何判準：

1. 第一次完整的 `latency` 執行中，Wayfire 以「Error sending json to client!」切斷 Core 的事件連線：Core 每收到一個事件就在讀取執行緒上重讀整份快照，連續操作時 socket 塞滿。72 次聚焦（含 5 次暖機）裡 34 次回 `unavailable`，所有訂閱者被要求重新同步，Dock 的時間戳也因此遺失。事件流改在自己的執行緒讀取，一次重讀涵蓋已收到的全部變更（`session::tests::the_event_stream_is_drained_while_a_re_read_waits`，舊實作會失敗）。
2. svc-tasks 換設定（例如授權 todo.txt）後重新啟動，卻沒有通知訂閱者，所以 QML 面板要等檔案下次被改才會更新。現在新實例成為使用中的實例時送一次 `tasks/changed`（`why: started`）。
3. 以 `--launch` 啟動的客戶端結束後沒有被回收，變成殭屍程序，`kill -0` 仍然成功。Core 現在會回收它，並記一行 `launch.exited`。
4. 測試本身的問題：回讀 relay 與 Agent 替身的 `hold` 模式在 Core 結束後仍然留著。現在它們會跟著 Core 結束；headless 夾具的 runtime 目錄也會清掉。

還沒成立的：參考機上的執行（含 Firefox、release build）；EX1-11 的 UI 首幀參考值與啟動器替換 30 次；EX1-07 的面板時間是用戶端時鐘，QML 面板沒有 Core 時間戳可用。
