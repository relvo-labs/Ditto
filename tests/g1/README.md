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
| `manual-switch/run.sh` | EX1-01 | headless 桌面夾具：正常模式 Core 監督的真實 Shell、回讀 relay、foot 與 Kate（參考機另加 Firefox）。七步全部以合成按鍵經 Wayfire 操作組合中心與個人化設定（`lib/gui.py`：以無障礙名稱 Tab 到控制項、Enter／空白鍵、Ctrl+V 貼上中文名稱），每一步經 relay 回讀 Core（變更狀態、Profile 綁定、Shell 掛載、合成器的布局策略），每步一行寫入 `manual-switch-<run_id>.jsonl`；另檢查快捷鍵與命令沒有重複擁有者、參考應用未終止、Kate 未儲存緩衝雜湊不變。設定視窗以 Shell 控制 socket 的 `command composition.open` 開啟（與面板選單同一個 Shell 命令）。非實作者的人工錄影永遠是 `operator`；nightly 以 `DITTO_G1_PENDING_OK=operator` 只讓結束碼放行這一項，文件仍記 `incomplete` |
| `rescue-supervision/run.sh` | EX1-12 ①②③ | 登入的「Ditto (Wayfire)」工作階段。其他環境改跑 headless 夾具，只量 supervisor 從 `SIGSTOP` 到終止 Shell 的時間（開發證據，不含救援介面）。③ 會真的終止 Core，需另設 `DITTO_ALLOW_CORE_STORM=1` |
| `lock/run.sh` | EX1-12 ④⑤ | 登入的 Ditto 工作階段。合成器本身的行為是差異表 C-19（`tools/compositor-probe/g1`，headless 開發證據）；以密碼解鎖與錄影由操作者完成 |
| `output-hotplug/run.sh --automated` | EX1-13 ⑤ | 接第二螢幕的登入工作階段，以 `wlr-randr --off` 停用第二輸出。沒有工作階段時跑 headless 替代版：以 Wayfire IPC 建立再刪除一個 headless 輸出（C-18），並在旁邊啟動 Shell。兩者都先以 ChangeSet 把角色放到第二輸出（工作階段中結束時撤銷），再判定 `windows-visible`（Core 的視窗回讀，每個視窗帶所在輸出）與 `avatar-visible`（Shell 經 `desktop.panels.list` 回報的角色位置） |
| `output-hotplug/run.sh --physical` | EX1-13 ⑤ | 同上，由腳本引導操作者實際拔線。plan/03/05 §7 要求兩個變體都通過 |
| `rescue-no-node/run.sh` | EX1-05 | 隔離的 headless 夾具；救援 Core 以 `--mode rescue --development` 啟動，⑥ 另以受控的正常模式 Core／hostd 驗證；④ 的 Shell 文字由 `shell-text.sh` 在另一個 headless 桌面（`--mode rescue` 的 Core 監督真實 Shell、沒有 hostd）讀 Shell 控制 socket 的 `services` 行：待辦面板與通知區實際顯示的不可用文字 |
| `preflight-negative/run.sh` | EX1-02 | ①②③ 由 Rust 契約測試判定（也在 `rust.yml` 阻擋合併），另以真實 `ditto-core` 對內建套件能表達的負例（缺套件、單一供應者衝突）回讀 head、內容雜湊與已存變更；④ 的產品文字由人在參考機的插件中心確認（`operator`） |
| `rollback/run.sh` | EX1-03 | Rust 情境測試；另寫 `rollback-<run_id>.jsonl`，每個情境一行結果類別。③ 由合成器參與者負責：切換布局策略時記下切換前的視窗位置（工作階段狀態，只在記憶體，不進 Profile），撤銷時放回；已關閉的視窗列為 `not_restored`、原因 `window_closed`，變更仍提交但結果為 `partial`。Core 重啟後的撤銷沒有位置可放回，也不會列出視窗 |
| `persistence-faults/run.sh` | EX1-09 | `fault-injection` build 的真實二進位（`crates/ditto-core/tests/persistence_faults.rs`）。真正寫滿的檔案系統需要 root 先掛好：設 `DITTO_G1_SMALL_FS=<已掛載、可寫的小 tmpfs>`，否則該項記為 `environment` |
| `lifecycle/run.sh` | EX1-08 | L-01～L-04、L-08 為 Vitest（`packages/host-runtime/tests/lifecycle/`，每個檔案至少要跑到正例與負例兩項、不得有略過），L-02／L-03 另有 Rust 單元測試的一半；L-05～L-07、L-09、L-10 為 `fault-injection` build 的真實二進位（`crates/ditto-core/tests/lifecycle.rs`）：正常模式 Core（fixture 合成器）＋ Core 監督的真 hostd（故障注入 bundle，腳本每次重建）＋內建 tasks 服務，L-10 加 Agent 替身，全部由 Core 的啟動器啟動；測試經 `lib/bridge.mjs` 與 Core 對話。量到的數字寫在結果的 `notes` |
| `contract-vectors/run.sh` | EX1-06 | Rust 與 TS 兩側共享向量、0.1 拒絕、缺口重訂、`operation_id` 重連、`on_behalf_of` 偽造、目錄 gate；加上 Agent 替身的身分路徑（經啟動器以 `agent` 受理；同一程式拿偽造 token 被 Core 拒絕） |
| `cordis-independent/run.sh` | EX1-07 | headless 桌面夾具（`lib/shell-fixture.sh`）：Wayfire 與夾具自己的工作階段匯流排，正常模式 Core 監督的真實 Shell、hostd、Agent 替身與回讀 relay；Core 以 `DITTO_SYSTEM=no-logind` 在夾具的匯流排上擁有通知伺服器。① 面板內容取自 Shell 的 `tasks` 控制行，2 秒以用戶端單調時鐘量「檔案寫入 → 面板顯示」（每 20 ms 輪詢，QML 面板沒有 Core 時間戳）；通知以 `gdbus` 送出，決定經 Core 讀回（規則：專注模式、允許清單為空；緊急通知是對照）。② Shell 不在時（socket 拒絕且 Core 回報無 Shell 連線）改檔並送通知，重啟後的面板內容與策略紀錄經回讀判定。③ hostd PID 三個時點相同 |
| `cleanup-stress/run.sh` | EX1-04 | ② tasks 服務停用／啟用與 ③ realm 往返（`packages/plugin-fixtures/stress/realm_cycle`）各在一組新的 Core 與 hostd 上真的跑 100 次；① Dock A／B 往返在 headless 桌面夾具（真實 Shell、回讀 relay）上跑 100 次（`dock_cycle.py`：先加入膠囊 Dock，之後每次以一筆 `bind_slot` ChangeSet 換綁並等 Shell 回報掛載）。每 10 次取快照：Core 的綁定／租約／訂閱、hostd 的 fiber／effect／註冊、Shell 已掛載的供應者數；`judge.py` 比對首尾計數、PSS 中位數增幅與 Mann-Kendall（② ③ 判 hostd，① 以 `--process shell` 判 Shell 的 PSS 與 PID） |
| `latency/run.sh` | EX1-11 | 兩個夾具。② 另列的 Cordis 服務數字：fixture 合成器＋hostd，`change_updated` 的 `updated_at`。①②③：headless 桌面夾具（真實 Shell、hostd、foot 與 Kate；參考機另加 Firefox），由 Core 啟動的 driver 執行。① 工作區與聚焦取 Core 回應的 `_meta.handled_us`（Core 單調時鐘，從讀到請求到回讀確認後寫出結果）；外觀 token 是 ChangeSet，取 `created_at` 到最後一次 readback 操作的 `ended_at`（皆為 Core 寫入，毫秒）；每種先暖機 5 次，保留但不判定。② 取 `prepared`／`committed` 的 `updated_at`，每次切換後另以 `desktop.panels.list` 確認 Shell 掛上對的 Dock。③ 合成器對應的 PID 每 0.5 秒檢查，Kate 未儲存緩衝雜湊前後比對。driver 的往返時間只並列參考。樣本寫到 `latency-<run_id>.jsonl` |
| `measure/cold-login.sh`、`measure/series.sh` | EX1-10 | 參考機上以登入管理器登入的「Ditto (Wayfire)」，每次 run 一次登入：`prepare <狀態>` 寫 `measure-conditions.json`，重新登入後 `sample <狀態>` 檢查實際狀態（Core 模式、Shell 的角色變數、Ditto 單元中的 Node 程序、Profile 中沒有 D-34 插件）、開參考應用、暖機 300 秒、採樣 600 秒，三次不同登入後 `report <狀態>`。`series.sh` 在開啟自動登入的機器上把 prepare → `ditto-relogin` → 等新登入 → sample → report 串起來，可中斷續跑。需要 `install-session.sh --verification-relay`。`measure/dry-run.sh` 是 headless 夾具上的短時試跑、`measure/test-series.sh` 以替身測 `series.sh`，兩者都只是開發證據 |

