# 01｜G1 範圍界線、開工條件與出口門檻

> 本文回答三件事：G1 做什麼、不做什麼；什麼條件下可以開工；做到什麼程度才算通過。門檻一律寫成**可判定**的形式，每項都有明確的量測方法、證據檔案與失敗判準。

## 1. G1 範圍

### 1.1 範圍內

G1 交付以下能力，**只交付這些**：

| 群 | 內容 |
| --- | --- |
| Core 權威狀態 | SQLite 儲存層與遷移；Profile 與不可變 revision；受保護的最近可用版本；保留策略；匯出與匯入驗證 |
| Core 變更交易 | ChangeSet 狀態機；確定性預檢；熱換四等級執行器；回讀後提交；限時回復；基底 revision 檢查；`operation_id` 查詢；崩潰恢復 |
| Core 能力與權限 | 能力目錄擴充到協定 `0.2.0`；每項能力的 `resource_scope` 分級；單一授權入口；授予、撤銷與撤銷後的訂閱處理 |
| Core 系統轉接 | 桌面項目索引與應用啟動；`org.freedesktop.Notifications` 伺服端；logind 的登出、電源與鎖定訊號 |
| Cordis 宿主 | vendored Cordis 與修改集；`ditto-hostd`；交易式 `ditto-host-loader`；能力註冊代理與租約；事件橋；健康檢查與交接；資源回報；回收政策 |
| 服務插件 | 任務／待辦資料服務；通知策略服務。兩者都是非 AI、真實資料來源、Agent 不存在時照常運作 |
| SDK | `host-sdk`：manifest 驗證、能力註冊 helper、設定 schema、測試宿主、範例插件；manifest 完整語意 |
| Shell | 柔光果凍 token；UI 供應者裝載與交易參與；兩個 Dock 與兩個啟動器；應用搜尋；通知、快捷鍵、音量與網路狀態；組合中心、插件中心、變更歷史、個人化設定；變更卡；鎖定、登出與電源；繁中／英文 i18n |
| 平台 | systemd user unit 與監督；`dittoctl` 救援；無 Node 救援模式；雙螢幕與熱插拔；浮動與基本平鋪布局；全域快捷鍵路徑 |
| QA | 跨語言契約測試；生命週期契約測試 L-01～L-10；故障注入框架；清理壓力；NFR-03／04／07／08／09 量測；Cordis 啟用／Agent 不存在的分層資源量測 |

### 1.2 明確不做

