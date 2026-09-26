# 06｜驗證、故障注入與量測

> 對應工作包：G1-QA-01～07。開工前讀 `ditto-verification-evidence`；故障注入另讀 `ditto-failure-and-rescue`，資源量測另讀 `ditto-process-budget`。
>
> 總則沿用 `milestones/01/04`：功能測試檢查**實際狀態**，不檢查某個元件說了什麼；效能與資源數字只在實體參考機產生；開發 VM（D-25）只提供開發證據。

## 1. 測試分層（G1 的增量）

| 層 | G1 新增內容 | 執行時機 | 阻擋合併 |
| --- | --- | --- | --- |
| 單元 | `ditto-store`、協調器、預檢、授權、租約、事件合併、manifest 驗證 | 每次 PR | 是 |
| 契約（跨語言） | 協定 0.2 的共享向量；0.1 拒絕；hostd 方向的請求 | 每次 PR | 是 |
| schema 新鮮度＋目錄一致性 | 約 55 項能力；新增「`resource_scope` 非空」檢查 | 每次 PR | 是 |
| 生命週期契約 | L-01～L-10（`createTestHost()`＋故障注入層） | 每次 PR（host-runtime 或 coordinator 變更）＋ nightly | 是 |
| 預檢負例 | EX1-02 的六個負例＋ 02 §6 的 13 項 | 每次 PR | 是 |
| 協調器整合 | 真 Core ＋假參與者；逾時、部分完成、未知 | 每次 PR | 是 |
| 開發 VM 迴歸 | 上述之外、需要圖形但不量效能的套件（EX1-01／03／05／07 的功能部分） | 相關 PR ＋每日 | 否（報告） |
| 真機整合 | EX1-01／03／07／09／12／13 的腳本 | 參考機 nightly | 否；連續失敗擋出口 |
| 效能與資源 | EX1-10／11 | 每週＋出口前 3 次 | 否；出口門檻 |
| 人工驗收 | §8 的清單 | M4 與出口前 | 出口門檻 |

## 2. 跨語言契約（G1-QA-01）

- 共享向量放在 `tests/contract-vectors/0.2/`，每個檔案一個情境：`{ "description", "direction", "frames": [...], "expect": {...} }`。
- Rust runner（`crates/ditto-protocol/tests/vectors.rs`）與 TS runner（`packages/protocol/tests/vectors.test.ts`）讀同一批檔案。任何一邊新增欄位而另一邊沒跟上，向量就會失敗。
- 必備情境：每個錯誤值的編解碼；0.1 握手被拒；`_meta` 缺失；亂序 `seq`；重連時 `after_seq` 在佇列內與佇列外；Core 發起的 `participant.*` 請求與 hostd 的回應；`on_behalf_of` 指向未分派的 entry；同一 `operation_id` 重送時回傳既有結果而不重做。
- G0 的 21 項 Rust 與 9 項 TS 契約測試全部遷移到 0.2 並保留。

## 3. 生命週期契約測試 L-01～L-10（G1-QA-02）