## 共用函式（`lib/common.sh`）

沿用 `tests/g0/lib/session.sh` 的 headless 合成器、開發模式 Core、`run_id` 與環境標籤，另加：

- `g1_capabilities`：以 `dittoctl --json probe capabilities` 列出 Core 目前提供且可用的能力。所需能力缺席或不可用時，子檢查記為 `not_implemented`，並寫出缺少哪些 `capability_id`。
- `g1_call`：一般能力呼叫。G0 的 `dittoctl` 只有固定的 probe 子命令，這些腳本需要 **`dittoctl probe call <capability_id> <params-json>`**（以 `--json` 印出與其他 probe 子命令相同格式的紀錄）。它不存在時，所有需要呼叫能力的步驟都是 `not_implemented`。
- `screen_fraction`：以 `grim` 截圖並計算某個顏色占畫面的比例，用來判斷鎖定時是否露出桌面。
- `g1_cargo`／`g1_run`：把一個 Rust 測試（或任一測試命令）記成一項子檢查，完整輸出存到 `<name>-<run_id>.d/`；篩選沒有跑到任何測試時是 `fail`，不是 `pass`。
- `g1_fixture_core`／`g1_fixture_stop`／`g1_head`：開發模式 Core（fixture 合成器、自己的 runtime 與 store，路徑夠短以符合 `sun_path`）；`g1_head` 回 head revision 與內容雜湊。
- `g1_hostd_spec <node> <bundle>`：Core 的 `--hostd` 啟動規格，帶上 systemd unit 同一份 Node 旗標（`packages/host-runtime/hostd.node-flags`），讓腳本量到的是實際出貨的 hostd。

