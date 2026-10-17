# G3 決策、風險與交接

本檔為執行提案。決策權與紀錄依 `ditto-decision-record`；不以程式碼選項冒充 owner 核定。

## 1. 已授權的開工範圍

使用者於 2026-10-13 明確要求深入分析 #34、相關 issues、參考 `.agents`、開新 branch 實作。依此開始獨立基礎設施，採目前可用的 G2 分支基底；見 [D-45](../../.agents/notes/decisions/2026-10-13-d45-g3-independent-foundation.md)。

G2 證據只對應 G2 原 commit；G3 commit 不作 G2 證據；Core／協定接線等待條件由 [D-46](../../.agents/notes/decisions/2026-10-13-d46-g2-functional-acceptance-and-g3-integration.md) 取代，owner 接受 G2 功能完成並授權完整 G3。這不把未執行量測改成通過，也不核定 D-17 選型或工期。後續 main 的 G2-exit §3.6 已提供參考機數據，D-44 後端先採 1G 寬鬆上限；其收緊與整組 slice 由 #35 追蹤。

## 2. 待決策／提案

| 議題 | 提案與必要依據 | 最晚時點 |
| --- | --- | --- |
| D-17 兩類生成插件 | 沿用待辦摘要／工作區快捷動作；SDK 可先做，不宣告選型核定 | #28 真模型驗收前 |
| D-08 實作細節 | 沿用現有 `ditto-confine`，獨立 systemd cgroup；不新增 Harness 原始碼；AppArmor 不放寬 | #23 生產執行政策凍結前 |
| D-12／G3 人力與曆時 | 64 人週維持提案，各流拆分見 05；實作後按剩餘工作估，不以 Agent 執行時間換算人週 | 正式接線與出口排程前 |
| D-44／G2 資源 | G2 參考機量測已完成，後端先採 1G；#35 依 memory.peak 收緊並整組 slice。G3 宿主另依 D-06b | G2 出口、G3 資源比較前 |
| 生產模板的執行位置 | 受限描述由可信固定 UI 解譯；自由 QML 不載主 Shell；試載／預覽獨立 | #19／22 正式契約前 |
| 資料 schema 回退政策 | 按可讀範圍／可逆／快照／不可回退分項，不提供通用任意遷移腳本 | #21 實作前 |

## 3. 上游與現有實作取用

HOST 第一批只以 subprocess 使用本倉庫的 `ditto-confine@a88bce8`，沒有複製 Harness 的 `landlock-run`／`sandbox-local`。這是 Ditto 既有邊界的薄轉接，不是新增外部源碼移植；新增政策與 cgroup 是 Ditto 工作，不寫成 Harness 既有功能。

本次 #29 已彙整於 [G3 沿用紀錄](../../docs/upstream/g3-adoption.md)，來源包括 `docs/upstream/cordis-port.md`、`harness-g2-port.md`、Codex／D-Bus proxy pins、各 vendor manifest 與固定測試矩陣。原待決策表保留提案脈絡，實際模板／資料政策見 [實作邊界](../../docs/platform/generated-template-boundary.md)，出口與剩餘驗收見 [G3-exit](../../.agents/notes/gate-reviews/G3-exit.md)。新增外部程式碼時逐項記 package、repo、commit、port kind、modifications、host contract、trust、license、test matrix，以及四欄沿用對照。原來源授權不能改成主專案授權；G4 完整盤點仍另做。

## 4. 風險

| 風險 | 處理／阻擋條件 |
| --- | --- |
| G2 還在量測，G3 污染基線 | 分支／commit 固定；依 D-46 整合 Core／wire；G2 量測仍在原 G2 checkout 跑 |
| bwrap 被 AppArmor 擋住 | 不把 bwrap 設為唯一方案；confine ABI／seccomp／cgroup 實測，缺證據拒絕 |
| `confined:true` 被誤當 full | 由受控 runner 分項彙總，讀 cgroup，固定政策與原因；不能由候選自證 |
| G2 connect broker 不是全面關閉網路 | 程式碼檢查顯示 unconnected UDP 不經 connect；G3 額外 seccomp 禁止非 Unix socket。G2 本身的網路政策另行檢討，不能將其直接稱為生成安全政策 |
| 測試程序逃離 process group | 以整個 cgroup 清理、驗證 pids；不只 kill 父 PID |
| 模板內容注入程式碼 | 描述封閉、文字純文字、無 source interpolation、無動態 import／URL |
| 生成只是切內建外觀 | AT-06 留真模型的全新內容地址產物與多次修改，不接受 fixture 替代 |
| 修復重啟重置預算 | Core 持久三輪與錯誤指紋、工具前落盤 |
| schema 回退破壞新資料 | 快照／相容範圍與獨立授權；不能證明時拒絕回退，保留資料 |
| OOM 或診斷洪水影響桌面 | D-06b cgroup、輸出上限、整組終止，見證桌面同 PID／revision |
| Agent 暖態 VM 超標 | 原 150 MiB 目標不變；G2 參考機暖態 88.6～89.2 MiB，VM 差異由 #35 追蹤，不作 G3 資源驗收 |

## 5. G4 交接清單

交付 G3-exit 五項原門檻與 AT-26／29 的事實／缺口；每筆附 commit、硬體、PID／cgroup 與證據類別。G4 接手安裝發行、完整依賴／字型／素材授權、名稱權利、參考機資源與效能、基本桌面／雙螢幕、nightly 與 D-38 未完項。不把 G3 的開發 CLI、離屏模板或單元測試當成發布完成。
