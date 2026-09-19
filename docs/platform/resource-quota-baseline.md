# 工具配額基線

| 文件屬性 | 內容 |
| --- | --- |
| 狀態 | **未核定**。以下數據來自開發 VM，不是實體參考機；初始建議值須依 EX-05 的決策程序核定 |
| 對應工作包 | [G0-QA-03](../../plan/02/05-measurement-and-verification.md#6-工具配額基線g0-qa-03) |
| 重跑方式 | `bash tests/g0/quota-baseline/run.sh`（需要 `systemd --user`；不在開發容器內執行） |
| 原始輸出 | `artifacts/g0/quota-baseline-<run_id>.json` |

G0 沒有工具與測試宿主，但配額機制必須先確認可用：G3 的隔離直接建在它上面，等到那時才發現平台做不到會很貴。

## 1. 三個案例與判準

| 案例 | 限制 | 判準 |
| --- | --- | --- |
| 記憶體 | `MemoryMax=64M`、`MemorySwapMax=0` | scope 內的程序被終止，**scope 外的程序不受影響** |
| CPU | `CPUQuota=20%` | 忙碌迴圈取得的 CPU 時間約為配額比例，而不是整顆核心 |
| 程序數 | `TasksMax=16` | 建立程序在上限處停止（實際成功的 fork 次數，不是嘗試次數） |

腳本在三個案例期間持續執行一個「見證」程序；記憶體案例要同時證明**候選 OOM 不會連帶終止桌面**（19.1 與 SEC-12 的共同要求）。

## 2. 開發 VM 的實測結果（2026-09-19）

| 案例 | 結果 | 說明 |
| --- | --- | --- |
| 記憶體 | **生效** | scope 被終止（SIGKILL），見證程序在整段期間持續取樣，未受影響 |
| CPU | **未生效** | 20% 配額下，忙碌迴圈仍取得 0.999 的 wall time |
| 程序數 | **生效** | `TasksMax=16` 下 64 次 fork 只有 15 次成功 |

CPU 未生效的原因是這台 VM 的 `systemd --user`（249.11）沒有把 `cpu` 控制器委派給使用者實例：系統根 cgroup 有 `cpu`，但 `user@.service` 的 `cgroup.controllers` 只有 `memory` 與 `pids`。**這是平台設定問題，不是配額機制不存在**；參考機凍結時必須在 D-01 一併確認委派設定，否則 G3 的 CPU 配額沒有著力點。

## 3. 一併記錄的平台事實

| 事實 | 開發 VM 的值 | 誰會用到 |
| --- | --- | --- |
| 核心 | `5.15.0-186-generic` | Landlock ABI 綁定此版本 |
| LSM | `lockdown,capability,landlock,yama,apparmor` | G3 隔離 |
| **Landlock ABI** | **1** | ABI 1 沒有 `refer` 與 `truncate` 規則；R-16 的 `partial` 風險在此版本成立 |
| cgroup v2 控制器（根） | `cpuset cpu io memory hugetlb pids rdma misc` | 配額 |
| `systemd --user` 委派 | 空（實際可用：`memory`、`pids`） | 上述 CPU 案例 |
| `bwrap` | 0.6.1 | G3 |
| Secret Service | 不可用（無 `org.freedesktop.secrets`） | G2 的秘密儲存 |

## 4. 尚未完成

- 三個案例都要在**實體參考機**重跑，並與該機的核心、systemd 版本與委派設定一起記錄。
- 建議初始值（生成測試宿主、建置工作、一般工具各一組）要等參考機數據才提出；本文件不先寫下數字，避免把開發 VM 的條件變成預設值。
- 核定走 EX-05 的決策紀錄，結論回寫 `milestones/01/05`。
