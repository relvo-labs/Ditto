# 07｜工作包、週序、里程碑與估算

> 54 個工作包的執行細節與時序。工作包狀態只在本文 §8 更新，不散落到其他文件。
>
> 週序以 18 週排定（`milestones/01` 建議工期 14–18 週的上緣），W1 為 G0 出口評審通過後的第一週。人力是否足以在 18 週內完成，見 §5：**以 `milestones/01/05` 的建議人力，18 週做不完 124 人週，更做不完 140.5 人週**，這件事要在開工前由 D-31 裁決。

## 1. 工作包總表

「前置」欄使用簡寫：C＝CORE、H＝HOST、S＝SHELL、P＝PLAT、Q＝QA，後接編號；D-xx 為決策。「里程碑」是該工作包必須完成的最晚里程碑（§3）。

### 1.1 CORE（47 人週）

| ID | 名稱 | 前置 | 人週 | 里程碑 | 出口證據 |
| --- | --- | --- | --- | --- | --- |
| G1-CORE-16 | Core 執行緒與儲存架構 | D-26 | 2 | M1 | 協調器＋唯讀連線池骨架；watchdog 接在協調器迴圈 |
| G1-CORE-01 | 持久層與遷移 | C-16、D-15 | 4 | M1 | `ditto-store` 12 張表、遷移測試、不可變 trigger |
| G1-CORE-02 | Profile 與 revision | C-01 | 3.5 | M1 | ProfileDocument schema、JCS 雜湊、受保護版本、保留策略 |
| G1-CORE-15 | 協定 0.2 與能力目錄擴充 | C-16 | 2 | M3 | `PROTOCOL_VERSION=0.2.0`、約 55 項能力、目錄 gate 全綠 |
| G1-CORE-03 | ChangeSet 狀態機 | C-02 | 4.5 | M1 | 11 個狀態、先寫紀錄再做副作用、冪等鍵、序列化 |
| G1-CORE-04 | 確定性預檢 | C-03 | 2.5 | M2 | 13 項檢查、封閉原因碼、EX1-02 負例 |
| G1-CORE-07 | 熱換執行器與參與者協定 | C-03 | 3 | M2 | `participant.*` 五個方法、四等級步驟、逾時 |
| G1-CORE-08 | 回讀、提交與限時回復 | C-07 | 2.5 | M2 | readback 比對規則、`pending_confirmation`、15 秒倒數在 Core |
| G1-CORE-05 | 能力路由 | C-15 | 3 | M3 | `hostd:<entry>` 路由、租約檢查、Core 自行 readback |
| G1-CORE-06 | 權限模型 | C-05 | 3.5 | M3 | 單一 `authorize()`、scope 分級、撤銷、`approval_unavailable` 失敗即拒絕 |
| G1-CORE-10 | 宿主監督 | H-03、C-07 | 2.5 | M4 | 啟動、心跳、退避、風暴、entry 停用 |
| G1-CORE-11 | 崩潰恢復 | C-07、C-10 | 2.5 | M4 | 開機恢復流程；EX1-09 ① |
| G1-CORE-12 | 套件來源與完整性 | C-01、H-09 | 2.5 | M4 | `.dittopkg`、sha256、安裝與啟用分開；EX1-09 ④ |
| G1-CORE-09 | 匯出與匯入 | C-02、C-12 | 2 | M4 | 匯出不含秘密與私人路徑；匯入先驗證 |
| G1-CORE-13 | 日誌與診斷 | C-03 | 2 | M4 | 三個 id 串聯、遮蔽負例、REC-07 集合 |
| G1-CORE-14 | 資源配額施加 | C-10 | 2 | M4 | D-06b 三類配額；施加失敗即拒絕啟動 |
| G1-CORE-17 | `ditto-system` | C-16、D-28 | 3 | M3 | 桌面項目索引、通知伺服端、logind |

### 1.2 HOST（27 人週）

| ID | 名稱 | 前置 | 人週 | 里程碑 | 出口證據 |
| --- | --- | --- | --- | --- | --- |
| G1-HOST-01 | vendored Cordis 引入 | D-04 | 1.5 | M1 | 建置通過、鎖定表、修改集、`FiberState` 鏡像測試 |
| G1-HOST-12 | vendor 守門與移植紀錄 | H-01 | 1 | M1 | `check-vendor-manifest.sh` 在 CI；一次擋下紀錄 |
| G1-HOST-02 | 交易層 `ditto-host-loader` | H-01、C-07、D-32 | 5 | M2 | prepare／commit／abort／rollback；L-02／03／08 |
| G1-HOST-03 | 能力註冊代理與租約 | H-02、C-05 | 3 | M2 | 批次續約、逾期撤銷、generation；L-07 |
| G1-HOST-05 | 健康檢查與交接 | H-02 | 2.5 | M2 | health、drain、export／import |
| G1-HOST-04 | 事件橋 | H-03 | 2 | M2 | `seq`、合併政策、溢位即 resync |
| G1-HOST-09 | Manifest 完整語意 | C-04 | 2 | M2 | `schema/manifest.json`、強制與記錄欄位 |
| G1-HOST-06 | 服務插件 ① tasks | H-03、H-04、C-06 | 2.5 | M3 | 檔案授予、監看、事件、QML 面板 |
| G1-HOST-07 | 服務插件 ② 通知策略 | H-06、C-17 | 2 | M4 | 四條規則、volatile 熱更新、決策紀錄 |
| G1-HOST-08 | `host-sdk` | H-02、H-09 | 3 | M4 | `createTestHost()`、validate、pack、範例 |
| G1-HOST-10 | 宿主資源回報 | H-03 | 1 | M4 | 三欄 Node 數字、每 entry 計數、無每插件記憶體 |
| G1-HOST-11 | 宿主回收政策 | C-10 | 1.5 | M4 | 四條件回收、30 秒內回收與重建 |

