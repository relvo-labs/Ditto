# D-06a Core／Shell PSS 預算（提案）

| 欄位 | 內容 |
| --- | --- |
| 提案日期 | 2026-10-05 |
| 狀態 | **提案，待核定**；本紀錄提供量測與建議值，不代替產品與工作流 owner 的決定 |
| 決策者 | 待定（G0 owner Lei-k ＋ QA／Core／Shell） |
| 前置 | EX-05 的三次冷登入量測（本次已取得）；D-06b 已決定 |

## 量測（參考機 `ditto-ref-ws-rtx4060-01`）

兩組資料都是 GDM 真正的冷登入，每次登入一次執行，暖機 300 秒、採樣 600 秒（121 點，跨度約 603 秒），PSS 取自 `smaps_rollup`，Firefox／foot／Kate 啟動並排除。

**G0 程式（EX-05）**：分支 `g0/ex05-sample-span` `1fdbb7f`（G0 出口 commit `7333c20` 加取樣跨度與工作階段路徑兩項修正），報告在該 worktree 的 `artifacts/g0/resource-report-cold-login-{standard,avatar-off,reduced-motion}-2026-10-05T13:12:15Z.md`。

| 狀態 | Core | Shell | 合成器 | Fcitx |
| --- | ---: | ---: | ---: | ---: |
| 標準（三次中位數範圍） | 2.1 MiB | 150.4～150.7 MiB | 151～154 MiB | 50.7 MiB |
| 角色關閉 | 2.1 MiB | 125～128 MiB | 151 MiB | 50.7 MiB |
| 減少動畫 | 2.1 MiB | 141～142 MiB | 150～151 MiB | 50.8 MiB |

**G1 完整桌面（EX1-10）**：`main` `61ae38b`，`artifacts/g1/resource-report-cold-login-desktop_full_no_agent-2026-10-05T08:15:07Z.md`：Core 約 26.6 MiB、Shell 約 174 MiB（p95 174.1～175.3）、hostd p95 45.1～45.4 MiB、合成器約 152.6 MiB、Fcitx 50.6 MiB、桌面合計 p95 449～451 MiB。

G0 的 Core 只有協定 0.1 的 13 項能力、沒有儲存層；G1 的 Core 有 SQLite、交易協調與套件庫，所以 G0 的 2.1 MiB 不能拿來當 G1 之後的預算基準。

## 建議

以 G1 完整桌面的實測為基準、留約三成餘裕，作為 G1～G2 的分層預算；超過即依原則 5 提出數據與調整提案，不靜默放寬：

| 分層 | 建議預算（p95） | 實測 p95 | 餘裕 |
| --- | ---: | ---: | ---: |
| Core | 40 MiB | 26.9 MiB | 約 49% |
| Shell（角色開啟） | 230 MiB | 175.3 MiB | 約 31% |
| hostd | 100 MiB（PRD 19.1 既有） | 45.4 MiB | — |
| 全桌面、Agent 不存在 | 600 MiB（PRD 19.1 既有） | 450.9 MiB | — |

合成器與 Fcitx 是平台程序，列入全桌面合計但不另訂 Ditto 預算。

## 考慮過但沒選的方案

- **以 G0 數字訂 Core 預算（如 4 MiB）**：G0 Core 沒有 G1 的儲存與交易層，一進 G1 就必然超標，等於預訂一次放寬。
- **不訂分層、只管全桌面合計**：Shell 的角色資源佔大宗，沒有分層數字就看不出是誰長大了。

## 影響

- 核定後，EX-05 的「D-06a」條件與 EX1-10 的 plan/03/06 §7.1 前置一起解除；G4 的資源回歸以此為對照。
- 同一天較早的 G0 九次執行（02:58～05:33 UTC）因工作階段範本寫死主倉庫路徑而量到錯的程式，已標為不可用，不在本紀錄引用。
