# G2 出口評審｜開發證據與待評審項目

| 欄位 | 內容 |
| --- | --- |
| 狀態 | **未評審。** 本檔整理 2026-10-08 在開發機（同時是參考機 `ditto-ref-ws-rtx4060-01`）與開發 VM 取得的證據；十九項出口沒有任何一項由本檔判定通過 |
| 計畫 | [plan/04](../../../plan/04/README.md) |
| 範圍 | `main@787b44a` 之後分支 `codex/g2-agent-foundation` 的 23 個提交（`108d25e`…`12851f5`） |
| 評審者 | owner（依 D-38 慣例，實際使用裁定）；本檔只陳列事實、缺口與提案 |

證據類別：`development-host`（開發機、fixture compositor、腳本模型）、`development headless desktop`（開發機巢狀 headless Wayfire＋真 Shell）、`development-vm`（還原快照的 VM，HWE 7.0 核心）、`development-host-real-subscription`（真實訂閱，尚無結果）。開發機雖是參考機，以下**都不是**參考機出口量測：沒有一項是冷登入、實體座位或真實模型的出口流程。

## 1. 結論摘要

- **已實作並有開發證據**：Core 啟動並驗證隔離的 Codex app-server、動態工具全經 Core、ChangeSet 歸屬 Agent turn 並回讀、會話與設定由 Core 持有、approval 四結果、使用者附加的 context、job pool 配額、可保存的區域布局、直接 API 金鑰路徑（Secret Service）、Shell 聊天兩種外觀與七態、閒置回收、崩潰後的工具結果對帳、競爭與模型斷線故障。
- **阻擋出口、需要本人**：真實訂閱尚未登入（2026-10-08 授權頁開啟等待 240 分鐘至 19:50 逾時，未登入；`subscription.mjs` 誠實以 `signed in through the browser` 失敗結束）。因此 EX2-01／02／03／11／19 的真實模型部分、語意分數與帳號矩陣都**未執行**；工具與夾具已備妥，登入後可直接跑。
- **阻擋出口、需要參考機流程**：EX2-12／13／14 的冷登入與實體座位量測要登出目前的桌面工作階段，未在本次執行；方法與工具已就緒並以 headless 乾跑驗證。
- **本輪修正的產品缺陷**：區域布局在用戶端提交尺寸前就判定「已驗證」（Firefox 保留自己的寬度時會假成功）；Codex 模型服務失敗被報成 `interrupted`；Core 連線關閉洩漏執行緒與 socket；Profile 可綁定 Core 保留的快捷鍵。

## 2. 十九項出口逐項

「狀態」欄：**有開發證據**＝所需行為在開發環境有可重現的通過證據，但出口要求的環境（參考機、冷登入、真實模型）尚未執行；**未執行**＝出口要求的核心證據尚無；**部分**＝部分子項有證據、部分未執行。