### 1.3 SHELL（34.5 人週）

| ID | 名稱 | 前置 | 人週 | 里程碑 | 出口證據 |
| --- | --- | --- | --- | --- | --- |
| G1-SHELL-01 | 柔光果凍 token | C-02 | 2 | M2 | 完整 token、兩組替代值、低效能樣式 |
| G1-SHELL-13 | 供應者裝載與交易參與 | C-07 | 2.5 | M2 | ProviderHost、參與者方法、掛載回報 |
| G1-SHELL-03 | 兩個 Dock ＋兩個啟動器 | S-13、C-17 | 5 | M3 | 四個供應者、100 次替換無殘留 |
| G1-SHELL-02 | 桌面表面 | S-13、P-05 | 3 | M3 | 工作區格線、布局策略入口、角色位置 |
| G1-SHELL-04 | 應用搜尋與啟動 | C-17、S-03 | 2 | M3 | 鍵盤選擇、`launcher.launch`、執行中視窗 |
| G1-SHELL-10 | 變更卡與試看 | C-08 | 2 | M3 | 原型三態、真實狀態文字 |
| G1-SHELL-06 | 組合中心 | S-10、C-02 | 4 | M4 | 七項功能；匯入先驗證 |
| G1-SHELL-07 | 插件中心 | H-10、C-06 | 3 | M4 | MOD-01／RUN-08 欄位；權限授予與撤銷 |
| G1-SHELL-08 | 變更歷史 | S-10、C-11 | 2.5 | M4 | 四種結果類別的呈現；逐步撤銷 |
| G1-SHELL-09 | 個人化設定 | S-01、P-05 | 2.5 | M4 | 外觀、快捷鍵、角色、動畫、語言、無障礙 |
| G1-SHELL-05 | 通知、快捷鍵、音量、網路 | C-17、H-07 | 3 | M4 | 通知區；W1 探測結果落地 |
| G1-SHELL-11 | 鎖定、登出、電源 | C-17、P-05（C-19）、D-30 | 1.5 | M4 | 獨立鎖定客戶端；EX1-12 ④ |
| G1-SHELL-12 | i18n、剪貼簿、開檔 | S-06～09 | 1.5 | M4 | `qsTr` 覆蓋 lint、兩份 `.qm` |

### 1.4 PLAT（12 人週）

| ID | 名稱 | 前置 | 人週 | 里程碑 | 出口證據 |
| --- | --- | --- | --- | --- | --- |
| G1-PLAT-05 | 布局策略與快捷鍵的 Wayfire 路徑 | —（W1 探測） | 2 | M2 | C-15～C-19 探測結果；兩個策略供應者 |
| G1-PLAT-02 | systemd user unit | C-16 | 2 | M2 | 四個 unit、`Type=notify`、`OnFailure` |
| G1-PLAT-01 | 雙螢幕、縮放、熱插拔 | P-05（C-17／18）、第二螢幕 | 3 | M4 | 熱插拔後視窗與角色可見 |
| G1-PLAT-03 | `dittoctl` 救援與救援介面 | C-11、P-02、D-29 | 2.5 | M4 | 六個子命令、離線模式、`shell/rescue/` |
| G1-PLAT-04 | 無 Node 救援模式 | C-10、P-03 | 2.5 | M4 | EX1-05 |

### 1.5 QA（20 人週）

| ID | 名稱 | 前置 | 人週 | 里程碑 | 出口證據 |
| --- | --- | --- | --- | --- | --- |
| G1-QA-01 | 跨語言契約 | C-15 | 2.5 | M3 | 0.2 向量、雙語言 runner |
| G1-QA-04 | 故障注入框架 | C-03、H-02 | 4 | M3 | 四種注入點；release 無注入點檢查 |
| G1-QA-02 | 生命週期 L-01～L-10 | H-02、H-03、Q-04 | 4.5 | M4 | 十項正例＋負例 |
| G1-QA-07 | AT-16／17／20 腳本與 Agent 替身 | Q-04、P-03 | 2 | M4 | 替身、三組腳本 |
| G1-QA-03 | 清理壓力 | S-13、H-02 | 2.5 | M5 | EX1-04 |
| G1-QA-06 | NFR-03／04／09 量測 | S-03、C-08 | 2 | M5 | EX1-11 |
| G1-QA-05 | 分層資源量測 | G0 D-06a、D-34 | 2.5 | M5 | EX1-10 |

