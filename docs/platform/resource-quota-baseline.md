# 工具配額基線

| 文件屬性 | 內容 |
| --- | --- |
| 狀態 | **未核定**。以下數據來自開發機，不是實體參考機；初始建議值須依 EX-05 的決策程序核定 |
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

## 2.1 開發工作站的實測結果（2026-09-22）

主要開發機換成[工作站](dev-wayland-environment.md)後重跑，**三個案例全部生效**：

| 案例 | 結果 | 數據 |
| --- | --- | --- |
| 記憶體 | 生效 | scope 被終止，見證程序 29 次取樣期間不受影響 |
| CPU | **生效**（舊 VM 未生效） | `CPUQuota=20%` 下忙碌迴圈取得 0.202 的 wall time |
| 程序數 | 生效 | `TasksMax=16` 下 64 次 fork 成功 15 次 |

原始輸出：`artifacts/g0/quota-baseline-2026-09-22T02:22:03Z-35a1.json`。

CPU 從未生效變成生效，**不是機制改變，是平台設定不同**：這台的 `user@1000.service` 的 `cgroup.controllers` 有 `cpu`，舊 VM 沒有。這正是上一節說的「平台設定問題」，也說明為什麼 D-01 凍結參考機時必須把委派設定一起記下來——同一份腳本在兩台機器上會得到相反的結論。

一個要注意的落差：腳本記錄的 `delegated_controllers` 是空字串，但 CPU 配額確實生效。屬性值與實際行為不一致，判定以實測行為為準；參考機上要確認這個欄位的取得方式是否需要修正。

## 3. 一併記錄的平台事實

| 事實 | 舊開發 VM（2026-09-19） | **開發工作站（2026-09-22）** | 誰會用到 |
| --- | --- | --- | --- |
| 核心 | `5.15.0-186-generic` | `6.17.0-40-generic` | Landlock ABI 綁定此版本 |
| LSM | `lockdown,capability,landlock,yama,apparmor` | 同左再加 `ima,evm` | G3 隔離 |
| **Landlock ABI** | **1** | **7** | ABI 1 沒有 `refer` 與 `truncate` 規則，R-16 的 `partial` 風險在該版本成立；ABI 7 兩者都有 |
| cgroup v2 控制器（根） | `cpuset cpu io memory hugetlb pids rdma misc` | 同左再加 `dmem` | 配額 |
| `systemd --user` | 249.11，`cpu` 未委派 | 255.4，`user@1000.service` 的 `cgroup.controllers` 含 `cpu` | 上述 CPU 案例 |
| `bwrap` | 0.6.1 | 0.9.0 | G3 |
| Secret Service | 不可用 | **可用** | G2 的秘密儲存（D-09 的 Secret Service 首選在此機成立） |

**兩台的值差距很大，這正是不能把任一台當成參考機的理由。** R-16 的沙箱風險在 ABI 1 上成立、在 ABI 7 上不成立，而參考機會是哪一種目前沒有答案。

## 4. 尚未完成

- 三個案例都要在**實體參考機**重跑，並與該機的核心、systemd 版本與委派設定一起記錄。
- 建議初始值（生成測試宿主、建置工作、一般工具各一組）要等參考機數據才提出；本文件不先寫下數字，避免把開發 VM 的條件變成預設值。
- 核定走 EX-05 的決策紀錄，結論回寫 `milestones/01/05`。