### 有真實 Shell 的 headless 桌面（`lib/shell-fixture.sh`）

`manual-switch` 的夾具抽成共用：`start_compositor` 之後以 `shell_fixture_start [--hostd] [serve 參數…]` 啟動正常模式 Core、受 Core 監督的 Shell、（選用）hostd 與回讀 relay；`relay` 經 relay 呼叫 Core，`shell_line` 寫一行到 Shell 的控制 socket，`core_child` 找 Core 底下的程序，`fixture_reference_apps` 起參考應用，`shell_fixture_stop` 收掉一切並刪除 runtime 目錄。Core 以 `DITTO_SYSTEM=no-logind` 執行：通知伺服器是真的、在夾具自己的匯流排上，logind 不連，所以不碰旁邊的登入工作階段。

### 由 Core 啟動的驗證 driver

帶 hostd 或 Agent 替身的夾具必須以非開發模式啟動 Core（開發模式的共用 token 不能與受控啟動的客戶端並用），所以外面的 `dittoctl` 連不上。這些腳本改讓 Core 以 `--launch "dittoctl 0.2.0 <node> <driver.mjs> …"` 啟動一支觀察用 driver（`lib/core-client.mjs`），它只呼叫能力並記錄；**終止程序一律由 `run.sh` 在外面做**，兩邊以工作目錄中的檔案交接。

Agent 替身（`fixtures/agent-standin/standin.mjs`，G1-QA-07）不含任何模型或模型 SDK，只做三件事：訂閱 tasks 事件、送出 ChangeSet、以 `operation_id` 查詢結果（外加 `hold`，連上後等著被終止）。`--gate <檔案>` 讓它啟動後先連上（啟動器的 token 只有 30 秒效期），等檔案出現才執行指令；`--out <檔案>` 另把每一行輸出寫進檔案。報告中一律稱「Agent 替身」。

Rust 整合測試不能自己連上正常模式的 Core，所以由 Core 以 `--launch "dittoctl 0.2.0 <node> lib/bridge.mjs <socket>"` 啟動一支轉接程式：它用自己的啟動器 token 完成握手，再把測試連到 `<socket>` 的位元組原樣轉給 Core。它不判斷任何事，身分仍是 Core 綁定給這個程序的 `cli`。

## 各工作流要提供什麼，腳本才能往下跑