合計 **140.5 人週**。與 `milestones/01` 的差異見 [README §4](README.md#4-對-milestones01-的增補加嚴與回饋登記)。

## 2. 逐包執行細節

格式：**目的｜關鍵步驟｜完成判準｜必讀 skill**。步驟只列影響順序或判斷的關鍵步。設計判準在 02～06，本節不重述。

### CORE

**G1-CORE-16 執行緒與儲存架構** — 目的：在寫任何交易邏輯前定下並行模型。步驟：① D-26 核定；② 協調器執行緒與命令佇列；③ 唯讀連線池；④ 計時器執行緒；⑤ `sd_notify` 與 watchdog 接在協調器迴圈。判準：假參與者下跑 1,000 筆併發 propose，無資料競爭（`cargo test` ＋ loom 或壓力測試），提交嚴格序列化。skill：`ditto-process-budget`、`ditto-changeset-transaction`。

**G1-CORE-01 持久層** — 目的：權威資料的唯一落點。步驟：① 12 張表與預留表；② trigger（revision 不可變、狀態轉移合法）；③ 遷移框架與備份；④ `quick_check` 與救援轉入；⑤ `.partial` 清理；⑥ `ditto-store` 對 `dittoctl` 開放的離線 API。判準：[02 §3](02-core-state-and-transactions.md#3-儲存層g1-core-01) 的不變量各有測試；ENOSPC 測試通過。skill：`ditto-authority-boundaries`。

**G1-CORE-02 Profile 與 revision** — 目的：可比較、可追溯、不可變的組合版本。步驟：① ProfileDocument 的 Rust 型別與 schema；② JCS 正規化與雜湊；③ 七項操作；④ 受保護版本的觀察期；⑤ 保留策略背景工作；⑥ 預設組合 `soft-jelly` 的初始文件。判準：同內容不同鍵序的雜湊相同；保留策略不刪除受保護鏈與被引用套件。skill：`ditto-authority-boundaries`。

**G1-CORE-15 協定 0.2 與能力目錄** — 目的：讓新能力一出現就受 gate 約束。步驟：① `PROTOCOL_VERSION` 與錯誤集；② `ResultMeta` 拆欄位；③ 逐群組加描述子；④ gate 增加 `resource_scope` 非空；⑤ Shell、`dittoctl`、TS client 同一 PR 升版；⑥ `docs/contracts/protocol-0.2.md`。判準：EX1-06 ①②⑥。skill：`ditto-capability-contract`。

**G1-CORE-03 ChangeSet 狀態機** — 目的：所有寫入的單一路徑。步驟：① 型別；② 狀態與終態；③ 先寫紀錄再做副作用；④ 冪等鍵；⑤ 基底 revision 雙重檢查（validated 與進入 prepared 前）；⑥ diff 產生（翻譯鍵）；⑦ 以假參與者跑完整路徑。判準：非法轉移被 trigger 擋下；同鍵重送回傳既有 change。skill：`ditto-changeset-transaction`。

**G1-CORE-04 預檢** — 目的：在任何副作用之前擋下可預知的失敗。步驟：13 項依序；一次回報全部原因；原因碼封閉。判準：每項至少一個負例；EX1-02 六個負例後內容雜湊不變。skill：`ditto-changeset-transaction`。

**G1-CORE-07 熱換執行器** — 目的：一套執行器服務所有參與者。步驟：① `participant.*` 協定與逾時；② 四等級的步驟表；③ 等級推導（宣告值與推導值取高）；④ 工作階段重啟等級只排程不執行。判準：假參與者下四等級各有正例與逾時負例。skill：`ditto-changeset-transaction`。

**G1-CORE-08 回讀與限時回復** — 目的：成功只能由回讀證明。步驟：① 每種 op 的比對規則；② 提交寫 revision 與移 head 同一交易；③ `pending_confirmation` 與倒數；④ `changes.get` 以 `operation_id` 查詢。判準：注入「呼叫成功但回讀不一致」→ 回復；Shell 死於倒數中 → 仍自動回復。skill：`ditto-changeset-transaction`。

**G1-CORE-05 能力路由** — 目的：跨宿主能力與本機能力走同一個入口。步驟：① provider 種類；② 租約檢查；③ 轉送攜帶原始身分；④ Core 自行 readback。判準：租約逾期的能力回 `unavailable`；provider 自報 `readback_verified` 被忽略。skill：`ditto-capability-contract`。

**G1-CORE-06 權限** — 目的：G2 之前就有一個誠實的授權入口。步驟：① 主體；② scope 分級填入全部能力；③ `authorize()`；④ 授予表；⑤ 撤銷（含訂閱與 hostd 通知）；⑥ audit。判準：決策表測試；`approval_unavailable` 為拒絕；偽造 `on_behalf_of` 被拒。skill：`ditto-permission-and-secrets`。

**G1-CORE-10 宿主監督** — 目的：hostd 的存活由 Profile 決定。步驟：[02 §12](02-core-state-and-transactions.md#12-宿主監督g1-core-10) 的六列。判準：不可用轉換 ≤500 ms；風暴後停止重啟；entry 連續失敗被停用。skill：`ditto-failure-and-rescue`。

**G1-CORE-11 崩潰恢復** — 目的：沒有永遠停在中間的變更。步驟：[02 §13](02-core-state-and-transactions.md#13-崩潰恢復g1-core-11) 的五步。判準：EX1-09 ①。skill：`ditto-failure-and-rescue`。

**G1-CORE-12 套件來源** — 目的：可驗證地安裝本機插件。步驟：格式、暫存、校驗、rename、紀錄；安裝與啟用分開。判準：EX1-02（雜湊負例）、EX1-09 ④。skill：`ditto-upstream-port`、`ditto-release-audit`。

**G1-CORE-09 匯出與匯入** — 目的：組合可攜，但不帶秘密與私人內容。步驟：① 匯出 = ProfileDocument ＋套件鎖定 ＋ schema 版本，排除 `path_grant` 的實際路徑與插件資料；② 匯入先驗證來源、平台、版本、能力、缺失授予，**不執行程式碼**；③ 匯出掃描（秘密樣式、家目錄路徑）。判準：含檔案授予的組合匯出後不含路徑；匯入缺套件時列出缺失項。skill：`ditto-permission-and-secrets`。

**G1-CORE-13 日誌與診斷** — 目的：任何失敗都能從結果追到日誌。步驟：結構化欄位、遮蔽層與負例、診斷集合。判準：故意把視窗標題寫進日誌的測試被遮蔽。skill：`ditto-failure-and-rescue`。

**G1-CORE-14 資源配額** — 目的：配額真的施加在程序上。步驟：D-06b 三類；施加失敗即拒絕。判準：hostd 的 scope 屬性回讀與設定一致；user manager 不可用時 hostd 不啟動並回報。skill：`ditto-process-budget`。

**G1-CORE-17 `ditto-system`** — 目的：系統整合集中在 Core 側。步驟：① 桌面項目索引與 inotify；② 應用啟動（scope＋activation token）；③ 通知伺服端與策略詢問；④ logind。判準：Shell 重啟期間送出的通知不遺失；啟動的應用不是任何 Ditto 程序的子程序。skill：`ditto-authority-boundaries`、`ditto-process-budget`。

### HOST

**G1-HOST-01 vendored Cordis** — 目的：鎖定、可建置、可追溯。步驟：[03 §2](03-host-and-cordis.md#2-cordis-取用g1-host-01)。判準：`pnpm -r build` 通過；釘選測試通過。skill：`ditto-upstream-port`。

**G1-HOST-12 vendor 守門** — 目的：來源義務不靠 review。步驟：腳本、CI、`docs/upstream/cordis-port.md` 初版。判準：一個故意只改 vendor 原始碼的 PR 被擋下（保留 CI 紀錄）。skill：`ditto-upstream-port`。

**G1-HOST-02 交易層** — 目的：在非交易式 loader 之上建立交易語意。步驟：① D-32 的預先承諾判準寫進決策紀錄；② 試作策略 A 並量測；③ 依判準定案；④ 獨占資源延後；⑤ abort 等待整棵 dispose；⑥ `participant.state`。判準：L-02、L-03、L-08 正負例通過。skill：`ditto-cordis-plugin`、`ditto-changeset-transaction`。

**G1-HOST-03 租約** — 目的：跨宿主註冊有擁有者與期限。步驟：register 驗證 manifest `provides`；TTL 10 秒、每 3 秒批次續約；revoke 為 effect disposer；generation。判準：L-07。skill：`ditto-cordis-plugin`。

**G1-HOST-05 健康檢查與交接** — 目的：受控交接真的交接。步驟：[03 §5](03-host-and-cordis.md#5-健康檢查與交接g1-host-05)。判準：tasks 替換時未寫出的變更經 export／import 保留。skill：`ditto-cordis-plugin`。

**G1-HOST-04 事件橋** — 目的：Cordis 事件與 RPC 事件流之間語意不走樣。步驟：manifest 宣告、hostd 佇列與合併政策、Core broker 對接。判準：溢位時訂閱者收到 `resync_required`，不靜默丟失。skill：`ditto-cordis-plugin`。

**G1-HOST-09 Manifest** — 目的：12 節的必要語意全部有落點。步驟：[03 §9](03-host-and-cordis.md#9-manifest-完整語意g1-host-09)。判準：每個強制欄位至少一個預檢或執行期測試。skill：`ditto-capability-contract`。

**G1-HOST-06 tasks** — 目的：第一個真的在跑的 Cordis 服務。步驟：[03 §6](03-host-and-cordis.md#6-服務插件-任務待辦資料服務g1-host-06)。判準：外部編輯器改檔 2 秒內面板更新；撤銷授予後停止監看。skill：`ditto-cordis-plugin`。

**G1-HOST-07 通知策略** — 目的：第二個服務，事件驅動且不依賴 UI。步驟：[03 §7](03-host-and-cordis.md#7-服務插件-通知策略服務g1-host-07)。判準：`notify-send` 連發 5 則同應用通知 → 合併；改規則不重掛插件。skill：`ditto-cordis-plugin`。

**G1-HOST-08 host-sdk** — 目的：非 Runtime 作者寫得出插件（G4 的 SDK 可用性測試以此為起點）。步驟：[03 §8](03-host-and-cordis.md#8-host-sdkg1-host-08)。判準：範例插件以 `createTestHost()` 通過 L-01／03／04／08。skill：`ditto-cordis-plugin`。

**G1-HOST-10 資源回報** — 目的：RUN-08 誠實呈現。步驟：[03 §10](03-host-and-cordis.md#10-資源回報g1-host-10)。判準：插件中心沒有任何每插件記憶體數字。skill：`ditto-process-budget`。

**G1-HOST-11 回收政策** — 目的：hostd 不套用 Agent 閒置規則，但也不永遠常駐。步驟：四條件；回收與重建測試。判準：停用兩個服務 30 秒內回收；重新啟用後重建。skill：`ditto-process-budget`。

### SHELL

**G1-SHELL-01 token** — 目的：外觀全部由 Profile 驅動。步驟：[04 §3](04-shell-and-surfaces.md#3-柔光果凍-tokeng1-shell-01)。判準：改 accent 的 ChangeSet 回讀一致；兩組替代值逐畫面檢查（M-09）。skill：`ditto-qml-shell`。

**G1-SHELL-13 供應者裝載** — 目的：UI 替換是交易。步驟：[04 §2](04-shell-and-surfaces.md#2-ui-供應者裝載與交易參與g1-shell-13)。判準：[04 §11](04-shell-and-surfaces.md#11-驗證清單) 第 1～3 項。skill：`ditto-qml-shell`、`ditto-changeset-transaction`。

**G1-SHELL-03 Dock 與啟動器** — 目的：DES-10 的可替換性證明。步驟：四個供應者；遷移或保留設定。判準：EX1-01 ①②。skill：`ditto-qml-shell`。

**G1-SHELL-02 桌面表面** — 目的：DES-04。步驟：[04 §4](04-shell-and-surfaces.md#4-桌面表面g1-shell-02)。判準：EX1-13 ②。skill：`ditto-qml-shell`。

**G1-SHELL-04 應用搜尋與啟動** — 目的：DES-02。判準：EX1-13 ①。skill：`ditto-qml-shell`。

**G1-SHELL-10 變更卡** — 目的：原型契約落地。判準：七種狀態文字對應真實 ChangeSet 狀態。skill：`ditto-prose-standard`。

**G1-SHELL-06～09 四個中心** — 目的與判準見 [04 §7](04-shell-and-surfaces.md#7-四個管理中心g1-shell-0609)；人工驗收 M-02、M-03、M-06。skill：`ditto-qml-shell`、`ditto-prose-standard`。

**G1-SHELL-05 通知、快捷鍵、音量、網路** — W1 先探測 Quickshell 整合（[04 §6](04-shell-and-surfaces.md#6-通知快捷鍵音量與網路g1-shell-05)）。判準：EX1-13 ③。skill：`ditto-qml-shell`。

**G1-SHELL-11 鎖定、登出、電源** — 步驟：[04 §8](04-shell-and-surfaces.md#8-變更卡鎖定登出與電源g1-shell-10shell-11)。判準：EX1-12 ④⑤。skill：`ditto-permission-and-secrets`、`ditto-qml-shell`。

**G1-SHELL-12 i18n** — 判準：EX1-13 ④；`shell-i18n.yml` 綠燈。skill：`ditto-prose-standard`。

### PLAT

**G1-PLAT-05 Wayfire 路徑** — 目的：先查清楚布局與快捷鍵能不能執行期變更。步驟：W1–W2 探測 C-15～C-19，寫入差異表；W3 依結果決定處理方式（G1-R4）；實作兩個策略供應者與快捷鍵綁定。判準：差異表新列有探針輸出；策略切換有回讀。skill：`ditto-verification-evidence`、`ditto-capability-contract`。

**G1-PLAT-02 systemd user unit** — 步驟：[05 §2](05-platform-supervision-and-rescue.md#2-systemd-user-unitg1-plat-02)；登入 script 改名與移除 `measure-variant` 檔讀取。判準：Core 被 `SIGKILL` 後 1 秒內重啟；第 6 次失敗觸發 `OnFailure`。skill：`ditto-failure-and-rescue`。

**G1-PLAT-01 雙螢幕** — W1 取得第二螢幕。判準：EX1-13 ⑤、M-08。skill：`ditto-verification-evidence`。

**G1-PLAT-03 救援** — 步驟：[05 §3～4](05-platform-supervision-and-rescue.md#3-救援介面g1-plat-03-的-ui-部分d-29)。判準：EX1-12 ①③。skill：`ditto-failure-and-rescue`。

**G1-PLAT-04 無 Node 救援** — 步驟：[05 §5](05-platform-supervision-and-rescue.md#5-無-node-救援模式g1-plat-04)。判準：EX1-05。完成後依 plan/01/05 的 W2-02 核對 `ditto-failure-and-rescue` 第 3 步並提出轉 stable。skill：`ditto-failure-and-rescue`。

### QA

**G1-QA-01 契約** — [06 §2](06-verification-and-measurement.md#2-跨語言契約g1-qa-01)。判準：EX1-06。
**G1-QA-04 故障注入** — [06 §4](06-verification-and-measurement.md#4-故障注入框架g1-qa-04)。判準：四種注入點各有一個示範測試；release 檢查在 CI。
**G1-QA-02 生命週期** — [06 §3](06-verification-and-measurement.md#3-生命週期契約測試-l-01l-10g1-qa-02)。判準：EX1-08。
**G1-QA-07 替身與 AT-16／17／20** — [06 §9](06-verification-and-measurement.md#9-agent-替身g1-qa-07)。判準：EX1-07、09、12 的腳本可在 nightly 執行。
**G1-QA-03 清理壓力** — [06 §5](06-verification-and-measurement.md#5-清理壓力g1-qa-03)。判準：EX1-04。
**G1-QA-06 延遲** — [06 §6](06-verification-and-measurement.md#6-延遲與存活g1-qa-06)。判準：EX1-11。
**G1-QA-05 資源** — [06 §7](06-verification-and-measurement.md#7-分層資源量測g1-qa-05)。判準：EX1-10。

QA 工作包的必讀 skill 一律是 `ditto-verification-evidence`，並依內容併讀 `ditto-failure-and-rescue` 或 `ditto-process-budget`。

## 3. 里程碑、關鍵路徑與並行

### 3.1 五個內部里程碑

里程碑不是出口門檻，是**週檢查點上可以被驗證的狀態**。每個里程碑都有一段可示範的端到端流程；示範失敗代表關鍵路徑延遲，不代表可以跳過。

| 里程碑 | 週 | 可示範的狀態 | 必須完成的工作包 |
| --- | --- | --- | --- |
| **M0 開工** | W1 首日 | G0 已出口；D-04、D-08、D-10、D-15、D-26、D-27 已核定；D-32 的判準已寫定；各工作流 owner 已指派 | 決策與管理 |
| **M1 骨幹** | W4 末 | `dittoctl` 送出「把 accent 改成紫色」→ Core 預檢、提交 revision → Shell 回讀一致 → 撤銷回到上一版；Core 重啟後歷史仍在 | C-16、C-01、C-02、C-03、H-01、H-12 |
| **M2 交易式替換** | W8 末 | 以 `dittoctl` 把 Dock A 換成 B：候選隱藏載入、commit、回讀；故障夾具讓候選失敗 → 現役不受影響。hostd 由 Core 啟動，tasks 服務的前身（計數器範例）以租約發布能力；L-02／03／07／08 通過 | C-04、C-07、C-08、H-02、H-03、H-04、H-05、H-09、S-01、S-13、P-02、P-05 |
| **M3 G2 可開工點** | W11 末 | 見 §4。另：兩個 Dock 與兩個啟動器可替換；tasks 服務在真實檔案上運作並顯示於面板；協定 0.2 契約向量綠燈 | C-05、C-06、C-15、C-17、H-06、S-02、S-03、S-04、S-10、Q-01、Q-04 |
| **M4 功能完整** | W14 末 | 四個管理中心、通知策略、救援、監督、崩潰恢復、套件安裝、匯出匯入、鎖定、雙螢幕全部可用；L-01～L-10 通過；**W15 起功能凍結** | 其餘全部，Q-03／05／06 除外 |
| **M5 收斂與出口** | W16–W18 | 清理壓力、延遲、3 次冷登入資源量測、5 晚 nightly、人工驗收、出口評審 | Q-03、Q-05、Q-06 ＋全部門檻 |

### 3.2 關鍵路徑

```
D-26 ─► C-16 ─► C-01 ─► C-02 ─► C-03 ─► C-07 ─┬─► H-02 ─► H-03 ─► H-06 ─► C-10 ─► C-11 ─► Q-07 ─► EX1-09
                                                │     ▲
D-04 ─► H-01 ────────────────────────────────── ┘     │
D-32（判準 W0，定案 W3）───────────────────────────────┘
                                                └─► S-13 ─► S-03 ─► S-06 ─► EX1-01
G0 EX-05（D-06a）─────────────────────────────────────────────────► Q-05（W15–W17，3 次冷登入）─► EX1-10
```

**關鍵路徑**：D-26 → 儲存 → Profile → ChangeSet → 熱換執行器 → 交易層 → 租約 → tasks → 監督 → 崩潰恢復 → 故障腳本 → EX1-09。約 16 週的連續工作，**沒有餘裕**。任何一個節點延遲一週，出口就延遲一週，除非增加 CORE 或 HOST 人力。

### 3.3 可以獨立推進的工作

| 工作 | 為什麼不必等關鍵路徑 |
| --- | --- |
| G1-PLAT-05 的 Wayfire 探測（W1–W2） | 只需要參考機與合成器 |
| G1-SHELL-01 token、四個供應者的 QML 本體 | 可以先對假資料開發，SHELL-13 就緒後再接交易 |
| G1-CORE-17 `ditto-system` | 只依賴執行緒架構 |
| G1-HOST-01／12 vendor 與守門 | 只依賴 D-04 |
| G1-QA-04 故障注入框架 | 只需要協調器骨架 |
| 四個管理中心的畫面 | 能力定義（CORE-15）一出來即可對假 Core 開發 |

### 3.4 最容易被低估的依賴

1. **SHELL-13 依賴 CORE-07 的參與者協定。** 若 W6 參與者協定還沒定，Shell 的四個供應者只能是「可以顯示但不能交易替換」，M2 的示範會退化成重啟 Shell。
2. **HOST-06 依賴 CORE-06 的檔案授予。** tasks 服務要讀使用者的檔案，沒有權限模型就只能讀寫死的路徑——那正是本計畫說「不能是示範玩具」的反例。
3. **Q-05 依賴 G0 的 D-06a。** G0 的 EX-05 若在 G1 期間才完成，Q-05 的三次冷登入最早也只能在 D-06a 核定後開始。
4. **EX1-13 ⑤ 依賴第二台實體螢幕。** 這是硬體採購，W1 就要啟動。

## 4. G2 可開工點（M3）

`milestones/01/03` 允許 G2 在「G1 的能力目錄與 ChangeSet 可用（不必等 G1 全部完成）」時開始；PRD 22 節也明示不得等整個桌面完成才接 LLM。本計畫把「可用」寫成可檢查的清單。**全部成立**才可宣告 G2 開工：

| # | 條件 | 檢查方式 |
| --- | --- | --- |
| G2-S1 | `desktop.capabilities.list` 回傳 G2 會用到的群組（profiles、changes、plugins、appearance、panels、launcher、layout、notifications、tasks）且目錄 gate 全綠 | CI 紀錄 |
| G2-S2 | `desktop.changes.propose／get／undo` 走完整狀態機，含預檢、回讀與四種結果類別 | 協調器整合測試 |
| G2-S3 | 單一 `authorize()` 已接上所有能力；`agent` 主體存在；`approval_unavailable` 失敗即拒絕 | 授權決策表測試 |
| G2-S4 | Agent 替身能經受控啟動器取得身分、送出 ChangeSet、以 `operation_id` 查詢 | L-10 正例 |
| G2-S5 | 基底 revision 過期被拒（CFG-06） | L-09 正例 |
| G2-S6 | 協定 0.2 已凍結欄位：之後只允許新增選用欄位，任何破壞性變更須通知 G2 並升版 | `docs/contracts/protocol-0.2.md` 標示凍結 |

G2 開工後，G1 的 CORE 人力會被 G2-CORE-01～06 分走（`milestones/01/03` 的 G2 估算中 CORE 18 人週）。§5 的人力選項必須把這個重疊算進去。

## 5. 人力、估算與差異說明

### 5.1 估算差異

| 工作流 | milestones/01 | 本計畫 | 差 | 理由 |
| --- | --- | --- | --- | --- |
| CORE | 40 | 47 | ＋7 | CORE-15（2）、CORE-16（2）、CORE-17（3） |
| HOST | 26 | 27 | ＋1 | HOST-12 |
| SHELL | 32 | 34.5 | ＋2.5 | SHELL-13 |
| PLAT | 10 | 12 | ＋2 | PLAT-05 |
| QA | 16 | 20 | ＋4 | QA-06（2）、QA-07（2） |
| **合計** | **124** | **140.5** | **＋16.5** | |

### 5.2 人力與工期的矛盾（F-3）

`milestones/01/05 §3.1` 的建議人力中，G1 會用到的是 Core 2、Host 2、Shell 2（含 1 設計）、平台 1、QA 1，合計 8 人。

| 情境 | 可完成人週 | 對照 |
| --- | --- | --- |
| 8 人 × 18 週 × 75% 有效投入 | 108 | 低於 124，也低於 140.5 |
| 8 人 × 18 週 × 100% | 144 | 帳面上夠 140.5，但 100% 有效投入不現實，且 W11 起 CORE 要分人給 G2 |
| 需要的人數（140.5 人週、18 週、75%） | 10.4 人 | —— |
| 需要的週數（140.5 人週、8 人、75%） | 23.4 週 | —— |

G0 的經驗值是約 55% 有效投入（plan/02/06 §5.1），G1 以 75% 估算已經偏樂觀。

### 5.3 三個選項（D-31 裁決）

| 選項 | 內容 | 代價 |
| --- | --- | --- |
| **A（建議）** | 11 人、18 週：Core 3、Host 3、Shell 3（含 1 設計）、平台 1、QA 1.5（另 0.5 由 Host 支援故障注入） | 人力成本；W11 起 Core 仍會被 G2 分走約 1 人，需在 G2 計畫中補足 |
| B | 8 人、23–24 週 | G1 延後 5–6 週；G2 的可開工點（M3）同步後移到約 W14 |
| C | 8 人、18 週、縮減範圍 | **本計畫不能選**。縮減範圍是放寬，須依 `ditto-decision-record` 附數據提案並回寫上位文件；若被核定，受影響的出口門檻必須在同一份決策中明列 |

D-31 未核定前，`milestones/01` 的 124 人週與 14–18 週仍是有效的上位建議值；本計畫的週序以選項 A 的人力排定。

### 5.4 每週人力分配（選項 A）

| 週 | CORE（3） | HOST（3） | SHELL（3） | PLAT（1） | QA（1.5） |
| --- | --- | --- | --- | --- | --- |
| W1 | C-16；C-01 起 | H-01；D-32 試作 | token；供應者 QML 本體（假資料） | **C-15～C-19 探測**；第二螢幕 | Q-04 設計；替身骨架 |
| W2 | C-01；C-15 起 | H-12；D-32 試作 | 同上 | 探測收斂 | Q-04 |
| W3 | C-02；C-15 | **D-32 定案**；H-02 起 | S-01 | 探測結果寫入差異表；G1-R4 決定 | Q-04；Q-01 起 |
| W4 | C-03；C-17 起 | H-02 | S-01；S-13 起 | P-02 | Q-01 |
| **W4 末** | **M1** | | | | |
| W5 | C-03；C-04；C-17 | H-02；H-09 | S-13 | P-02；P-05 實作 | Q-01；Q-04 |
| W6 | C-07；C-04 | H-02；H-03 | S-13；S-03 | P-05 | Q-04 |
| W7 | C-08；C-05 起 | H-03；H-05 | S-03 | P-05 | Q-04；Q-02 起 |
| W8 | C-08；C-05；C-06 起 | H-04；H-05 | S-03；S-02 | P-01 起 | Q-02 |
| **W8 末** | **M2** | | | | |
| W9 | C-05；C-06 | H-06 | S-03；S-04；S-10 | P-01 | Q-02 |
| W10 | C-06；C-15 收尾 | H-06；H-07 起 | S-02；S-10；S-06 起 | P-01 | Q-02；Q-07 起 |
| W11 | C-10；C-12 起 | H-07；H-08 起 | S-06；S-07 起 | P-03 起 | Q-02；Q-07 |
| **W11 末** | **M3（G2 可開工）** | | | | |
| W12 | C-11；C-12；C-13 | H-08；H-10 | S-06；S-07；S-08 | P-03 | Q-02；Q-07 |
| W13 | C-11；C-09；C-14 | H-08；H-11 | S-08；S-09；S-05 | P-04 | Q-07；Q-03 準備 |
| W14 | C-09；C-13；缺口 | H-11；缺口 | S-05；S-11；S-12 | P-04 | Q-03 準備；Q-06 準備 |
| **W14 末** | **M4；W15 起功能凍結** | | | | |
| W15 | 缺口修補 | 缺口修補 | 缺口修補；M-01～M-09 準備 | 缺口修補 | Q-03；Q-06；**Q-05 第 1 次** |
| W16 | 缺口修補 | 移植紀錄定稿（EX1-14） | 人工驗收 | 支援矩陣更新 | Q-05 第 2 次；nightly 計數 |
| W17 | —— | —— | —— | 授權盤點彙整 | Q-05 第 3 次；報告 |
| W18 | **出口評審**（見 [09](09-exit-review-and-handoff.md)） | | | | |

nightly 連續 5 晚（EX1-15）必須在 W16–W17 之間累積完成；W15 功能凍結就是為了讓 nightly 不再因功能變更而重新計數。

## 6. 每週檢查點清單

每週結束時逐項回答，寫進 §8 的進度紀錄：

1. 關鍵路徑上的工作包是否照計畫推進？延遲幾天？延遲的影響是否已傳遞到後續工作包？
2. 本週有沒有任何程式碼寫入 Core 以外的配置路徑？（hostd 的磁碟檔案、Shell 的設定檔、插件自己選的資料路徑）
3. 本週有沒有新增能力？它是否同時有 Definition、Provider、Consumer 與非空的 `resource_scope`？
4. 本週有沒有「先這樣、之後再改」的決定？它會不會讓 G2 的 Agent 接入時多出一條繞過 ChangeSet 的路？
5. nightly 與 VM 迴歸是否綠燈？連續失敗超過兩晚即視為阻塞。
6. 是否有已到期未決的決策？（見 [08 §1](08-decisions-and-risks.md#1-g1-必須落定的決策)）
7. 本週是否產生應記錄而未記錄的決策或對上位文件的回饋？
8. （W11 起）G2 是否提出了對協定 0.2 的破壞性變更需求？若有，是否走了升版程序？

## 7. 預備期工作

G0 出口前允許的工作見 [01 §2.2](01-scope-and-exit-criteria.md#22-預備期g0-出口前)。預備期的產出**不計入**上表的週序，但可以縮短 W1–W3：

| 項目 | 負責 | 產出 |
| --- | --- | --- |
| D-04、D-08、D-10、D-15、D-26、D-27 的決策紀錄 | 各工作流 owner | `.agents/notes/decisions/` |
| D-32 的預先承諾判準 | HOST | 決策紀錄的「依據」欄 |
| vendor 取用試作（分支，不合併） | HOST | 建置可行性紀錄 |
| 策略 A 的純 Node 試作 | HOST | 試作報告（開發證據） |
| `ditto-store` schema 草案 | CORE | `docs/contracts/store-schema.md` 草案 |
| 協定 0.2 草案 | CORE | `docs/contracts/protocol-0.2.md` 草案 |
| 第二螢幕採購 | PLAT | 到貨日期 |

## 8. 進度紀錄

更新日期 2026-09-27。狀態只有四種：**未開始**、**進行中**、**開發環境已完成**（程式與腳本可重複執行，但判定所需的參考機證據還沒有）、**完成**。門檻通過與否一律在出口評審判定，本表不代表出口結果。

### 8.1 開工條件

| 條件 | 狀態 | 缺口 |
| --- | --- | --- |
| G0 出口 | **未達成** | EX-02（C-08）、EX-05（D-06a）、EX-08、EX-09 未通過；EX-01／03／04／06／07 待進版重跑 |
| D-04／08／10／15／26／27 | 未決 | 見 [08 §1](08-decisions-and-risks.md#1-g1-必須落定的決策) |
| D-31（估算與人力） | 未決 | 選項 A／B 待管理裁決 |
| 各工作流 owner（D-12 的 G1 部分） | 未指派 | G0 整體 owner 為 Lei-k；G1 各工作流負責人未定 |
| 第二台實體螢幕 | 未取得 | —— |

### 8.2 工作包狀態

全部 54 個工作包：**未開始**。預備期項目：**未開始**。

### 8.3 期間的其他紀錄

| 日期 | 項目 | 內容 |
| --- | --- | --- |
| 2026-09-27 | 計畫建立 | 以 harness HEAD `477b4f4` 與 Ditto `8dc27d2` 為盤點基準 |
