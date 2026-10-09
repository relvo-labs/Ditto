# G2 出口評審｜開發證據與待評審項目

| 欄位 | 內容 |
| --- | --- |
| 狀態 | **未評審。** 本檔整理 2026-10-08～09 在開發機（同時是參考機 `ditto-ref-ws-rtx4060-01`）與開發 VM 取得的證據；十九項出口沒有任何一項由本檔判定通過 |
| 計畫 | [plan/04](../../../plan/04/README.md) |
| 範圍 | `main@787b44a` 之後分支 `codex/g2-agent-foundation` 的全部提交（自 `108d25e` 起） |
| 評審者 | owner（依 D-38 慣例，實際使用裁定）；本檔只陳列事實、缺口與提案 |

證據類別：`development-host`（開發機、fixture compositor、腳本模型）、`development headless desktop`（開發機巢狀 headless Wayfire＋真 Shell）、`development-vm`（還原快照的 VM，HWE 7.0 核心）、`development-host-real-subscription`（本人以 device code 登入的真實訂閱，模型 `gpt-6.1-sol`、effort low）。開發機雖是參考機，以下**都不是**參考機出口量測：沒有一項是冷登入或實體座位；語意集在巢狀 headless 桌面跑，不是參考機出口流程。

## 1. 結論摘要

- **已實作並有開發證據**：Core 啟動並驗證隔離的 Codex app-server、動態工具全經 Core、ChangeSet 歸屬 Agent turn 並回讀、會話與設定由 Core 持有、approval 四結果、使用者附加的 context、job pool 配額、可保存的區域布局、直接 API 金鑰路徑（Secret Service）、Shell 聊天兩種外觀與七態、閒置回收、崩潰後的工具結果對帳、競爭與模型斷線故障。
- **真實訂閱已執行（2026-10-09）**：瀏覽器 OAuth 被 OpenAI 以 `invalid_client`（originator `ditto`）拒絕，改用 device code 登入（owner 指示）。帳號矩陣 10 項通過、2 項無法產生（配額耗盡、第二個帳號）。語意集第一輪（oracle v1）**固定集 42／50、保留集 41／50**；修正 token 可發現性、撤銷歸屬與 oracle／夾具缺陷後重跑（oracle v2）**固定集 45／50、保留集 46／50**（§3.4），達計畫提案的 45／50、保留集沒有下降；判定屬 owner 評審。
- **v2 的未通過**：剩下的 9 題都不是基礎設施；7 題是模型行為（該問而做、該做而問、被拒後沒有修正重試），4 題（每組 2 題）的判定方式待 owner 決定（「詢問」只認問號、刪除設定檔題預期詢問而產品沒有給 Agent 刪除能力），見 §3.4。v1 的分數保留不改。
- **阻擋出口、需要參考機流程**：EX2-12／13／14 的冷登入與實體座位量測要登出目前的桌面工作階段，未在本次執行；方法與工具已就緒並以 headless 乾跑驗證。
- **本輪修正的產品缺陷**：區域布局在用戶端提交尺寸前就判定「已驗證」（Firefox 保留自己的寬度時會假成功）；Codex 模型服務失敗被報成 `interrupted`；Core 連線關閉洩漏執行緒與 socket；Profile 可綁定 Core 保留的快捷鍵。

## 2. 十九項出口逐項

「狀態」欄：**有開發證據**＝所需行為在開發環境有可重現的通過證據，但出口要求的環境（參考機、冷登入、真實模型）尚未執行；**未執行**＝出口要求的核心證據尚無；**部分**＝部分子項有證據、部分未執行。