| 誰 | 什麼 | 用在 |
| --- | --- | --- |
| Shell | `shell.sock` 上的 `ping <n>` → `pong <n>`（格式見 [crates/ditto-supervisor/README.md](../../crates/ditto-supervisor/README.md)） | rescue-supervision ① |
| Shell | 救援介面 `shell/rescue/shell.qml`，表面可操作時在 stdout 印一行 `ditto-rescue ready` | rescue-supervision ① 的計時終點 |
| Shell | 鎖定客戶端 `shell/lock/shell.qml`，由 Core 以 `--lock` 啟動，scope 為 `ditto-lock.scope` | lock ④ |
| Core／dittoctl | `dittoctl probe call`；`dittoctl rescue restart shell`；`dittoctl --offline rescue restore-last-good` | lock、rescue-supervision ①③、rescue-no-node ②③ |
| Core | 熱插拔後把視窗移回剩餘輸出的可見範圍（plan/03/05 §7）；角色位置的回讀（2026-10-04 已提供，見下方紀錄） | output-hotplug |
| HOST | 會連續崩潰的測試插件 `tests/g1/fixtures/crashing-plugin` | rescue-supervision ② |
| Core＋Shell | 能同時掛上多個 QML 狀態項的位置：D-34 的五個 QML 插件宣告 `ui.status_item`，但 Profile 的 slot 一次只綁一個 entry，Core 不認得 `ui.status_item`，Shell 也只掛綁在 slot 上的 QML，所以沒有 slot 的 entry 不會被載入（2026-10-05 夾具中 `shell_mounted_providers` 啟用前後不變） | measure 的 `desktop_full_plus10`：在此之前 A/B 報告不對 ≤50 MiB 判定 |

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
- `cleanup-stress` ②：**未通過。** 100 次（另試 400 次）停用／啟用後，Core 與 hostd 的所有計數首尾完全相同，但 hostd PSS 由約 41 MB 升到 52 MB（400 次時 65 MB，中途一次回落到 36 MB），中位數增幅 13.7%，Mann-Kendall p=0.012。同期 hostd 回報的 JS heap 穩定在約 12 MB、external 2.1 MB，所以增長在 JS heap 之外（模組／realm 的程式碼與原生配置是候選）。依原則 5 不調整門檻；交 HOST 查明，查明前 EX1-04 ② 記為未通過。（2026-10-04 已查明，「JS heap 之外」的判斷有誤，見文末一節。）

## 救援夾具更新（2026-09-27，開發證據）

`rescue-no-node/run.sh` 先前只隔離 socket，沒有指定專用 `DITTO_DATA_DIR`，因此在本機曾開啟預設 Ditto store。三次舊執行不作出口證據；沒有執行資料回滾。現在使用專用暫存 store 並在結束後清理。`artifacts/g1/rescue-no-node-2026-09-27T13:05:42Z-effb.json` 的隔離重跑：啟動、原生視窗操作、歷史讀取、恢復受保護文件（head 與雜湊回讀）、Cordis 能力標為 `rescue_mode`、無 Ditto Node 程序、正常模式重建 tasks 並讀回救援前的待辦，七項通過。Shell 產品文字仍需登入工作階段，因此 EX1-05 仍未通過。

## EX1-04 hostd PSS 成長查明與修正（2026-10-04，開發機，fixture 合成器，開發證據）

本節的數字都來自開發機上的 fixture 夾具（未經參考機 preflight，表中八次執行時工作樹尚未提交），只是開發證據，不是出口證據；EX1-04 仍要在參考機的工作階段判定，① 與 Shell PSS 也還沒有數字。

**原因。** 不是洩漏，也不在 JS heap 之外。9 月 27 日引用的「JS heap 約 12 MB」是 `heapUsed`（存活物件），成長的是 V8 已占用的堆積容量（`heapTotal` 12→28 MB，與 `Pss_Anon` 的增量一致）。查到的證據：