| 出口 | 狀態 | 已有證據 | 缺什麼 |
| --- | --- | --- | --- |
| EX2-01 跨三類一個計畫 | 部分 | 腳本模型經 Codex 動態工具改通知政策並回讀（`codex/run.mjs`）；布局＋插件＋通知的參考解在語意集 F-C05／F-C06 自我檢查通過 | 真實模型以非預設語句完成跨三類（語意集 C 類、真實訂閱） |
| EX2-02 最近目標、保持其他 | 部分 | Core 在 claim 附上最近 ChangeSet（`recent_changes`，`run.mjs` 驗證追問 turn 帶到 change id）；oracle 以未觸及欄位雜湊判定（語意集 E 類） | 真實模型多輪修正與中英文變體 |
| EX2-03 保存／複製／比較／切換／撤銷 | 部分 | Profile duplicate／rename／switch／undo 經 Core；會話→turn→工具→ChangeSet→revision 一次可查（`agent.turns.trace`）；語意集 D 類自我檢查 16／16 | 真實模型；參考應用未儲存內容存活需參考機 |
| EX2-04 GUI 與 Agent 競爭 | 有開發證據 | `codex/races.mjs`：Agent 持舊 base 時本人提交同一項 → Agent 的 ChangeSet `rejected`、本人的值保留；授權撤銷後同一讀取不再執行；AI 關閉後不再動作 | 參考機重跑 |
| EX2-05 斷網、逾時、斷線、取消 | 有開發證據 | `codex/faults.mjs` 20／20：停止 109 ms 結束為 `cancelled`；app-server SIGKILL → 整代收掉；模型 HTTP 500／連線中斷 → `provider_unavailable`（約 24 s，Codex 自身重試）；3 s 模型預算 → `provider_timeout`；皆無工具執行、桌面不變。`codex/crash.mjs`：Core 在 applying／verifying 中斷，重啟後工具結果依 ChangeSet 對帳、turn 為 `unknown`、下一代不重播 | 真實模型；Codex 約 24 s 才放棄的使用者感受需評審 |
| EX2-06 授權一致、外部內容不授權 | 有開發證據 | approval 四結果 fail-closed、`never` 模式拒絕、鎖定時記 `unavailable` 並拒絕（`desktop.sh` 18／18）；對話記下 approval 的提問與結果；繁中英文注入 16／16（`codex/injection.mjs`）；Profile 不得綁定保留快捷鍵 | 真實模型下的注入；參考機 |
| EX2-07 真實閒置回收 | 有開發證據 | 真實 5 分鐘：300.3 s 釋放、無殘留 Agent 程序（`lifecycle/run.mjs idle`）；活動中不誤殺（`activity`）；100 次啟停 Core PSS +0.1%；重啟保留對話、不重播 | 參考機登入工作階段中重跑；approval 等待中的不誤殺 |
| EX2-08 受理前後終止 | 有開發證據 | 受理前終止不執行（工具 intent 綁世代）；受理後 Core 提交或回復、重連查 trace（`codex/crash.mjs`、`turns.rs` 單元測試）；hostd 同 PID 存活 | 參考機 |
| EX2-09 keyring 與無秘密外洩 | 有開發證據 | 真 Secret Service 寫讀刪（`direct/run.mjs` 13／13）；金鑰不在磁碟、日誌、Profile 匯出；刪除對話後文字不留在 Core 儲存任何檔案、任何日誌（`codex/run.mjs` 40／40） | 匯入缺引用提示的端到端；Codex 登入權杖在 keyring 的檢查需真實登入 |
| EX2-10 離線與停用 | 部分 | 模型不可用時手動設定照常（faults）；無角色時 Super+A 開聊天視窗（`shell/run.sh`） | 參考機上斷網與停用角色的完整流程、重連後會話 |
| EX2-11 語意 45／50 與保留集 | 未執行 | 固定集與保留集各 50 題、oracle 只讀 Core；自我檢查兩組各 50／50、空白對照兩組各 0／50 | 真實模型全集（需登入）；D-43 待決 |
| EX2-12 冷啟動 p95 ≤2 s | 部分 | 開發機 30 次 p95 118 ms（release Core，fixture）；方法見 `measure/cold-start.mjs` | 參考機登入工作階段中、真實後端與真實首字 |
| EX2-13 暖態首幀 p95 ≤150 ms | 部分 | 聊天 200 次 p95 30 ms、啟動器 200 次 p95 40 ms（headless，`measure/chat-first-frame.sh`） | 實體座位呈現時間（wp_presentation）、G1 的呈現警訊 |
| EX2-14 四狀態冷登入資源 | 未執行 | 冷登入工具新增 `desktop_full_agent_warm`／`_active`、預算判定（Agent ≤150、全桌面 ≤750 MiB）；headless 乾跑三次：Agent 62.2～62.8 MiB、全桌面 268.4～269.0 MiB（不是證據）；一個 turn 後 Agent 群組 102～115 MiB | 參考機三次真冷登入×四狀態；活動狀態需登入訂閱 |
| EX2-15 程序上限、工作池、清理 | 有開發證據 | ≤1 controller＋≤1 app-server（Core 單例）；工作池兩個並行、第三個排隊、取消、逾時、OOM（256 MiB 範圍內 512 MiB 被殺）、CPU 0.50 核（`jobs/run.mjs` 17／17）；100 次清理 | D-44 的後端 cgroup 硬限制尚未設定 |
| EX2-16 兩種聊天外觀與七態 | 部分 | 角色旁面板↔完整視窗、草稿與串流 20 次切換不丟、七態文字、無角色入口、AI 設定鍵盤操作（`shell/run.sh`）；第一次使用的三個例子依能力啟用 | 實體鍵盤中文輸入（D-38 追蹤項）、reduced motion 實機 |
| EX2-17 Core 持有會話與設定 | 有開發證據 | 單 writer、append／flush、torn tail、中段損毀、磁碟滿、遷移回滾、刪除中斷（`ditto-store` conversations 故障套件）；刪對話不撤銷配置 | 參考機 |
| EX2-18 移植、契約新鮮度、身分 | 有開發證據 | [harness-g2-port](../../../docs/upstream/harness-g2-port.md)：Harness 9 檔雜湊、Codex 與 D-Bus proxy 釘選；schema→TS 新鮮度；G2 共享向量（Rust 與 TS 同檔，含未知 enum／多餘欄位拒絕）；Agent 身分只能由 Core 啟動取得 | CI 在 runner 上的第一次執行 |
| EX2-19 Codex 訂閱真實矩陣 | 未執行 | 授權網址取得、keyring 儲存設定、無 `auth.json`、內建工具不可旁路（腳本模型）；帳號矩陣工具 `account-matrix-driver.mjs` 已備 | 本人登入；登出／取消／切帳號（切帳號需第二個帳號）、配額耗盡無法刻意產生 |