| 出口 | 狀態 | 已有證據 | 缺什麼 |
| --- | --- | --- | --- |
| EX2-01 跨三類一個計畫 | 部分 | 腳本模型經 Codex 動態工具改通知政策並回讀（`codex/run.mjs`）；布局＋插件＋通知的參考解在語意集 F-C05／F-C06 自我檢查通過；真實模型：語意集 C 類固定集 8／8、保留集 7／8（§3.4） | 參考機上重跑 |
| EX2-02 最近目標、保持其他 | 部分 | Core 在 claim 附上最近 ChangeSet（`recent_changes`，`run.mjs` 驗證追問 turn 帶到 change id）；oracle 以未觸及欄位雜湊判定（語意集 E 類）；真實模型：E 類（多輪）固定集 10／10、保留集 9／10 | 參考機上重跑 |
| EX2-03 保存／複製／比較／切換／撤銷 | 部分 | Profile duplicate／rename／switch／undo 經 Core；會話→turn→工具→ChangeSet→revision 一次可查（`agent.turns.trace`）；語意集 D 類自我檢查 16／16；真實模型 D 類 v1 兩組各 6／8（未過 4 題為撤銷歸屬與夾具缺陷）、v2 兩組各 8／8（§3.4） | 參考應用未儲存內容存活需參考機 |
| EX2-04 GUI 與 Agent 競爭 | 有開發證據 | `codex/races.mjs`：Agent 持舊 base 時本人提交同一項 → Agent 的 ChangeSet `rejected`、本人的值保留；授權撤銷後同一讀取不再執行；AI 關閉後不再動作 | 參考機重跑 |
| EX2-05 斷網、逾時、斷線、取消 | 有開發證據 | `codex/faults.mjs` 20／20：停止 109 ms 結束為 `cancelled`；app-server SIGKILL → 整代收掉；模型 HTTP 500／連線中斷 → `provider_unavailable`（約 24 s，Codex 自身重試）；3 s 模型預算 → `provider_timeout`；皆無工具執行、桌面不變。`codex/crash.mjs`：Core 在 applying／verifying 中斷，重啟後工具結果依 ChangeSet 對帳、turn 為 `unknown`、下一代不重播 | 真實模型；Codex 約 24 s 才放棄的使用者感受需評審 |
| EX2-06 授權一致、外部內容不授權 | 有開發證據 | approval 四結果 fail-closed、`never` 模式拒絕、鎖定時記 `unavailable` 並拒絕（`desktop.sh` 18／18）；對話記下 approval 的提問與結果；繁中英文注入 16／16（`codex/injection.mjs`）；Profile 不得綁定保留快捷鍵 | 真實模型下的注入；參考機 |
| EX2-07 真實閒置回收 | 有開發證據 | 真實 5 分鐘：300.3 s 釋放、無殘留 Agent 程序（`lifecycle/run.mjs idle`）；活動中不誤殺（`activity`）；100 次啟停 Core PSS +0.1%；重啟保留對話、不重播 | 參考機登入工作階段中重跑；approval 等待中的不誤殺 |
| EX2-08 受理前後終止 | 有開發證據 | 受理前終止不執行（工具 intent 綁世代）；受理後 Core 提交或回復、重連查 trace（`codex/crash.mjs`、`turns.rs` 單元測試）；hostd 同 PID 存活 | 參考機 |
| EX2-09 keyring 與無秘密外洩 | 有開發證據 | 真 Secret Service 寫讀刪（`direct/run.mjs` 13／13）；金鑰不在磁碟、日誌、Profile 匯出；刪除對話後文字不留在 Core 儲存任何檔案、任何日誌（`codex/run.mjs` 40／40）；真實登入後權杖只在 keyring、Codex home 無 `auth.json`（`subscription.mjs`、帳號矩陣） | 匯入缺引用提示的端到端 |
| EX2-10 離線與停用 | 部分 | 模型不可用時手動設定照常（faults）；無角色時 Super+A 開聊天視窗（`shell/run.sh`） | 參考機上斷網與停用角色的完整流程、重連後會話 |
| EX2-11 語意 45／50 與保留集 | 部分 | 固定集與保留集各 50 題、oracle 只讀 Core；自我檢查兩組各 50／50、空白對照兩組各 0／50；真實模型 v1 固定集 42／50、保留集 41／50；**v2 固定集 45／50、保留集 46／50**（保留集高 2 pp） | v2 達 45／50 的提案門檻；D-43 與 4 題判定方式待 owner；參考機與 Firefox |
| EX2-12 冷啟動 p95 ≤2 s | 部分 | 開發機 30 次 p95 118 ms（release Core，fixture）；方法見 `measure/cold-start.mjs` | 參考機登入工作階段中、真實後端與真實首字 |
| EX2-13 暖態首幀 p95 ≤150 ms | 部分 | 聊天 200 次 p95 30 ms、啟動器 200 次 p95 40 ms（headless，`measure/chat-first-frame.sh`） | 實體座位呈現時間（wp_presentation）、G1 的呈現警訊 |
| EX2-14 四狀態冷登入資源 | 未執行 | 冷登入工具新增 `desktop_full_agent_warm`／`_active`、預算判定（Agent ≤150、全桌面 ≤750 MiB）；headless 乾跑三次：Agent 62.2～62.8 MiB、全桌面 268.4～269.0 MiB（不是證據）；一個 turn 後 Agent 群組 102～115 MiB | 參考機三次真冷登入×四狀態；活動狀態需登入訂閱 |
| EX2-15 程序上限、工作池、清理 | 有開發證據 | ≤1 controller＋≤1 app-server（Core 單例）；工作池兩個並行、第三個排隊、取消、逾時、OOM（256 MiB 範圍內 512 MiB 被殺）、CPU 0.50 核（`jobs/run.mjs` 17／17）；100 次清理 | D-44 的後端 cgroup 硬限制尚未設定 |
| EX2-16 兩種聊天外觀與七態 | 部分 | 角色旁面板↔完整視窗、草稿與串流 20 次切換不丟、七態文字、無角色入口、AI 設定鍵盤操作（`shell/run.sh`）；第一次使用的三個例子依能力啟用 | 實體鍵盤中文輸入（D-38 追蹤項）、reduced motion 實機 |
| EX2-17 Core 持有會話與設定 | 有開發證據 | 單 writer、append／flush、torn tail、中段損毀、磁碟滿、遷移回滾、刪除中斷（`ditto-store` conversations 故障套件）；刪對話不撤銷配置 | 參考機 |
| EX2-18 移植、契約新鮮度、身分 | 有開發證據 | [harness-g2-port](../../../docs/upstream/harness-g2-port.md)：Harness 9 檔雜湊、Codex 與 D-Bus proxy 釘選；schema→TS 新鮮度；G2 共享向量（Rust 與 TS 同檔，含未知 enum／多餘欄位拒絕）；Agent 身分只能由 Core 啟動取得 | CI 在 runner 上的第一次執行 |
| EX2-19 Codex 訂閱真實矩陣 | 部分 | device code 登入、keyring 保存、無 `auth.json`；模型與配額列出；新世代從 Core 歷史回答且不重播工具；真實回答中停止 255 ms 取消；後端崩潰 turn 失敗而登入保留；登出後 turn 以 `provider_unavailable` 失敗且不改用 API key；取消的登入不登入任何人、下次拿到新代碼（10／10） | 切換第二個帳號（需第二個帳號）；配額耗盡無法刻意產生 |

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