- 兩份相隔約 280 次的 heap snapshot，存活物件只多 386 KB，全是 JIT 程式碼；任何時刻都只有 6～7 個 fiber、2～3 個 instance，沒有已撤除的插件被留住。`external`、`arrayBuffers` 與 V8 的 malloc 計數都持平；模組記錄數不變（`import()` 用的是同一個檔案 URL，沒有每次重新載入）。
- 每次掛載都會留下 Cordis 的 context、閉包、隱藏類別與診斷用的呼叫堆疊（V8 物件統計中最多的是 function context、CallSiteInfo、未編譯函式與 map）。這些都會死，但：① V8 預設讓新生代在交易負載下倍增且不歸還（新生代 4→14 MB／100 次，400 次時 27 MB）；② 每次 scavenge 約有 200 KB 晉升到老生代，老生代要到上限才做完整回收，在 100 次內通常一次都沒做。
- 只固定新生代（4 MiB semi-space）時，② 十一次中四次、③ 八次中兩次通過；再調老生代初始上限、`--optimize-for-size` 等都只是改變回收落在量測窗哪裡，結果仍時過時不過，所以不採用。

**修正（產品端，門檻、暖機與取樣都沒改）。**

- `packages/host-runtime/hostd.node-flags`：所有 hostd 啟動路徑（systemd unit、`bin/ditto-hostd`、G1 腳本）共用一份旗標：`--min/max-semi-space-size=4` 固定新生代，`--expose-gc` 供下一項使用。hostd 啟動時在日誌寫明是否拿到這些設定。
- `src/reclaim.ts`：某次掛載的 disposer 全部結束後，hostd 要求一次完整回收；合併處理，最多每秒一次。`gc` 在任何插件載入前就從全域物件拿走，插件呼叫不到。

**新數字**（以下 run id 都在 `artifacts/g1/cleanup-stress-<run_id>.d/`）：

| | 修正前（`2026-10-04T08:10:47Z-d30c`） | 修正後，八次（`09:23:37Z`～`09:28:52Z`，`-d30c`） |
| --- | --- | --- |
| ② PSS 中位數增幅 | +14.2% | −1.4%～+0.7% |
| ② Mann-Kendall p | 0.001 | 0.032～1.0；7／8 通過 |
| ② `Pss_Anon` 首→尾 | 16.4→29.6 MB | 19.0～19.4 → 19.7～20.2 MB |
| ③ PSS 中位數增幅 | （當時沒有 ③） | −2.5%～+1.3% |
| ③ Mann-Kendall p | | 0.107～1.0；8／8 通過 |
| ③ `Pss_Anon` 首→尾 | | 17.8～18.1 → 18.6～19.3 MB |

提交後（`75279cc`）再跑三次（`2026-10-04T09:37:51Z-7527`、`09:38:10Z-7527`、`09:38:28Z-7527`）：② 增幅 −1.7%～−0.6%、p=0.15～0.72，③ 增幅 +0.2%～+1.2%、p=0.11～0.32，六項都通過。首尾計數在每一次都完全相同。tasks 停用／啟用 100 次的耗時沒有變（約 9.4 秒）。400 次的補充執行：`Pss_Anon` 19.4→21.3 MB（修正前同樣 400 次是 16→43 MB），此時 V8 堆積持平，增加的是 JIT 程式碼與原生記憶體。

**還不能主張的事。**

- 這台開發機上，每一次執行在第 40 次左右 hostd 的 `Pss_File` 都會固定下降約 1.27 MB（與其他 Node 程序共用的檔案頁面），總 PSS 因此被拉低。那一次 ② 的失敗就是這個下降造成的「遞減」趨勢（p=0.032）。反過來，若只看 `Pss_Anon`，十六次中有十二次仍有 1～5% 的單調上升（JIT 與原生記憶體的暖機），通過有一部分是靠這個下降抵消。判定照 `judge.py` 用總 PSS，沒有改；參考機上剛啟動的 hostd 是否也這樣，要以參考機數列為準。
- ③ 每次 prepare 由 hostd 命名自己的 realm（`ditto-candidate-<n>`），所以「同一 realm」指的是同一個 entry、套件與設定反覆掛進 isolate realm 再撤除；夾具以候選健康檢查拒絕讓變更中止，主 realm 不受影響。
## 熱插拔與角色位置（2026-10-04，headless，開發證據）