## 3. 執行紀錄

### 3.1 一次完整的開發機執行（`tests/g2/run.sh desktop`）

2026-10-08T09:47Z（`12851f5`，產物 `artifacts/g2/run-2026-10-08T09:47:54Z-12851`）：

| 套件 | 結果 | 主要數字 |
| --- | --- | --- |
| confine | 通過 | 3 個邊界測試 |
| foundation | 通過 | |
| codex-run | 通過 | 40／40；一個 turn 後 Agent 群組 PSS 115 MiB（controller 19.4、app-server 94.5、confine 0.5、proxy 0.5） |
| codex-faults | 通過 | 20／20 |
| codex-crash | 通過 | applying、verifying 各 9 項 |
| codex-injection | 通過 | 16／16 |
| codex-races | 通過 | 7／7 |
| jobs | 通過 | MemoryMax 256 MiB、CPU 0.5 核、TasksMax 32；11 個套件驗證 |
| lifecycle quick | 通過 | 100 次啟停，Core PSS 20 418→20 454 KiB |
| cold-start | 通過 | 30 次：authenticated p50 112、p95 118、最大 425 ms（目標 p95 ≤2 000） |
| layout | 通過 | 6／6（Wayfire） |
| codex-desktop | 失敗（無效） | 執行途中 `desktop.sh` 正被修改（加入鎖定案例），bash 讀到半截檔案；單獨重跑見下 |
| shell | 通過 | 6／6 |
| semantic 自我檢查／空白對照 | 通過 | 固定、保留各 50／50 與 0／50 |

單獨重跑 `codex/desktop.sh`（09:54Z，`346ed26` 加上鎖定案例）：18／18，含「鎖定時 approval 記為 unavailable、呼叫被拒」。首幀（09:58Z 起，headless）：聊天 200 次 p50 29、p95 30 ms；啟動器 200 次 p50 39、p95 40 ms。

### 3.2 VM（`tools/dev-vm/run-g2.sh`，快照 `ditto-g2`，核心 7.0.0-38）