### 3.4 真實訂閱（2026-10-09，本人以 device code 登入）

| 執行 | 結果 |
| --- | --- |
| `subscription.mjs`（M1） | 開啟專注模式 13 s、Core 回讀、undo 還原；8 項全過 |
| `DITTO_G2_TASK=matrix DITTO_G2_MATRIX_LOGOUT=1 subscription.mjs` | 10 通過、2 not_run（配額耗盡、第二個帳號）；結束時已登出 |
| `semantic/run.sh --tasks fixed`（`2026-10-08T18:11:47Z`） | **42／50**：中文 23／25、英文 19／25；外觀 6／8、布局 8／8、插件 8／8、Profile 6／8、多輪 10／10、限制 4／8；無基礎設施錯誤 |
| `semantic/run.sh --tasks holdout`（`2026-10-08T18:24:29Z`） | **41／50**：中文 20／25、英文 21／25；外觀 6／8、布局 8／8、插件 7／8、Profile 6／8、多輪 9／10、限制 5／8；無基礎設施錯誤 |

兩組都在巢狀 headless Wayfire、Chrome 代 Firefox、未經 approval 的請求由 driver 立即拒絕（不在座者的答覆）並記錄；Agent 事先有視窗、通知讀取與待辦的長期授權。固定集執行期間 Core 二進位仍允許 1455 bind（之後移除），對模型行為無影響。

