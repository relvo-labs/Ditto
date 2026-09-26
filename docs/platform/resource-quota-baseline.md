# 工具配額基線

| 文件屬性 | 內容 |
| --- | --- |
| 狀態 | **機制在參考機成立，初始值未核定**。D-06b 仍須依 EX-05 的決策程序核定 |
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

## 2.1 參考機的實測結果（2026-09-22）

`ditto-ref-ws-rtx4060-01` 同時可作開發工作站；依 D-01 凍結後以 `DITTO_REFERENCE_MACHINE=1` 重跑，**三個案例全部生效**：

| 案例 | 結果 | 數據 |
| --- | --- | --- |
| 記憶體 | 生效 | scope 被終止，見證程序 29 次取樣期間不受影響 |
| CPU | **生效**（舊 VM 未生效） | `CPUQuota=20%` 下忙碌迴圈取得 0.202 的 wall time |
| 程序數 | 生效 | `TasksMax=16` 下 64 次 fork 成功 15 次 |

最新參考證據：`artifacts/g0/quota-baseline-2026-09-22T14:46:14Z-6dfa.json`。先前未標成參考機的同機結果保留為開發證據。

CPU 從舊 VM 的未生效變成參考機的生效，**不是機制改變，是平台設定不同**：本機的 `user@1000.service` cgroup 有 `cpu`，舊 VM 沒有。這說明為什麼開發可跨機器、出口數字卻不能混算。

一個要注意的落差：腳本記錄的 `delegated_controllers` 是空字串，但 CPU 配額確實生效。屬性值與實際行為不一致，判定以實測行為為準；參考機上要確認這個欄位的取得方式是否需要修正。

## 3. 一併記錄的平台事實

| 事實 | 舊開發 VM（2026-09-19） | **參考機（2026-09-22）** | 誰會用到 |
| --- | --- | --- | --- |
| 核心 | `5.15.0-186-generic` | `6.17.0-40-generic` | Landlock ABI 綁定此版本 |
| LSM | `lockdown,capability,landlock,yama,apparmor` | 同左再加 `ima,evm` | G3 隔離 |
| **Landlock ABI** | **1** | **7** | ABI 1 沒有 `refer` 與 `truncate` 規則，R-16 的 `partial` 風險在該版本成立；ABI 7 兩者都有 |
| cgroup v2 控制器（根） | `cpuset cpu io memory hugetlb pids rdma misc` | 同左再加 `dmem` | 配額 |
| `systemd --user` | 249.11，`cpu` 未委派 | 255.4，`user@1000.service` 的 `cgroup.controllers` 含 `cpu` | 上述 CPU 案例 |
| `bwrap` | 0.6.1 | 0.9.0 | G3 |
| Secret Service | 不可用 | **可用** | G2 的秘密儲存（D-09 的 Secret Service 首選在此機成立） |

兩台的值差距很大；D-01 已指定右欄為 G0 參考指紋。R-16 在 ABI 1 的舊 VM 上風險較高，但 ABI 7 仍不等於完整沙箱已成立，後續實作仍須如實回報 full／partial。

## 4. 尚未完成

D-06b 已依參考機結果核定以下 G1/G3 起始預設；它們是上限，不是應用可預先保留的容量：

| 工作類型 | `MemoryMax` | `CPUQuota` | `TasksMax` | 補充 |
| --- | ---: | ---: | ---: | --- |
| 一般短工具 | 256 MiB | 50% | 32 | 預設單程序；逾時另由操作契約限制 |
| 生成測試宿主 | 512 MiB | 100% | 64 | 超限終止候選，不影響桌面 |
| 受控建置工作 | 2 GiB | 200% | 256 | RUN-05 仍限制最多 2 個重型工作並行 |

基線測試的 64 MiB／20%／16 是為了快速觸發並證明三種控制器確實生效，不是上述三類工作的正式配額。初始值與調整規則見 [D-06b 決策紀錄](../../.agents/notes/decisions/2026-09-22-d06b-tool-quotas.md)。D-06a 的 Core／Shell PSS 預算仍要等合格的三次 cold-login 量測，兩者不得合併成同一個「已核定」。