2026-10-08T09:08Z（`15af0b5`）：還原、同步、建置、Rust、Node、foundation、Codex binary、D-Bus proxy 建置、`ditto-confine`、codex-run、codex-faults、codex-injection、jobs、lifecycle、layout、codex-desktop、shell 共 17 項全數通過。之後（`58d5fcb`，`2026-10-08T10:08:49Z-58d5`）再跑一次，加上 fault-injection 建置、codex-crash、codex-races：20 項全數通過。前一次（`6c492d3`）的 codex-faults 失敗揭露了一個缺陷，見 §4.1。原快照 `ditto-base`（核心 6.8）沒有 Landlock ABI 6，Core 依設計拒絕啟動後端；那些套件現在記 `not_run` 而非失敗。

### 3.3 單獨執行

| 套件 | 結果 | 類別 |
| --- | --- | --- |
| `lifecycle/run.mjs idle`（真實 5 分鐘） | 3／3，300.3 s 釋放 | development-host |
| `codex/crash.mjs` | applying 與 verifying 各 9 項通過；兩者 recovery 皆判 `partially_applied`（見 §4.3） | development-host |
| `codex/races.mjs` | 7／7 | development-host |
| `semantic/run.sh --self-test`／`--null` | 固定集 50／50、0／50；保留集 50／50、0／50（Chrome 代瀏覽器） | development headless desktop |
| `ditto-measure` 乾跑 `desktop_full_agent_warm` | 三次格式檢查完成（2 s 暖機，非證據） | development headless desktop |

## 4. 發現

### 4.1 已修正

| 問題 | 影響 | 修正 |
| --- | --- | --- |
| 區域布局的回讀讀到 Wayfire 收到的請求尺寸，不是用戶端提交的尺寸 | Firefox（浮動視窗只把 configure 當建議）保留 348 px 寬時，變更仍判 committed：違反「完成以回讀為準」 | Core 放置後等到視窗幾何連續 150 ms 不變（上限 1.5 s）再判定；Firefox 不接受時誠實回滾（`3626fdd`） |
| Codex turn 失敗一律報 `interrupted` | 使用者看不出是模型服務不可用 | 依 `codexErrorInfo` 報 `provider_unavailable`／`rate_limited`（`78bc437`） |
| 連線關閉時每條連線留下 2 執行緒、3 fd | 每個 Agent 世代約 107 KiB PSS 累積 | 關閉時送出 Shutdown（`63c0624`） |
| Profile 可透過 `/shortcuts` 綁 Core 保留的組合鍵 | Super+A 可被改掉，聊天入口消失 | preflight 拒絕（`cb250d5`） |
| 第一次啟動 Agent 時，Core 在 10 秒啟動期限內雜湊並掃描 290 MB 的 Codex binary | 慢的機器（debug 建置的 VM）上，新 store 的第一個 Agent 在連上時被拒 | 期限改從 controller 啟動起算；以 memchr 搜尋目錄；dev 建置最佳化 sha2／memchr（`58d5fcb`） |
| 量測乾跑的 `prepare` 會連到登入中的工作階段的 relay | 2026-10-08 一次嘗試在使用中的 Profile 建立了一筆 `aborted` 的 ChangeSet（無任何套用，head 不變） | 乾跑在登入前把 relay 指向不存在的路徑（`c9f3b5a`） |

### 4.2 環境限制

- 參考平台 AppArmor 禁止非特權 user namespace：bubblewrap 與 Codex 自帶 sandbox 都不能用，邊界由 `ditto-confine`（Landlock＋seccomp）提供；需要核心 Landlock ABI ≥6。
- Ubuntu 的 xdg-dbus-proxy 0.1.5 會斷開 zbus 用戶端，改用自建釘選的 0.1.9。
- headless 夾具裡的 Firefox 不接受寬度變更；開發機的布局題以 Chrome 代替，參考機出口仍用 Firefox。
- Codex 對模型服務失敗自行重試約 24 秒，Ditto 目前無法縮短（訂閱路徑的 provider 設定不由 Ditto 覆寫）。