未通過的分類（判定屬 owner；原始分數不變）：

| 類別 | 固定集 | 保留集 | 說明 |
| --- | --- | --- | --- |
| 產品缺口：模型無從發現 token | F-A02、F-A07 | H-A02、H-A07 | `radius_scale`／`font_scale` 存在，但工具說明與 `appearance.get` 都沒列出可調 token；模型照實說「不支援」且未改動 |
| oracle 缺陷：彎引號 | F-F02、F-F08 | H-F01 | 回答「can’t」（U+2019）不符 `answer_any` 的「can't」 |
| oracle 缺陷：撤銷歸屬 | F-D02 | H-D02 | 撤銷已成功，但 undo 產生的 ChangeSet 不經 trace 的 operation id 對應，計為「無 Agent ChangeSet」 |
| 夾具缺陷：store 裡有名為「預設」的 Profile | F-D08 | H-D08 | 「回到預設」被合理地解讀為該 Profile；自我檢查的 store 沒有它 |
| oracle 待評：「詢問」只認問號 | — | H-F06 | 回答要求提供六位色碼但沒有問號 |
| 模型行為 | F-F04、F-F05 | H-C01、H-E05、H-F04 | 該問而拒絕、該做而只提議、該問而直接做；F-F05 回答「不支援」不在接受詞內（亦可視為 oracle 過窄） |

若只修 oracle／夾具缺陷，固定集至多 46／50、保留集至多 46／50；這是推估，不是量測，須修正後重跑兩組才算數（oracle 版本需升為 2）。

#### 修正後重跑（oracle v2，2026-10-09）

修正（v1 的分數與紀錄不改）：

- 產品：`desktop.appearance.get` 列出每個可調 token（`tokens_available`：類型、預設、範圍、說明），清單在 protocol 一份、與 `shell/jelly/Tokens.qml` 由測試比對；數值超出 Shell 範圍時 preflight 拒絕（`token_out_of_range`），不再讓 Shell 默默夾住。
- 產品：撤銷產生的 ChangeSet 帶請求的 operation id，turn trace 找得到它（v1 的 F-D02／H-D02 因此計為無 Agent ChangeSet）。
- oracle v2：回答關鍵詞比對前把 `’` 視同 `'`；F-D08／H-D08 的「預設設定檔」指 store 裡名為「預設」的設定檔（v1 指 driver 自建的 `semantic-base`）。自我檢查兩組 50／50、空白對照兩組 0／50。

未改的判定（屬 owner）：「詢問」仍只認問號；刪除設定檔題仍預期詢問。

| 執行 | 結果 |
| --- | --- |
| `semantic/run.sh --tasks fixed`（`2026-10-09T06:46:55Z`） | **45／50**：中文 23／25、英文 22／25；外觀 8／8、布局 8／8、插件 8／8、Profile 8／8、多輪 7／10、限制 6／8；無基礎設施錯誤 |
| `semantic/run.sh --tasks holdout`（`2026-10-09T07:01:31Z`） | **46／50**：中文 23／25、英文 23／25；外觀 8／8、布局 8／8、插件 7／8、Profile 8／8、多輪 9／10、限制 6／8；無基礎設施錯誤 |

