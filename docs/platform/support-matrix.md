# G0 支援矩陣草稿

本文件是 G0-PLAT-01／02 的工作紀錄，尚未完成平台凍結。下列硬體只用於規劃容量；沒有實體參考機的版本指紋、可重建映像或量測結果，因此不能作為 D-01／D-03 決策與 EX-04／05／09 證據。

## 參考機候選

| 維度 | 規劃值 | 尚需核對 |
| --- | --- | --- |
| CPU | 8 CPU（使用者提供的估算） | 實際型號、實體核心／執行緒、時脈 |
| RAM | 16 GB | 實際容量與速度 |
| GPU | NVIDIA RTX 3060 | 具體型號、顯存、驅動與圖形堆疊 |
| 儲存 | 未定 | SSD 型號與容量 |
| 顯示 | 未定 | 是否符合主測 1080p／60 Hz；雙螢幕條件 |
| 發行版／核心 | 未定 | 套件快照、LSM、Landlock ABI |
| 合成器 | 未定 | 候選與備案的 C-01～C-14 功能探測 |
| 工作階段 | 未定 | 登入管理器、`systemd --user`、輸入法環境 |

規劃時可把此候選視為有 8 CPU 與 16 GB RAM 的開發目標；PRD 驗收仍依凍結後的實體平台與固定流程量測。RTX 3060 的渲染、顯存與驅動表現尚無數據，不從型號推定幀時或 PSS 達標。

`milestones/01/04 §2.1` 的量測參考條件是 4 核／16 GB／SSD；「8 CPU」目前還不清楚是 8 個邏輯執行緒或 8 個實體核心。若最終硬體與上位文件的參考條件不同，須在 D-01 與出口評審中明確處理比較方式，不能靜默把候選規格當作原門檻。

## 目前可重建的開發工具鏈候選

| 工具 | 目前檔案／開發環境 | 狀態 |
| --- | --- | --- |
| Rust | `rust-toolchain.toml`：1.98.1；`Cargo.lock` | 開發 pin，D-03 未核定 |
| Node | `.nvmrc`：22.23.2，符合本機 Harness 的 `>=22.19.0` 範圍 | 開發 pin，D-03 未核定 |
| pnpm | 根目錄 `packageManager`：10.11.0；`pnpm-lock.yaml` | 開發 pin，D-03 未核定 |
| Qt／Quickshell | [開發 VM 紀錄](dev-wayland-environment.md) 的 Qt 6.10.2／Quickshell 0.3.1 | 僅容器驗證；正式版本未凍結 |

## 開發 VM 已量到的平台事實

這些值只描述目前的開發 VM（Ubuntu 22.04.5、核心 5.15.0-186-generic），**不是參考機的凍結值**；取得方式見 [工具配額基線](resource-quota-baseline.md)，原始輸出在 `artifacts/g0/quota-baseline-<run_id>.json`。

| 事實 | 值 | 取得方式 |
| --- | --- | --- |
| Landlock ABI | 1 | `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)` |
| LSM 清單 | `lockdown,capability,landlock,yama,apparmor` | `/sys/kernel/security/lsm` |
| cgroup v2 控制器（根） | `cpuset cpu io memory hugetlb pids rdma misc` | `/sys/fs/cgroup/cgroup.controllers` |
| `systemd --user` | 249.11；`memory`、`pids` 可用，**`cpu` 未委派** | `systemctl --user show`、`user@.service` 的 `cgroup.controllers` |
| `bwrap` | 0.6.1 | `bwrap --version` |
| Secret Service | 不可用 | `busctl --user --list` |

後續在實體參考機記錄：`uname -r`、CPU／記憶體／SSD／GPU 識別、驅動與 Mesa、顯示模式、套件版本與雜湊、合成器版本、`/sys/kernel/security/lsm`、Landlock syscall 探測、cgroup v2 與 `systemd --user` 委派、`bwrap` 版本、Secret Service 可用性。每項都附取得指令或檔案路徑，再建立 `packaging/reference-image/` 的可重建安裝腳本。
