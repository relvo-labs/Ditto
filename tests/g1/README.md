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
| `output-hotplug/run.sh --automated` | EX1-13 ⑤ | 接第二螢幕的登入工作階段，以 `wlr-randr --off` 停用第二輸出。沒有工作階段時跑 headless 替代版：以 Wayfire IPC 建立再刪除一個 headless 輸出（C-18），並在旁邊啟動 Shell。兩者都先以 ChangeSet 把角色放到第二輸出（工作階段中結束時撤銷），再判定 `windows-visible`（Core 的視窗回讀，每個視窗帶所在輸出）與 `avatar-visible`（Shell 經 `desktop.panels.list` 回報的角色位置） |
| `output-hotplug/run.sh --physical` | EX1-13 ⑤ | 同上，由腳本引導操作者實際拔線。plan/03/05 §7 要求兩個變體都通過 |
| `rescue-no-node/run.sh` | EX1-05 | 隔離的 headless 夾具；救援 Core 以 `--mode rescue --development` 啟動，⑥ 另以受控的正常模式 Core／hostd 驗證；④ 的 Shell 文字仍需登入工作階段 |
| `preflight-negative/run.sh` | EX1-02 | ①②③ 由 Rust 契約測試判定（也在 `rust.yml` 阻擋合併），另以真實 `ditto-core` 對內建套件能表達的負例（缺套件、單一供應者衝突）回讀 head、內容雜湊與已存變更；④ 的產品文字由人在參考機的插件中心確認（`operator`） |
| `rollback/run.sh` | EX1-03 | Rust 情境測試；另寫 `rollback-<run_id>.jsonl`，每個情境一行結果類別。③ 由合成器參與者負責：切換布局策略時記下切換前的視窗位置（工作階段狀態，只在記憶體，不進 Profile），撤銷時放回；已關閉的視窗列為 `not_restored`、原因 `window_closed`，變更仍提交但結果為 `partial`。Core 重啟後的撤銷沒有位置可放回，也不會列出視窗 |
| `persistence-faults/run.sh` | EX1-09 | `fault-injection` build 的真實二進位（`crates/ditto-core/tests/persistence_faults.rs`）。真正寫滿的檔案系統需要 root 先掛好：設 `DITTO_G1_SMALL_FS=<已掛載、可寫的小 tmpfs>`，否則該項記為 `environment` |
| `contract-vectors/run.sh` | EX1-06 | Rust 與 TS 兩側共享向量、0.1 拒絕、缺口重訂、`operation_id` 重連、`on_behalf_of` 偽造、目錄 gate；加上 Agent 替身的身分路徑（經啟動器以 `agent` 受理；同一程式拿偽造 token 被 Core 拒絕） |
| `cordis-independent/run.sh` | EX1-07 | 夾具：Core（fixture 合成器）＋真實 hostd＋Agent 替身＋觀察用 driver，全部由 Core 的啟動器啟動。① 的 tasks 半邊與 ③ 在此判定（「面板」以讀 `desktop.tasks.list` 的訂閱者代替，屬開發證據）；通知策略與 ② 需要工作階段 |
| `cleanup-stress/run.sh` | EX1-04 | 夾具中 ② tasks 服務停用／啟用真的跑 100 次，每 10 次以 `desktop.plugins.diagnostics` 取快照，`judge.py` 比對首尾計數、PSS 中位數增幅與 Mann-Kendall。① 需要 Shell，③ 需要 HOST 的 realm 夾具 |
| `latency/run.sh` | EX1-11 | 時間取 Core 寫入各狀態時的 `updated_at`（經 `change_updated` 事件）。夾具量 ② 另列的 Cordis 服務數字；①②③ 本體需要工作階段。樣本寫到 `latency-<run_id>.jsonl` |

## 共用函式（`lib/common.sh`）

沿用 `tests/g0/lib/session.sh` 的 headless 合成器、開發模式 Core、`run_id` 與環境標籤，另加：