| 不做 | 屬於 | 說明 |
| --- | --- | --- |
| LLM、模型適配器、Agent Runtime、會話儲存 | G2 | G1 只提供一個**不含模型**的 Agent 替身客戶端，用來驗證 AT-30 的存活規則 |
| 權限確認的互動應答者（approval seam） | G2-CORE-02 | G1 的 `ask` 政策在沒有應答者時一律**失敗即拒絕**，回 `permission_denied`，原因為 `approval_unavailable` |
| 秘密儲存與 keyring 提供方 | G2-CORE-04 | G1 的 Profile 不得出現任何秘密欄位；匯出掃描照樣執行 |
| `desktop.jobs` 的完整語意與重型工作池 | G2 | G1 只做套件安裝需要的最小 job 紀錄，不做通用工作池 |
| 生成、測試宿主、Landlock／bwrap 隔離 | G3 | D-08 須在 G1 **開工前**決定方向，但實作不在 G1 |
| 網路套件來源 | D-10 決定 | G1 只從本機套件目錄安裝，見 [02 §11](02-core-state-and-transactions.md#11-套件來源與完整性g1-core-12) |
| 雙螢幕矩陣完整驗收、完整 portal、藍牙 | G4／P1 | G1 只做指定雙螢幕、縮放與熱插拔的基礎（DES-08） |
| 效能與資源的最終收斂 | G4 | G1 量測並核定，不做最佳化衝刺 |

### 1.3 會很想做但不能做的邊界案例

這些是 G1 期間最可能被「順手做掉」的事，每一項都會違反原則或在 G2／G3 造成返工：

| 誘因 | 為什麼不行 | G1 的正確做法 |
| --- | --- | --- |
| 「hostd 啟動時讀一份 YAML 比較快，Core 之後再接」 | 違反原則 1：hostd 變成第二份權威。harness 的 `cordis-plugin-include` 正是這條路 | hostd 開機後**沒有任何條目**，直到 Core 推送。`cordis-plugin-include` 不進產品執行期（`milestones/01/02 §1`） |
| 「Shell 換 Dock 只要改 `Loader.source`，不必走交易」 | 繞過 CHG-02／04：沒有快照、沒有候選、沒有回讀 | Dock 替換是 ChangeSet，Shell 是交易參與者，見 [04 §2](04-shell-and-surfaces.md#2-ui-供應者裝載與交易參與g1-shell-13) |
| 「先讓變更直接寫資料庫，回讀之後再補」 | 系統會出現兩種可靠性等級的變更，使用者分不出來（`ditto-changeset-transaction` 刻度範例） | 從第一個宣告式設定起就走完整狀態機；沒有 `readback` 的能力不進 ChangeSet |
| 「權限先全放行，G2 接 Agent 時再收」 | G2 會在全放行的基線上疊加限制，每一個既有呼叫路徑都要回頭補 | G1 就把每項能力分級，GUI 也走同一個 `authorize()` |
| 「Agent 還沒有，AT-30 就先跳過」 | AT-30 首次通過階段是 G1 | 以 `agent` 身分的替身驗證；可主張的範圍見 [§5](#5-g1-結束時能主張與不能主張什麼) |
| 「救援模式順便支援改主題」 | 救援的能力清單刻意最小（`ditto-failure-and-rescue` 刻度範例） | 救援只做 RUN-01 的三件事，要擴充走決策程序 |
| 「每個 QML 供應者開一個 Quickshell 程序，隔離比較好」 | 違反 RUN-02 與程序預算；同程序 QML 本來就不是隔離邊界 | 所有可信 QML 供應者在同一個 Shell 程序；信任等級如實標示為「同宿主、無隔離」 |
| 「通知策略在 Shell 裡做，少一跳 IPC」 | Shell 重啟會帶走策略；AT-30 要求策略服務不依賴任何 UI | 策略在 hostd 的 Cordis 插件；Shell 只顯示 |
| 「tasks 插件自己在 `~/.local/share` 存一份 JSON」 | 插件資料的路徑由 Core 決定（`ditto-authority-boundaries` 第 3 步） | 經 `ctx.ditto.data` 寫入 Core 管理的插件資料區，移除插件時預設保留 |
| 「故障注入的鉤子留在 release build 裡，方便現場除錯」 | 等於在產品裡留一條能讓 Core 自己死掉的控制通道 | 注入點只在 `fault-injection` feature 編譯；CI 檢查 release 二進位不含注入符號 |

## 2. 開工條件與預備期

### 2.1 正式開工條件

`milestones/01/03` 規定 G1 的前置是 G0 出口，本計畫不放寬這一條。G1 的 W1 從 G0 出口評審通過的下一個工作日起算。

G0 出口的九項門檻中，與 G1 有直接依賴的是：

| G0 門檻 | G1 依賴它的工作包 | 若 G0 以「範圍或門檻變更已核定」方式出口，G1 的處理 |
| --- | --- | --- |
| EX-05（D-06a：Core／Shell PSS 預算） | G1-QA-05、EX1-10 | EX1-10 需要 G0 的分層基線當對照；沒有 D-06a，Cordis 分項的增量無法計算 |
| EX-09（nightly 三晚綠燈） | G1-QA-02／04 的 nightly 部分、EX1-15 | G1 的 nightly 套件建在同一條 workflow 上 |
| EX-08（中文輸入） | G1-SHELL-06／07／09 的文字輸入欄位、EX1-13 | 管理中心的搜尋與命名欄位要能輸入中文 |
| EX-01／03／07 的進版重跑 | 協定 0.2 升級前的回歸基準 | 升版後以 0.2 重跑，對照 0.1 的結果 |

### 2.2 預備期（G0 出口前）

在 G0 出口前，下列工作**可以**進行，且不得假設 G0 已出口。預備期的產出一律標示為預備，不計入 G1 的週序：

| 可以做 | 理由 |
| --- | --- |
| D-04、D-08、D-10、D-15、D-16、D-26、D-27 的決策準備與紀錄 | 決策不依賴 G0 門檻；D-04／D-08 的最晚時點本來就是「G1 前」 |
| G1-HOST-01 的 vendor 取用試作（在分支上，不合併） | 只驗證建置與鎖定，不接桌面 |
| G1-HOST-02 的候選策略試作（D-32 的兩個方案） | 純 Node 測試，不依賴合成器或參考機 |
| `ditto-store` 的 schema 草案與遷移框架（G1-CORE-01 的前半） | 純 Rust，不依賴 G0 門檻 |
| `docs/contracts/` 的協定 0.2 草案 | 文件工作 |

**不可以做**：任何需要在參考機上量測的工作、任何修改 G0 已驗證路徑（IPC、身分、合成器轉接、Shell 熱路徑）的合併。後者會讓 G0 的條件通過項目失去對應的來源版本。

## 3. 出口門檻

十五項，全部通過才算 G1 出口。「條件通過」只用於記錄缺口與解除時點，不等於通過。若要改變範圍或門檻，須先依決策程序核定並回寫上位文件。

每項的「證據」欄是實際路徑，出口評審時逐項核對。`artifacts/g1/` 不進版控，路徑格式固定；參考機產生的才算出口證據，開發 VM（D-25）的結果只是開發證據。

### EX1-01 手動跨插件切換與保存成立

| 欄位 | 內容 |
| --- | --- |
| 判準 | 不使用任何模型，僅以 GUI（組合中心與插件中心）完成以下腳本，每一步都有回讀一致的結果：① 以 Dock B 替換 Dock A；② 以搜尋式啟動器替換網格式啟動器；③ 布局由浮動改為基本平鋪；④ 保存為新 Profile「開發」；⑤ 複製為「簡報」並修改外觀；⑥ 比較兩者差異；⑦ 切換回「開發」。全程參考應用（Firefox／foot／Kate）零非預期終止，Kate 未儲存緩衝雜湊不變；替換後 `desktop.shortcuts.list` 與 `desktop.commands.list` **沒有重複擁有者** |
| 方法 | `tests/g1/manual-switch/run.sh` 以合成輸入驅動 GUI，同時以 `dittoctl` 回讀；另由一名非實作者照步驟人工執行一次並錄影 |
| 證據 | `artifacts/g1/manual-switch-<run_id>.jsonl`、錄影位置、每一步的 `change_id` 與 revision |
| 對應 | AT-04、AT-08（GUI 部分）、DES-09、DES-10、CFG-01／02 |
| 負責 | SHELL ＋ CORE |

### EX1-02 安裝與啟用的預檢拒絕

| 欄位 | 內容 |
| --- | --- |
| 判準 | 六個負例全部在 `validated` 之前被拒：缺少 required 依賴、依賴循環、版本不相容、單一供應者衝突、套件雜湊不符、`required_protocol_version` 不相容。每個負例結束後：① Profile head revision 不變；② 資料庫中該 Profile 的內容雜湊不變；③ hostd 與 Shell 沒有任何新掛載；④ 回報文字以產品語言說明原因，診斷區可展開看到契約 ID |
| 方法 | `tests/g1/preflight-negative/` 契約測試（PR 快檢）＋參考機上經插件中心各跑一次 |
| 證據 | CI 紀錄、`artifacts/g1/preflight-negative-<run_id>.json` |
| 對應 | AT-05、MOD-02、MOD-04 |
| 負責 | CORE |

### EX1-03 回復成立，且不可回復部分被明確列出

| 欄位 | 內容 |
| --- | --- |
| 判準 | 三個情境：① 撤銷一筆跨插件變更（Dock＋啟動器同一 ChangeSet）→ 回到基底 revision 的內容，回讀一致；② 候選健康檢查失敗 → 自動 `aborted`，現役不受影響；③ 撤銷布局變更時其中一個視窗已被關閉 → 結果為**部分完成**，逐項列出未還原的項目與原因。另有「請先撤銷較新的變更」的政策檢查：撤銷非最新的變更且與後續變更衝突時被拒 |
| 方法 | `tests/g1/rollback/run.sh` |
| 證據 | `artifacts/g1/rollback-<run_id>.jsonl`（每個情境的結果類別、逐項差異） |
| 對應 | AT-09、CHG-02～04、REC-01 |
| 負責 | CORE |

### EX1-04 清理壓力無殘留

| 欄位 | 內容 |
| --- | --- |
| 判準 | 暖機後三組各 100 次：① Dock A／B 往返替換；② tasks 服務插件停用／啟用；③ 同一 isolate realm 掛載／撤除（L-04）。每 10 次取一次快照，比對：Core 的能力綁定數、租約數、訂閱數；hostd 的 fiber 數、effect 數、`ctx.registry` 條目數；Shell 的已掛載供應者數。**首尾計數完全相同**；hostd 與 Shell 的穩態 PSS 中位數增幅 ≤10%，且 10 個快照點不呈單調成長（以 Mann-Kendall 檢定 p ≥0.05 判定「無單調趨勢」） |
| 方法 | `tests/g1/cleanup-stress/run.sh` ＋ `ditto-measure` |
| 證據 | `artifacts/g1/cleanup-stress-<run_id>.json`、計數快照、PSS 序列 |
| 對應 | AT-19、MOD-05、NFR-07 |
| 負責 | QA |

### EX1-05 無 Node 救援模式

| 欄位 | 內容 |
| --- | --- |
| 判準 | 停止 hostd 與 Agent 替身，以 `ditto-core --mode rescue` 啟動：① 參考應用可聚焦、移動、關閉請求；② 可讀取變更歷史；③ 可切回受保護的最近可用 revision；④ 依賴 Cordis 的能力在 `desktop.capabilities.list` 中標為不可用、原因為 `rescue_mode`，Shell 以產品語言顯示「待辦與通知策略暫不可用」；⑤ 程序清單中**沒有任何 Node 程序**；⑥ 恢復正常模式後 hostd 重建服務，tasks 資料完整 |
| 方法 | `tests/g1/rescue-no-node/run.sh` |
| 證據 | `artifacts/g1/rescue-no-node-<run_id>.json`（含程序清單快照） |
| 對應 | AT-23、RUN-01／02、REC-03 |
| 負責 | PLAT ＋ CORE |

### EX1-06 跨語言契約

| 欄位 | 內容 |
| --- | --- |
| 判準 | ① 協定 0.2 的共享測試向量在 Rust 與 TS 兩側編解碼一致；② 0.1 客戶端被明確拒絕（`protocol_version_unsupported`）；③ 亂序事件被偵測並觸發重新訂閱；④ 重連後以快照重建，同一 `operation_id` 不被重複提交；⑤ hostd 送出的 `on_behalf_of` 指向**未分派給它**的條目時被拒（`identity_rejected`）；⑥ 目錄一致性 gate 在約 55 項能力上全部通過 |
| 方法 | `contracts.yml` PR 快檢；`tests/g1/contract-vectors/` |
| 證據 | CI 紀錄、`schema/catalog.json` |
| 對應 | AT-27、15.5、SEC-11、CHG-05～07 |
| 負責 | CORE ＋ HOST |

### EX1-07 Cordis 服務獨立於任何客戶端存活

| 欄位 | 內容 |
| --- | --- |
| 判準 | tasks 與通知策略兩個服務啟用後：① 以 `SIGKILL` 終止 Agent 替身 → tasks 的檔案變更事件仍在 2 秒內反映到 QML 面板；通知策略仍依規則抑制通知；② 以 `SIGKILL` 終止 Shell → 重啟後的 Shell 從快照取得最新 tasks 狀態，期間的策略決定有紀錄；③ hostd 的 PID 在上述兩個步驟中不變 |
| 方法 | `tests/g1/cordis-independent/run.sh` |
| 證據 | `artifacts/g1/cordis-independent-<run_id>.json` |
| 對應 | AT-30、RUN-10、RUN-03 |
| 負責 | HOST |

### EX1-08 生命週期契約 L-01～L-10

| 欄位 | 內容 |
| --- | --- |
| 判準 | [06 §3](06-verification-and-measurement.md#3-生命週期契約測試-l-01l-10g1-qa-02) 的十項測試全部通過，每項同時通過正例與故障注入負例；其中 L-05／L-06 的「能力即時標示不可用」以時間判定：hostd 連線中斷後 **≤500 ms** 內能力轉為 `unavailable`，不等租約逾期 |
| 方法 | Vitest（`packages/host-runtime/tests/lifecycle/`）＋ Rust 整合測試 ＋ 故障注入層；PR 快檢與 nightly 各一次 |
| 證據 | CI 紀錄、`artifacts/g1/lifecycle-<run_id>.json` |
| 對應 | AT-31、AT-32、RUN-11／12、15.6 |
| 負責 | HOST ＋ QA |

### EX1-09 持久故障不破壞最近可用版本

| 欄位 | 內容 |
| --- | --- |
| 判準 | ① 在 `prepared`、`applying`、`verifying` 各以 `SIGKILL` 終止 Core 一次 → 重啟後 `desktop.changes.get` 能定位該變更，並依回讀判定為成功、失敗、部分完成或結果未知之一，**沒有任何變更停在中間狀態**；② DB 所在檔案系統寫滿時執行一次變更 → 回報空間不足、head 與受保護版本的內容雜湊不變；③ 模擬 SQLite 寫入錯誤（`SQLITE_IOERR`）→ 同 ②；④ 套件安裝在解壓途中失敗 → 暫存目錄被清除、套件庫不含半成品 |
| 方法 | `tests/g1/persistence-faults/run.sh`（使用 `fault-injection` build 與容量受限的 tmpfs） |
| 證據 | `artifacts/g1/persistence-faults-<run_id>.json` |
| 對應 | AT-20、CHG-04、REC-04／05 |
| 負責 | CORE ＋ QA |

### EX1-10 Cordis 啟用、Agent 不存在的分層資源基線

| 欄位 | 內容 |
| --- | --- |
| 判準 | 依 19.1 流程（冷登入、暖機 300 秒、採樣 600 秒、重複 3 次）量測四組狀態：① 無 Node 救援模式；② 完整桌面（Cordis 常駐、Agent 不存在）；③ ② ＋ 10 個簡單插件（D-34 的固定集合）A/B；④ 角色關閉。報告含 Core／Shell／hostd／合成器分項、完整程序清單、排除清單、版本指紋。hostd ≤100 MiB、10 插件增量 ≤50 MiB、全桌面 ≤600 MiB **達標**，或調整提案**已在出口評審前核定** |
| 方法 | [06 §7](06-verification-and-measurement.md#7-分層資源量測g1-qa-05) |
| 證據 | `artifacts/g1/resource-report-<run_id>.md` ×3 ＋ 決策紀錄（若有調整） |
| 對應 | NFR-06、NFR-14、NFR-15、19.1、RUN-08 |
| 負責 | QA ＋全體核定 |
| 未達標 | 先分析來源（實作／量測方法／目標本身）；**不得**把 hostd 或 Ditto 新增服務移出統計範圍、不得改暖機或採樣條件 |

### EX1-11 本機操作、插件切換與應用存活

| 欄位 | 內容 |
| --- | --- |
| 判準 | ① NFR-03：簡單本機操作（切換工作區、聚焦視窗、改一個外觀 token）受理到回讀完成 p95 ≤100 ms，200 次；② NFR-04：已安裝 UI 插件切換（Dock A↔B）`prepared`→`committed` p95 ≤2 秒，100 次，另列 Cordis 服務插件替換的數字；③ NFR-09：上述 300 次操作期間參考應用零非預期終止、Kate 未儲存緩衝雜湊不變。達標，或調整提案已在出口評審前核定 |
| 方法 | `tests/g1/latency/run.sh`；時間戳取 Core 的受理與提交事件，不取 UI 估計 |
| 證據 | `artifacts/g1/latency-<run_id>.jsonl` |
| 對應 | NFR-03、NFR-04、NFR-09 |
| 負責 | QA |

### EX1-12 救援、監督與鎖定

| 欄位 | 內容 |
| --- | --- |
| 判準 | ① Shell 以 `SIGSTOP` 阻塞 → **10 秒內**出現可操作的救援介面，且參考應用與未儲存內容保留（NFR-08）；② 故障插件連續崩潰達門檻後被停用，停用原因與重新啟用入口可在插件中心與 `dittoctl` 查到，且不再重啟；③ Core 重啟風暴觸發 `OnFailure` 後救援介面可用；④ 鎖定時以 `SIGKILL` 終止鎖定客戶端與 Shell → 工作階段**保持鎖定**、不暴露桌面內容，重新輸入密碼可解鎖；⑤ 鎖定期間替換 Dock 的 ChangeSet 被拒或延後，不改變鎖定表面 |
| 方法 | `tests/g1/rescue-supervision/run.sh`、`tests/g1/lock/run.sh`（④ 另需人工實體確認一次並錄影） |
| 證據 | `artifacts/g1/rescue-supervision-<run_id>.json`、`artifacts/g1/lock-<run_id>.json`、錄影位置 |
| 對應 | AT-16、AT-17、REC-02／03、NFR-08、SEC-08、DES-06 |
| 負責 | PLAT ＋ SHELL |

### EX1-13 桌面基本面完整

| 欄位 | 內容 |
| --- | --- |
| 判準 | ① 應用搜尋、鍵盤選擇、啟動與執行中視窗列表（DES-02）；② 至少兩工作區與浮動／平鋪兩種布局，布局策略經 ChangeSet 替換（DES-04）；③ 通知、快捷鍵、音量與網路狀態顯示，詳細設定啟動既有工具（DES-05）；④ 繁中／英文切換後所有 Ditto 自有字串改變，無遺漏的寫死字串（以 lint 檢查 `qsTr` 覆蓋率）；中文輸入在管理中心的文字欄位可用；文字剪貼簿與預設應用開檔（DES-07）；⑤ 指定雙螢幕：拔除第二螢幕後視窗與角色回到可見範圍（DES-08）；⑥ 角色點擊、遮擋、快捷鍵喚回、隱藏（AT-12 的 G1 基礎） |
| 方法 | `tests/g1/desktop-basics/run.sh` ＋ `tests/g1/output-hotplug/run.sh`（需第二螢幕）＋人工檢查清單 |
| 證據 | 對應 artifacts ＋ [06 §8](06-verification-and-measurement.md#8-人工驗收清單) 的簽核表 |
| 對應 | AT-01（完整）、AT-12、AT-13（G1 基礎部分）、DES-02／04／05／07／08 |
| 負責 | SHELL ＋ PLAT |

### EX1-14 沿用對照表、移植紀錄與來源守門

| 欄位 | 內容 |
| --- | --- |
| 判準 | ① `docs/upstream/cordis-port.md` 逐套件記錄 `upstream_commit`、`port_kind`、修改集、宿主契約、授權、測試矩陣（`milestones/01/02 §5` 的七欄）；② `milestones/01/02 §2` 的沿用對照表以實際實作更新並附檔案位置；③ `scripts/check-vendor-manifest.sh` 在 CI 中執行，且有一次故意違規被擋下的紀錄；④ 授權清單包含全部 vendored 套件與新增的 Rust／npm 依賴 |
| 方法 | 文件審查 ＋ CI 紀錄 |
| 證據 | 上述文件、CI 紀錄、`licenses.yml` 產物 |
| 對應 | 15.6、24.1、`ditto-upstream-port` |
| 負責 | HOST |

### EX1-15 G1 套件進入 CI 與 nightly

| 欄位 | 內容 |
| --- | --- |
| 判準 | ① PR 快檢包含：協定 0.2 契約、目錄一致性、L-01～L-10、預檢負例、store 遷移測試，全部阻擋合併；② nightly 在參考機上跑 EX1-01／03／07／09 的腳本，**連續 5 個晚上**成功並保存 artifacts；③ `vm-regression.yml` 涵蓋 G1 的非圖形套件 |
| 方法 | CI 歷史紀錄 |
| 證據 | 5 次 nightly 執行紀錄 |
| 對應 | `milestones/01/04 §3～4` |
| 負責 | QA ＋ PLAT |

## 4. 與 milestones/01 出口門檻的對應

| milestones/01 的 G1 門檻 | 本計畫 | 關係 |
| --- | --- | --- |
| 手動跨插件切換與回復成立 | EX1-01、EX1-03 | 加嚴：固定七步腳本、回讀與無重複擁有者 |
| AT-04／05／08／09 | EX1-01、02、03 | 加嚴：AT-05 擴為六個負例並檢查內容雜湊 |
| AT-19、NFR-07 | EX1-04 | 加嚴：三組壓力與趨勢檢定 |
| AT-23、AT-27 | EX1-05、06 | 加嚴：程序清單中無 Node；`on_behalf_of` 偽造負例 |
| AT-30、31、32 | EX1-07、08 | 加嚴：不可用轉換 ≤500 ms；每項測試附負例 |
| 資源基線符合預算或附數據調整 | EX1-10 | 加嚴：調整提案須在評審前核定 |
| 沿用對照表與移植紀錄 | EX1-14 | 加嚴：vendor 守門須有一次實際擋下紀錄 |
| （無，04 標為 G1） | EX1-09、EX1-12、EX1-13 | 增補：AT-16／17／20、AT-01 完整、AT-12／13 基礎（F-1） |
| （無，04 標為 G1 量測） | EX1-11 | 增補：NFR-03／04／09 |
| （無） | EX1-15 | 增補：CI 與 nightly |

## 5. G1 結束時能主張與不能主張什麼

`ditto-prose-standard` 與 `ditto-verification-evidence` 對這件事有明確要求。G1 的成果很容易被寫成比實際更完整的樣子：

| 可以說 | 不可以說 |
| --- | --- |
| 「不使用模型，Ditto 可以在參考平台上以 GUI 替換 Dock、啟動器與布局，保存、比較並撤銷」 | 「Ditto 可以用對話改造桌面」——那是 G2 |
| 「兩個 Cordis 服務在 Agent 替身與 Shell 被終止後照常運作」 | 「AT-30 已通過且對 Agent 成立」——G1 驗的是替身；真實 Agent 的回歸在 G2-QA-04 |
| 「GUI 的所有能力呼叫都經過同一個授權入口，沒有應答者時一律拒絕」 | 「權限模型已完成」——應答者、上下文分級與 GUI／Agent 一致性（AT-14）在 G2 |
| 「hostd 在參考機的 PSS 為 X MiB（冷登入、3 次、p95）」 | 「全桌面符合 750 MiB」——Agent 暖態在 G2 才量得到 |
| 「救援模式不依賴 Node，提供三項基本能力」 | 「救援模式可以處理所有故障」——它刻意只保證 RUN-01 的三件事 |
| 「插件中心顯示 hostd 的程序層級資源」 | 「插件中心顯示每個插件的記憶體」——同程序插件無法獨立計量（RUN-08） |
| 「可從本機套件目錄安裝經雜湊校驗的插件」 | 「支援核可來源安裝」——網路來源依 D-10 決定，G1 未交付 |
| 「生命週期契約測試 L-01～L-10 通過」 | 「Cordis 宿主已經沒有殘留問題」——測試覆蓋的是十個情境，不是所有情境 |

同一條規則適用於 README、PR 描述與任何對外說明。