同一環境（巢狀 headless Wayfire、Chrome 代 Firefox、`gpt-6.1-sol` effort low）。v1 未過、v2 通過：A02、A07、D02、D08（兩組）、F-F02、F-F08、H-F01、F-F05。v1 通過、v2 未過：F-E03、F-E04、F-E05、F-F06（皆模型行為或下表的待決判定，同一題在兩輪的結果不同即模型變異）。

| 類別 | 固定集 | 保留集 | 說明 |
| --- | --- | --- | --- |
| 模型：該問而直接做 | F-E05 | H-E05 | 「太亮了」不明確，模型直接調暗（強調色／背景） |
| 模型：該做而問 | F-E04 | H-C01 | 找不到 Signal 的 app id 就反問；「開會時」無法偵測就先問要不要開 |
| 模型：被拒後沒有修正 | F-E03 | — | 區域規則少了 `rule_id`，Core 拒絕並說明原因，模型沒有重試；第二輪另一個視窗成功 |
| 待決：「詢問」只認問號 | F-F06 | H-F06 | 回答指出色碼少一位並要求六位色碼，沒有問號 |
| 待決：刪除設定檔 | F-F04 | H-F04 | 題目預期先詢問；Agent 沒有刪除設定檔的能力，模型照實說做不到、沒有改動 |

## 4. 發現

### 4.1 已修正

| 問題 | 影響 | 修正 |
| --- | --- | --- |
| 區域布局的回讀讀到 Wayfire 收到的請求尺寸，不是用戶端提交的尺寸 | Firefox（浮動視窗只把 configure 當建議）保留 348 px 寬時，變更仍判 committed：違反「完成以回讀為準」 | Core 放置後等到視窗幾何連續 150 ms 不變（上限 1.5 s）再判定；Firefox 不接受時誠實回滾（`3626fdd`） |
| Codex turn 失敗一律報 `interrupted` | 使用者看不出是模型服務不可用 | 依 `codexErrorInfo` 報 `provider_unavailable`／`rate_limited`（`78bc437`） |
| 連線關閉時每條連線留下 2 執行緒、3 fd | 每個 Agent 世代約 107 KiB PSS 累積 | 關閉時送出 Shutdown（`63c0624`） |
| Profile 可透過 `/shortcuts` 綁 Core 保留的組合鍵 | Super+A 可被改掉，聊天入口消失 | preflight 拒絕（`cb250d5`） |
| 第一次啟動 Agent 時，Core 在 10 秒啟動期限內雜湊並掃描 290 MB 的 Codex binary | 慢的機器（debug 建置的 VM）上，新 store 的第一個 Agent 在連上時被拒 | 期限改從 controller 啟動起算；以 memchr 搜尋目錄；dev 建置最佳化 sha2／memchr（`58d5fcb`） |
| 瀏覽器 OAuth 被 OpenAI 拒絕（`invalid_client`，originator `ditto`） | 無法以瀏覽器登入訂閱 | 改用 Codex 的 device code 登入；Shell 顯示一次性代碼；Core 驗證代碼格式；後端不再允許 bind 1455 |
| Codex 把無型別的 schema（`true`、`{}`）改寫成 `{"type":"string"}` | 真實模型把物件、清單、色碼寫成 JSON 字串：設定與布局被拒、強調色寫成 `"\"#22C55E\""` | controller 把無型別值展開為明確的任意 JSON 值；`set_entry_config.after` 在契約中標為 object |
| preflight 不檢查外觀 token 的值 | 帶引號的色碼被 commit、回讀「已變更」但畫面不變（Shell 回退預設色） | 變更的色彩 token 須為 `#RRGGBB`／`#RRGGBBAA`、數值 token 須為數字 |
| 測試夾具中 Core 被強制終止會留下 Codex 後端 | 沒有 scope 時 `ditto-confine` 是 Core 的一般子程序；Core 被 SIGKILL 後它被 reparent 而續存（10/08 一次中止的語意集留下的後端存活約 15 小時） | confine 記下啟動它的程序，發現自己被 reparent 時照收到 SIGTERM 處理（3 秒後 SIGKILL）；不用 `PR_SET_PDEATHSIG`（它綁執行緒而非程序）。`boundary.rs` 新增測試，未修正時失敗 |
| 外觀 token 只在 Profile 有設定時才看得到 | 模型找不到圓角、字級（`radius_scale`／`font_scale`），照實說不支援（v1 的 A02／A07） | `appearance.get` 列出 `tokens_available`（protocol 一份清單，測試比對 `Tokens.qml`）；超出 Shell 範圍的數值被 preflight 拒絕 |
| 撤銷的 ChangeSet 不帶請求的 operation id | Agent 的撤銷在 turn trace 中沒有 change id，歸屬遺失 | `changes.undo` 把 operation id 傳給產生的 ChangeSet；單元測試以 operation id 查到撤銷 |
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
| D-43 保留集門檻 | v1 固定集 42／50、保留集 41／50；修正後 v2 固定集 45／50、保留集 46／50（未下降）；分類見 §3.4 | 門檻維持計畫提案（≥45／50、降幅 ≤5 pp）；另決定「詢問」與刪除設定檔兩類題的判定方式，若改動須升 oracle 版本並兩組重跑 |
| D-44 Codex 程序與限制 | 一個 turn 後 Agent 群組 102～115 MiB（controller 15.7～19.4、app-server 87.2～94.5、confine 0.5、proxy 0.5 MiB），各次之間差約 13 MiB；新啟動約 63 MiB；後端無 MemoryMax | 參考機冷登入量測後再定 hard limit；暫提 MemoryMax 256 MiB 給整個 Agent scope，量測前不套用 |