- `g1_capabilities`：以 `dittoctl --json probe capabilities` 列出 Core 目前提供且可用的能力。所需能力缺席或不可用時，子檢查記為 `not_implemented`，並寫出缺少哪些 `capability_id`。
- `g1_call`：一般能力呼叫。G0 的 `dittoctl` 只有固定的 probe 子命令，這些腳本需要 **`dittoctl probe call <capability_id> <params-json>`**（以 `--json` 印出與其他 probe 子命令相同格式的紀錄）。它不存在時，所有需要呼叫能力的步驟都是 `not_implemented`。
- `screen_fraction`：以 `grim` 截圖並計算某個顏色占畫面的比例，用來判斷鎖定時是否露出桌面。
- `g1_cargo`／`g1_run`：把一個 Rust 測試（或任一測試命令）記成一項子檢查，完整輸出存到 `<name>-<run_id>.d/`；篩選沒有跑到任何測試時是 `fail`，不是 `pass`。
- `g1_fixture_core`／`g1_fixture_stop`／`g1_head`：開發模式 Core（fixture 合成器、自己的 runtime 與 store，路徑夠短以符合 `sun_path`）；`g1_head` 回 head revision 與內容雜湊。

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
| Core | 熱插拔後把視窗移回剩餘輸出的可見範圍（plan/03/05 §7）；角色位置的回讀（2026-10-04 已提供，見下方紀錄） | output-hotplug |
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

## 熱插拔與角色位置（2026-10-04，headless，開發證據）

- 協定 0.2 加了三個選用欄位（不升版）：視窗回讀的 `output`（Wayfire 由 view 所在輸出填入，fixture 由自身狀態填入）；Profile `avatar` 的 `output`（未指定＝跟隨主輸出）與 `corner`（預設右下）；Shell `shell.report` 的 `avatar_placement`，由 `desktop.panels.list` 的 `avatar` 回傳。主輸出定義為排列在最左上的輸出，Core 與 Shell 用同一條規則。預設值不寫進文件，所以既有 Profile 與匯出檔的雜湊不變。
- Core 在輸出消失後等 0.5 秒讓 Wayfire 先搬，再回讀：只搬仍在已消失輸出上、或中心點落在輸出外的視窗，搬完再回讀；搬不動的（平鋪中，`unsupported`）寫 log 並發一則產品語言的通知。Rust 測試以 fixture 合成器涵蓋三種情況（合成器沒搬、已搬入可見範圍、搬到範圍外）與平鋪視窗的通知。
- `output-hotplug --automated`（headless 替代版），commit `f84b5a2`、工作樹無未提交變更，連跑三次 `artifacts/g1/output-hotplug-2026-10-04T08:38:{20,25,31}Z-f84b.json`：`windows-visible` 與 `avatar-visible` 三次皆 `pass`。視窗在拔除前由 Core 回讀確認在 `HEADLESS-2`，之後在 `HEADLESS-1` 的目前工作區；Core 的 log 記錄 `checked=1 already_visible=1 moved=0`，也就是 Wayfire 已自行搬好、Core 沒有重複搬。角色先經 ChangeSet 放到 `HEADLESS-2`，拔除後 Shell 回報它在 `HEADLESS-1` 右下、`follows_primary: true`、整個表面在輸出內。
- 同一次開發也找到一個 Shell 問題並修正：輸出消失會連帶關掉角色的 layer surface，換到新輸出後它保持隱藏（`visible` 的綁定值沒變，所以不會重算）。現在 Shell 在應顯示卻未顯示時重新顯示一次，log 為 `ditto-shell avatar shown again on <輸出>`。
- 限制：角色位置是 Shell 依自己的表面（所在 screen、錨定角、邊距、尺寸）回報，不是合成器的回讀；Wayfire IPC 沒有列出 layer surface 的位置。這兩項 `pass` 不是 EX1-13 ⑤ 的證據：出口仍需參考機接上第二台實體螢幕，跑 `--automated`（`wlr-randr`）與 `--physical`（操作者拔線）兩個變體。
