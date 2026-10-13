# G3 隔離與受限模板

本檔為實作提案；#16／17／18／22／23／32。適用 skills：`ditto-generation-safety`、`ditto-process-budget`、`ditto-permission-and-secrets`、`ditto-qml-shell`、`ditto-upstream-port`。

## 1. 宿主邊界

生成測試是按工作啟動的獨立程序，不是新常駐 Node 服務。桌面 Core、hostd、Shell、合成器與原生應用均在候選 cgroup 外。D-06b 預設 `MemoryMax=512M`、`MemorySwapMax=0`、`CPUQuota=100%`、`TasksMax=64`；測試 deadline 提案 30 秒，上限 120 秒，取消或超限清理整個候選 cgroup。

提案提供 `ditto-test-host` 開發工具，外層以 systemd user transient service 啟動私有 runner。runner **先回讀實際** `memory.max`、`memory.swap.max`、`cpu.max`、`pids.max`，再啟動 `ditto-confine`。僅填入 systemd 參數不構成資源邊界成立的證據。

`ditto-confine` 維持 G2 版本原樣；檔案限固定唯讀執行期與候選工作區，候選沒有桌面 Core socket、session bus、真實 HOME 或網路端點。只把自己的 private status fd 當作 confinement 證據，候選 stdout 不授予信任。不得接受候選提供的 `full`、路徑白名單或執行環境。

初期命令只支援固定診斷 probe，不提供任意候選命令入口。這能在不執行模型程式碼的情況下測試檔案、網路、signal、fork、逾時與 OOM 邊界。之後由 Core 受控啟動固定 Qt 測試程式；不把這個開發工具當成正式能力或通過 AT-06 的證據。

## 2. 完整性與結果

| 等級 | 判準 | 後續 |
| --- | --- | --- |
| `full` | 此次程序的全部要求均有 OS 強制證據，檔案／網路／程序／時間與清理均成立 | 可進入下一個驗證關卡；不自動代表可啟用 |
| `partial` | 有邊界但缺任一要求或證據 | 可檢視，拒絕要求絕對邊界的啟用 |
| `unavailable` | 無法建立必要邊界，或無可信 status | 不執行候選，保留描述與原因 |

封閉等級拒絕未知值。ABI <6 時保留實際 ABI 並回報 `partial`／不可執行；不以測試 skip 當 `full`。無 session bus、cgroup controller 或 confine 啟動失敗時回報 `unavailable`。每次回報含原因、個別邊界、cgroup 回讀、退出碼、超限事件與清理結果；啟用必須同時檢查產物版本、全部驗證關卡與權限。

`full` 是相對於**列出的執行政策**，不是「程式可信」。G2 confine 允許唯讀執行期中程式執行，不能謊稱具「禁止一切子程序」政策。固定 probe 可以測試 bounded subprocess；未完成 #23 的生產政策前，生成候選仍不能進主 Shell。

## 3. 受限宣告式 SDK

生成輸入只允許固定模板 ID、格式版本、插件 ID／版本、顯示文字、有界布局／樣式與核可資料／動作引用。拒絕額外欄位、未知模板、任何 raw QML、JavaScript、imports、URL、檔案路徑、命令、原生入口與動態庫。顯示文字始終當純文字，不做 QML 字串插值或 `eval`。

首批模板提案對應 D-17 預設：

| 模板 | 核可能力 | 新描述可改的範圍 |
| --- | --- | --- |
| 待辦摘要 | `desktop.tasks.list`，有界 tasks 投影 | 標題、排序、最多顯示數量、摘要方式、樣式 |
| 工作區快捷動作 | `desktop.workspaces.list`／`desktop.workspaces.activate` | 標題、已存在 workspace 的按鈕標籤／排列、樣式 |

固定 QML 模板維持 `ready`、`healthy()`、`release()`、`config` 與 client／screen 供應者形狀；UI 不自行決定權限，動作經能力代理與 Core 共用授權。測試資料顯示「預覽使用測試資料」，沒有真實資料時不能假裝已有資料。鍵盤與 Accessible 路徑不可只用滑鼠驗證。

SDK 第一階段僅輸出可檢視描述與固定模板原始碼參考，不能安裝或啟用。每筆需求產生自己的受限描述／內容雜湊及新版本，不能以兩個內建皮膚切換冒充 AT-06。正式 manifest 與 artifact 在 #20／19 的 Rust-first 契約落地後才進安裝交易。