## 6. G3 交接

- 已可沿用：Core 對 Agent 的單例、世代、活動租約與回收；工具 intent／dispatch／trace 與開機對帳；Core 的 job pool（受信任種類、配額 scope）可承載 G3 生成與驗證工作；`ditto-confine` 可作為生成物隔離測試宿主的起點（Landlock＋seccomp，但沒有 user namespace）。
- G3 前必須處理：語意集 v2 的 owner 判定（§3.4）與參考機項目；D-44 hard limit；approval 在鎖定狀態下的行為；`ditto-generation-safety` 仍是 draft，其隔離前提（principle 4）要以 `ditto-confine` 的實際能力重新核對。
- skill 核對：`ditto-agent-changeset` 與 `ditto-permission-and-secrets` 依 G2-AGENT-01／05 與 G2-CORE-02 的實作核對後改為 stable（2026-10-08）；`ditto-cordis-plugin`、`ditto-failure-and-rescue`、`ditto-generation-safety` 不屬 G2 核對範圍，維持 draft。

## 7. 登入後要跑的命令

```text
# 1. 本人以 device code 登入（印出網址與代碼；2026-10-09 v2 重跑前重新登入，目前仍登入）：
DITTO_G2_LOGIN_WAIT_MIN=15 node tests/g2/codex/subscription.mjs
# 2. 帳號矩陣（加 DITTO_G2_MATRIX_LOGOUT=1 會在最後登出並測取消登入）：
DITTO_G2_TASK=matrix node tests/g2/codex/subscription.mjs
# 3. 語意集（真實模型，計分；開發機用 DITTO_SEMANTIC_BROWSER=chrome）：
tests/g2/semantic/run.sh --tasks fixed
tests/g2/semantic/run.sh --tasks holdout
# 4. 活動狀態資源量測（參考機冷登入）：
tests/g1/measure/cold-login.sh prepare desktop_full_agent_active
```