- 協定 0.2 加了三個選用欄位（不升版）：視窗回讀的 `output`（Wayfire 由 view 所在輸出填入，fixture 由自身狀態填入）；Profile `avatar` 的 `output`（未指定＝跟隨主輸出）與 `corner`（預設右下）；Shell `shell.report` 的 `avatar_placement`，由 `desktop.panels.list` 的 `avatar` 回傳。主輸出定義為排列在最左上的輸出，Core 與 Shell 用同一條規則。預設值不寫進文件，所以既有 Profile 與匯出檔的雜湊不變。
- Core 在輸出消失後等 0.5 秒讓 Wayfire 先搬，再回讀：只搬仍在已消失輸出上、或中心點落在輸出外的視窗，搬完再回讀；搬不動的（平鋪中，`unsupported`）寫 log 並發一則產品語言的通知。Rust 測試以 fixture 合成器涵蓋三種情況（合成器沒搬、已搬入可見範圍、搬到範圍外）與平鋪視窗的通知。
- `output-hotplug --automated`（headless 替代版），commit `f84b5a2`、工作樹無未提交變更，連跑三次 `artifacts/g1/output-hotplug-2026-10-04T08:38:{20,25,31}Z-f84b.json`：`windows-visible` 與 `avatar-visible` 三次皆 `pass`。視窗在拔除前由 Core 回讀確認在 `HEADLESS-2`，之後在 `HEADLESS-1` 的目前工作區；Core 的 log 記錄 `checked=1 already_visible=1 moved=0`，也就是 Wayfire 已自行搬好、Core 沒有重複搬。角色先經 ChangeSet 放到 `HEADLESS-2`，拔除後 Shell 回報它在 `HEADLESS-1` 右下、`follows_primary: true`、整個表面在輸出內。
- 同一次開發也找到一個 Shell 問題並修正：輸出消失會連帶關掉角色的 layer surface，換到新輸出後它保持隱藏（`visible` 的綁定值沒變，所以不會重算）。現在 Shell 在應顯示卻未顯示時重新顯示一次，log 為 `ditto-shell avatar shown again on <輸出>`。
- 限制：角色位置是 Shell 依自己的表面（所在 screen、錨定角、邊距、尺寸）回報，不是合成器的回讀；Wayfire IPC 沒有列出 layer surface 的位置。這兩項 `pass` 不是 EX1-13 ⑤ 的證據：出口仍需參考機接上第二台實體螢幕，跑 `--automated`（`wlr-randr`）與 `--physical`（操作者拔線）兩個變體。

## 生命週期契約 L-01～L-10（2026-10-04，開發機，fixture 合成器，開發證據）

`lifecycle/run.sh` 在 commit `3c61e47` 的乾淨工作樹上連跑三次，三次都是 12 項子檢查全部 `pass`（`artifacts/g1/lifecycle-2026-10-04T08:39:51Z-3c61.json` 等三份）。這是開發機與 fixture 合成器上的開發證據，不是 EX1-08 的出口通過：出口仍要參考機的 PR 快檢與 nightly 紀錄。

- 量到的值：L-05 在 `SIGKILL` hostd 後 29～44 ms 內，`desktop.tasks.list` 的可用性轉為 `host_unavailable`（門檻 500 ms，計時含觀察端的輪詢）；L-07 在 `SIGSTOP` 後約 6.1 秒撤銷綁定，靠的是 6 秒心跳逾時，不是 10 秒的租約效期；L-06 的變更以 `rolled_back` 結束並列出 3 項。
- 測試本身另外連跑：`cargo test --test lifecycle` 連續 10 次，及三份測試程式同時執行一次，都沒有失敗。
- 寫測試時找到並修正了四個產品問題，修正前對應的斷言都會失敗：
  - L-05：prepare 後 hostd 死掉的變更會被送去 commit 再回復，結果是 `partially_applied`。現在在 commit 前發現參與者連線已斷就從 `prepared` 中止（`change.participant_lost`）。
  - L-06：交接中 hostd 死掉時，回復的回讀仍送往已斷的連線，變更一律 `partially_applied`。現在等重啟的 hostd 上線、推送 head（仍是基底），再經新連線回讀；新 hostd 回答不記得這個變更（`participant.change_unknown`），由回讀判定。
  - L-10：客戶端在協調器受理前斷線，排隊中的提案仍會被執行。現在連線結束時標記，提案在寫入草稿前檢查，被丟棄（`change.dropped_before_acceptance`）。
  - 心跳逾時後被放棄的 hostd 連線，在下一個 hostd 連上前仍可送心跳與 `host.hello`，而且同一次失聯會被計兩次重啟。現在所有 host 方法都要求是目前存活的連線。