`milestones/01/02 §4` 定義了十項情境。下表把每項寫成可實作的測試：**層級**決定它在 PR 快檢還是 nightly；**負例**是本計畫加嚴的部分（[README §4.2](README.md#42-加嚴的門檻)），證明保護機制真的會擋，而不只是正常路徑剛好沒出錯。

| # | 情境 | 層級 | 正例的斷言 | 故障注入負例 |
| --- | --- | --- | --- | --- |
| L-01 | 依賴消失 | TS（testHost） | 停用供應者 entry → 消費者 fiber 由 `ACTIVE` 轉 `PENDING`；其能力在假 Core 中被撤銷；恢復供應者 → 消費者回到 `ACTIVE` 且重新註冊 | 消費者的 disposer 丟出例外 → 仍被卸載、錯誤被記錄且隔離，不影響其他消費者（修改集第 6 項的逐觀察者隔離） |
| L-02 | 服務替換 | TS ＋ Rust 整合 | 以 B 替換同名服務 A → 所有 inject 它的插件重啟並取得 B；`ctx.registry` 中沒有 A 的殘留 fiber | 替換途中 B 的 `apply` 拋錯 → 交易 abort，A 仍在服務，消費者不曾停在 `PENDING` 超過交易時間 |
| L-03 | 重複註冊 | TS ＋ Rust 整合 | 候選與現役宣告同一單一供應者能力 → commit 前 Core 只有一個綁定；commit 後仍只有一個；快捷鍵與命令無重複 | 候選在 candidate 模式強行呼叫綁定能力 → Core 回 `conflict`（`candidate_cannot_claim`） |
| L-04 | Context 撤除 | TS（testHost）＋ nightly 量測 | 同一 isolate realm 掛載／撤除 100 次 → 首尾的 fiber、effect、訂閱、租約數相同 | 撤除途中注入非同步 disposer 延遲 2 秒 → 下一次掛載等待，不出現兩個實例（與 L-08 交叉） |
| L-05 | 跨宿主斷線（prepare 後） | Rust 整合（真 hostd） | prepare 完成後 `SIGKILL` hostd → 交易 `aborted`；能力 ≤500 ms 標為 `unavailable`；合成器操作照常 | 同時送出一個對該能力的呼叫 → 回 `unavailable`，不掛起 |
| L-06 | 交接階段終止 hostd | Rust 整合（真 hostd） | drain 期間 `SIGKILL` hostd → 結果為失敗或部分完成且逐項列出；hostd 重啟後不重播已完成的外部副作用（以 tasks 的檔案寫入計數驗證） | 重啟後的 hostd 收到同一 `change_id` 的 `participant.state` → 回答「不記得」，Core 以 readback 判定 |
| L-07 | 租約逾期 | Rust 整合 | 暫停 hostd 的續約（`SIGSTOP` 10 秒）→ Core 撤銷綁定，後續呼叫被拒；`SIGCONT` 後 hostd 以新 generation 重新註冊 | 舊 generation 的 `lease_id` 在恢復後被拿來呼叫 → 被拒 |
| L-08 | 非同步 disposer 未完成即再次掛載 | TS（testHost） | 第二次掛載等待前次清理完成；任一時刻最多一個實例 | disposer 永不完成 → 清理逾時（`cleanup` 宣告值）後 entry 標為故障，第二次掛載被拒並回報，而不是讓兩個實例並存 |
| L-09 | prepare 期間手動修改同一項配置 | Rust 整合 | 基底 revision 過期 → 第一筆 ChangeSet 在重新檢查時 `rejected`（`base_revision_stale`），第二筆的修改保留 | 兩筆同時進入協調器 → 嚴格序列化，第二筆看到第一筆的結果 |
| L-10 | 客戶端程序終止（受理前／後） | Rust 整合（Agent 替身） | 替身送出 `changes.propose` 後、協調器受理前被終止 → 不執行；受理後被終止 → Core 完成或回復；新的替身以 `operation_id` 查到真實結果 | 替身在受理後以同一 `idempotency_key` 重送 → 回傳既有 `change_id`，不產生第二筆 |

L-10 在 G1 用 Agent 替身驗證，G2-QA-04 以真實 Agent 回歸（AT-28）。

## 4. 故障注入框架（G1-QA-04）

一套框架，四種注入點：

| 注入點 | 機制 | 可用於 |
| --- | --- | --- |
| Core 程序內 | `fault-injection` cargo feature；環境變數 `DITTO_FAULT=<point>:<action>[:<n>]`，例如 `coordinator.after_state=applying:abort_process:1`。注入點以常數列舉，測試引用常數而非字串 | 在任一狀態轉移後終止、延遲、回傳錯誤；模擬 `SQLITE_IOERR` |
| hostd 程序內 | `DITTO_HOST_FAULT`，僅在測試建置啟用 | prepare／commit／drain 中的延遲、拋錯、不回應 |
| IPC 路徑 | `ditto-fault-proxy`：夾在客戶端與 `core.sock` 之間的測試用代理，可延遲、丟棄、重排、截斷訊息 | 斷線、亂序、半包、`outcome: unknown` |
| 環境 | 容量受限的 tmpfs 掛在 `$XDG_DATA_HOME/ditto`；`systemd-run -p MemoryMax=` | 磁碟寫滿、OOM |

兩條約束：

1. **release build 不含注入點。** CI 以 `nm`／`strings` 檢查 release 二進位不含注入點常數，並確認 `DITTO_FAULT` 在 release build 中不被讀取。
2. 注入後的斷言一律檢查**實際狀態**（資料庫內容雜湊、`desktop.*.list` 的回讀、程序清單），不檢查被注入程序的日誌說了什麼。

## 5. 清理壓力（G1-QA-03）

- 腳本：`tests/g1/cleanup-stress/run.sh`，三組各 100 次（EX1-04）。
- 計數快照來源：Core 的 `desktop.plugins.diagnostics`（綁定、租約、訂閱）、hostd 的 `EffectMeta` 彙整、Shell 的 ProviderHost 回報。每 10 次一個快照。
- PSS：每個快照點由 `ditto-measure` 取樣 hostd 與 Shell，暖機後開始。
- 判準：首尾計數**完全相同**；穩態 PSS 中位數增幅 ≤10%；10 個快照點以 Mann-Kendall 趨勢檢定，p ≥0.05 視為無單調成長。檢定方法寫進報告，不在看到數字後才選。
- 失敗時先區分：計數殘留（實作錯誤，必修）、PSS 成長但計數不變（可能是 V8 堆積行為，須延長測試並附 `heapUsed` 序列分析）。

## 6. 延遲與存活（G1-QA-06）

| 指標 | 起點 | 終點 | 樣本 | 條件 |
| --- | --- | --- | --- | --- |
| NFR-03 簡單本機操作 | Core 受理請求的時間戳 | readback 完成的時間戳 | 200 次，三種操作各約 67 次 | 暖態；不含 LLM；同時記錄 UI 首幀時間供參考，但判定以 Core 時間戳為準 |
| NFR-04 UI 插件切換 | `prepared` 寫入時間 | `committed` 寫入時間 | Dock A↔B 100 次；另報啟動器與 Cordis 服務替換各 30 次 | 不含下載、確認；報 p50／p95／最大值 |
| NFR-09 應用存活 | —— | —— | 上述全部操作期間 | 參考應用 PID 不變；Kate 未儲存緩衝的剪貼簿雜湊不變（沿用 G0 的 `unsaved-buffer.py`） |

時間戳一律取 Core 寫入 `operations` 的時間（單調時鐘另存），不取 Shell 或腳本的估計值。

## 7. 分層資源量測（G1-QA-05）

### 7.1 前提

G0 的 D-06a（Core／Shell PSS 預算）必須已核定。沒有它，hostd 分項的增量沒有對照基線；本工作包的量測排在 W8 以後，就是為了等 G0 的 EX-05 結束。

### 7.2 狀態與分項

| 狀態標籤 | 內容 | 對應預算 |
| --- | --- | --- |
| `rescue_no_node` | `--mode rescue`，無任何 Node 程序 | 報告分列，不作全桌面數字 |
| `desktop_full_no_agent` | 完整桌面、hostd 常駐（兩個服務）、Agent 不存在 | hostd ≤100 MiB；全桌面 ≤600 MiB |
| `desktop_full_plus10` | 上一列 ＋ D-34 的 10 個簡單插件 | 增量 ≤50 MiB（A/B） |
| `desktop_full_no_avatar` | 角色關閉 | 19.1 要求兩組都測 |

分項：Core、Shell、hostd、合成器、`ditto-supervisor`、鎖定客戶端（若在執行）、Fcitx。hostd 另報 `heapUsed`、`external`、`arrayBuffers` 三欄，**不相加、不與 PSS 相加**。

### 7.3 流程

沿用 G0 的 cold-login 流程（`tests/g0/measure/cold-login.sh`）並擴充：冷登入 → 暖機 300 秒 → 採樣 600 秒 → 報中位數、p95、峰值 → 重複 3 次。10 插件 A/B 在同一次登入中先量 A（無 10 插件）、再以 ChangeSet 啟用 10 插件、暖機 300 秒後量 B，三次登入各做一組。

### 7.4 排除清單

可以排除：Firefox／foot／Kate（使用者開啟的應用）、既有 OS 服務、GDM。**不可以排除**：hostd、`ditto-supervisor`、鎖定客戶端、`ditto-system` 的任何執行緒所在程序（它在 Core 程序內，自然計入 Core）。

## 8. 人工驗收清單

每項都要記錄執行者、日期、參考機指紋與錄影或截圖位置。執行者**不能是該功能的實作者**。

| # | 項目 | 對應 |
| --- | --- | --- |
| M-01 | 照 EX1-01 的七步驟操作一次並錄影 | EX1-01 |
| M-02 | 插件中心的每個欄位都有值或明確的「不適用」說明；`PENDING` 顯示為等待中的服務名稱 | MOD-01、RUN-08 |
| M-03 | 變更歷史中，部分完成與結果未知的呈現能讓非工程人員說出「哪些生效了、哪些沒有」 | EX1-03 |
| M-04 | 繁中／英文切換後逐畫面檢查，無寫死字串 | EX1-13 ④ |
| M-05 | 中文輸入：組合中心命名、搜尋式啟動器、插件中心搜尋 | EX1-13 ④ |
| M-06 | Orca 走完組合中心的主要流程 | AVA-08（G1 基礎） |
| M-07 | 鎖定後終止 Shell 與鎖定客戶端，實體螢幕上確認沒有暴露桌面內容 | EX1-12 ④ |
| M-08 | 實體拔插第二螢幕 | EX1-13 ⑤ |
| M-09 | 減少動畫與降低透明度開啟後，逐畫面確認沒有位移動畫與半透明材質 | 11.1、AVA-08 |

## 9. Agent 替身（G1-QA-07）

- `tests/g1/fixtures/agent-standin/`：Node 程式，**不含任何模型或模型 SDK**。
- 經 Core 的受控啟動器以 kind `agent` 啟動，身分綁定與 G0 相同；它只做三件事：訂閱 tasks 事件、送出 ChangeSet、以 `operation_id` 查詢結果。
- 用途：EX1-07（終止後服務仍有效）、L-10（受理前後終止）、EX1-06（身分路徑）。
- 文件與報告中一律稱為「Agent 替身」，不稱為 Agent；可主張的範圍見 [01 §5](01-scope-and-exit-criteria.md#5-g1-結束時能主張與不能主張什麼)。
- G2 開工時刪除替身或保留為測試夾具，由 G2 計畫決定；它**不得**成為 `ditto-agentd` 的起點。

## 10. CI 擴充

| 工作流 | 變更 |
| --- | --- |
| `contracts.yml` | 協定 0.2 向量（Rust／TS）；目錄一致性加 `resource_scope` 檢查；manifest schema 新鮮度 |
| `rust.yml` | 新 crate 的 fmt／clippy／test；`fault-injection` feature 的測試另跑；release 二進位不含注入點的檢查 |
| `node.yml` | `host-runtime`、`host-sdk`、`plugins/*` 的型別檢查與 Vitest；L-01～L-10；`check-vendor-manifest.sh` |
| `shell-i18n.yml`（新增） | `lupdate` 無新增未翻譯字串；寫死中日韓字串 lint |
| `licenses.yml` | 納入 vendored 套件、rusqlite（bundled SQLite）、zbus 等新依賴 |
| `vm-regression.yml` | 加入 G1 的非量測套件 |
| `nightly-refmachine.yml` | 加入 EX1-01／03／07／09／12／13 的腳本；保留 G0 的全部項目作為迴歸 |
| `weekly-measure.yml` | 加入 §7 的四個狀態與 §6 的延遲量測 |

## 11. 證據規則

沿用 `milestones/01/04 §5`，並補兩條 G1 特有的：

1. 每個出口證據都要能對應到一個**已進版的 commit**。G0 出口預檢中「未提交工作樹的證據不算」的規則在 G1 從第一天起適用。
2. 生命週期測試的結果必須同時列出正例與負例；只有正例通過的報告視為未完成。