### 4.3 交 G1 範圍追蹤

hostd 承載的條目在 Core 與 hostd 一起中斷後，開機恢復把 applying 與 verifying 的變更都判為 `partially_applied`（Shell 承載的外觀變更在 G1 測試中分別判為 `rolled_back`／`committed`）。桌面實際狀態與 head 一致（舊值），只是判定比可能的更保守。Agent 端照實回報 `unknown` 並不重做。建議在 G1 coordinator 的 hostd 回讀規則中檢討。

## 5. 待決與提案（D-39～D-44，均未核定）

| 編號 | 本輪取得的資料 | 提案 |
| --- | --- | --- |
| D-39 協定 0.3 | wire 型別、閉集原因、`conversations` 主題、approval 綁定、`agent.turns.trace` 已實作；Rust 與 TS 共享向量通過 | 以目前 0.3 形狀凍結，trace 列入契約 |
| D-40 布局 | 浮動區域規則：放置、變窄、撤銷、後開視窗、平鋪時拒絕（`layout/run.sh` 6／6，Wayfire）；用戶端提交後才判定 | 採浮動比例區域；容差 2 px＋幾何穩定 150 ms |
| D-41 會話儲存 | 事件檔＋SQLite 索引、預設保留、刪除即移除文字（已驗證）、工具前先落盤 | 依實作定案；30 天自動清除另議 |
| D-42 人力 | 本分支 23 個提交完成可在開發環境驗證的工作包；剩餘工作集中在真實模型、參考機量測與評審 | owner 依剩餘項目重估 |
| D-43 保留集門檻 | 兩組 50 題與 oracle 就緒，尚無真實模型分數 | 先報原始比較；門檻維持計畫提案（≥45／50、降幅 ≤5 pp） |
| D-44 Codex 程序與限制 | 一個 turn 後 Agent 群組 102～115 MiB（controller 15.7～19.4、app-server 87.2～94.5、confine 0.5、proxy 0.5 MiB），各次之間差約 13 MiB；新啟動約 63 MiB；後端無 MemoryMax | 參考機冷登入量測後再定 hard limit；暫提 MemoryMax 256 MiB 給整個 Agent scope，量測前不套用 |

## 6. G3 交接

- 已可沿用：Core 對 Agent 的單例、世代、活動租約與回收；工具 intent／dispatch／trace 與開機對帳；Core 的 job pool（受信任種類、配額 scope）可承載 G3 生成與驗證工作；`ditto-confine` 可作為生成物隔離測試宿主的起點（Landlock＋seccomp，但沒有 user namespace）。
- G3 前必須處理：EX2 的真實模型與參考機項目；D-44 hard limit；approval 在鎖定狀態下的行為；`ditto-generation-safety` 仍是 draft，其隔離前提（principle 4）要以 `ditto-confine` 的實際能力重新核對。
- skill 核對：`ditto-agent-changeset` 與 `ditto-permission-and-secrets` 依 G2-AGENT-01／05 與 G2-CORE-02 的實作核對後改為 stable（2026-10-08）；`ditto-cordis-plugin`、`ditto-failure-and-rescue`、`ditto-generation-safety` 不屬 G2 核對範圍，維持 draft。

## 7. 登入後要跑的命令

```text
# 1. 本人在瀏覽器完成登入（若尚未）：
node tests/g2/codex/subscription.mjs
# 2. 帳號矩陣（加 DITTO_G2_MATRIX_LOGOUT=1 會在最後登出並測取消登入）：
DITTO_G2_TASK=matrix node tests/g2/codex/subscription.mjs
# 3. 語意集（真實模型，計分）：
tests/g2/semantic/run.sh --tasks fixed
tests/g2/semantic/run.sh --tasks holdout
# 4. 活動狀態資源量測（參考機冷登入）：
tests/g1/measure/cold-login.sh prepare desktop_full_agent_active
```