- 限制：L-07 的「舊 generation 租約」負例由新 hostd 經測試建置的 `lease.renew:present=` 把舊 id 送給 Core（舊程序已被 Core 終止，無法自己送）；L-09 的「使用者手動修改」由 CLI 身分送出，不是 Shell。L-05 的「合成器操作照常」只驗證 fixture 合成器的讀取能力在變更被卡住時仍回應。

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

## EX1-10 分層資源量測工具（2026-10-05，開發機，headless 夾具，開發證據）

`measure/` 是 G1-QA-05 的工具，**還沒有在參考機跑過任何一次正式量測**，所以 EX1-10 沒有任何數字可以主張。

- `cold-login.sh` 沿用 G0 的規則：每次 run 一次登入管理器登入、登入超過 600 秒拒絕、同一個登入不得量第二次（登入以 `<boot_id>:<logind session>` 記在 `cold-login-logins.txt`，開始採樣前就寫入）、非參考機只能 `DITTO_FORMAT_CHECK=1`，暖機 300 秒、採樣 600 秒（121 點，跨度滿 600 秒）、間隔 5 秒、登入年齡上限與三個參考應用只有在格式檢查時才能放寬。開始前回讀實際狀態：Core 的命令列有沒有 `--mode rescue`、Shell 的 `DITTO_AVATAR`、Ditto 單元中的 Node 程序（`rescue_no_node` 必須為零）、hostd 是否 `running`、Profile 中沒有 D-34 插件；每個執行中的 `ditto-*` 單元都必須能歸類到一層，否則拒絕。採樣前後單元集合或主程序有變，這次 run 不記錄。
- `rescue_no_node` 經 `measure-conditions.json` 的 `desktop_variant: rescue-no-node` 選擇；登入 script 寫入 `DITTO_CORE_MODE_ARGS=--mode rescue`，驗證安裝的 relay 改由兩個環境變數組成，在這個變體換成第二個 `--mode rescue`，所以不啟動 Node。一般登入不設這些變數，Core 的命令列不變（以 systemd 255 的暫時單元確認：未設定或空值的 `$VAR` 展開為零個參數，`EnvironmentFile=` 覆蓋 `Environment=`）。
- hostd 的 `heap_used`／`external`／`array_buffers` 由 `ditto-measure` 每次採樣經 relay 讀 `desktop.plugins.diagnostics`，與 PSS 分欄。回讀 relay 本身是 Node 程序，報告逐次列出它的 PSS，但不計入桌面合計，並寫明原因。
- 夾具試跑（`dry-run.sh`，commit `ee637af`，乾淨工作樹，暖機 2 秒、採樣 3 秒、只開 foot）：四個狀態各三次「登入」都記錄成功並產生報告，報告全部標為開發試跑、不判定。`rescue_no_node` 三次 Core 都是 rescue 模式、Ditto 單元中 Node 程序 0 個；完整桌面各狀態是 2 個（hostd 與 relay）。hostd 的 V8 欄位在 B 採樣時有值；A 與 `desktop_full_no_agent` 的 2 秒暖機短於 hostd 每 10 秒一次的回報，所以全是缺值並列出原因，參考機的 300 秒暖機不受影響。一次較早的試跑在中途改了工作樹，`report-ab` 因指紋（未提交路徑數）不同而拒絕產生報告，這是預期的行為。
- **找到的缺口：D-34 的五個 QML 插件掛不上。** 啟用的 ChangeSet 會提交，五個 Cordis 插件三次都是 `active`，但 Shell 掛上的 QML 數三次都是 0：它們宣告的 `ui.status_item` 不是 Core 認得的 slot，Profile 的 slot 一次只綁一個 entry，Shell 只載入綁在 slot 上的 QML。A/B 報告因此寫「不對 ≤50 MiB 判定」。這需要 Core 與 Shell 提供能同時掛上多個狀態項的位置（見上方「各工作流要提供什麼」），量測工具不繞過它。
- 沒有驗證的：真正的登入管理器登入、GDM 自動登入與 `ditto-relogin` 的串接（`series.sh` 只以替身測過續跑、重試與失敗上限，`test-series.sh`）、Firefox 與 Kate 的啟動、Fcitx 層、`install-session.sh --verification-relay` 實際安裝後的單元（只在暫存目錄展開並以 `systemd-analyze verify` 檢查）。本機沒有 `shellcheck`，腳本只做了 `bash -n`。
