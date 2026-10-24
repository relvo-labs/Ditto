# G0 支援矩陣

| 文件屬性 | 內容 |
| --- | --- |
| 狀態 | **G0 凍結**（D-01、D-03，2026-09-22） |
| 主要參考機 | `ditto-ref-ws-rtx4060-01` |
| 機械指紋 | [`packaging/reference-image/reference-machine.lock.json`](../../packaging/reference-image/reference-machine.lock.json) |
| 重建與 preflight | [`packaging/reference-image/README.md`](../../packaging/reference-image/README.md) |

這份矩陣只界定 G0 出口證據的可比範圍，**不限制開發機**。其他 Linux 機器可建置、跑單元／契約測試、開發 Shell 與 Core；其產物標為 development evidence。只有通過參考指紋 preflight 的實體機可產生 EX-01／03／04／05／08／09 證據，同一組三次重複不得混用機器。

2026-10-24 owner 選定發行版 A 底座為 **Ubuntu 26.04＋mkosi＋systemd-sysupdate `/usr` A/B**，B 為並行的既有 Ubuntu Desktop 加裝版（#174）。Fedora bootc 暫停，保留證據；不做 Fedora 加裝版。見[雙形式 ADR](distro-architecture.md)。這不更新下列 G0 凍結指紋，也不接受 Secure Boot、NVIDIA、安裝器、更新／回退或硬體。B 的 24.04 HWE 優先、26.04 後續仍是提案；suite／架構／GDM／GA-HWE／preview-stable／EOL 待 #149 與 owner 核定，現無 B stable 支援承諾。

## 1. 參考平台

| 維度 | 凍結值 | 證據／範圍 |
| --- | --- | --- |
| 發行版 | Ubuntu 24.04.2 LTS | `PRETTY_NAME` |
| 核心 | 6.17.0-40-generic，x86_64 | kernel meta packages 已 hold；漂移即 preflight 失敗 |
| CPU | AMD Ryzen 9 7945HX，16 核／32 執行緒 | 實體機 |
| RAM | 63,468,948 KiB（約 60.5 GiB） | `/proc/meminfo` |
| 儲存 | Crucial `CT2000P3PSSD8` 2 TB NVMe | 實體機 |
| GPU | NVIDIA GeForce RTX 4060 Laptop GPU，8,188 MiB | 驅動 570.211.01；機器另有 AMD Raphael iGPU |
| 顯示器 | Samsung LC34G55T | 出口流程固定 1920×1080、60 Hz、scale 1；日常開發可用其他模式 |
| 合成器 | Wayfire 0.11.0 build d3990237、wlroots 0.20.2 | D-02 已決定；Sway 只保留對照證據 |
| 登入工作階段 | `Ditto G0 (Wayfire)` | `install-session.sh` 安裝；仍須完成一次實體登入驗證 |

上位文件的量測參考條件是 4 核／16 GB／SSD；本機高於該硬體條件。出口報告必須保留本表的完整指紋，不能把本機數字泛化成最低規格承諾。

## 2. 工具鏈與桌面元件

| 元件 | 凍結值 | 鎖定位置 |
| --- | --- | --- |
| Rust | 1.98.1 | `rust-toolchain.toml`、`Cargo.lock` |
| Node | 22.23.2 | `.nvmrc`；符合 Harness 的 `>=22.19.0` |
| pnpm | 10.11.0 | `package.json#packageManager`、`pnpm-lock.yaml` |
| Qt | 6.10.2 gcc_64 | `$HOME/Qt/6.10.2/gcc_64` |
| Quickshell | 0.3.1，commit `1a4716cde794a59928d9d9fc15f2afc7a95de360` | 與 Qt 同前綴 |
| Wayfire | 0.11.0 build d3990237 | `$HOME/wayfire`；依賴 revision 見 `source-builds.lock` |
| Fcitx | 5.1.7 | Wayland input-method-v2 路徑；中文功能驗證尚未通過 |

Qt／Wayfire 使用凍結的私有前綴，不用 Ubuntu 內建 Qt 6.4.2 代替。G0 桌面工作階段沒有常駐 Node；Node 只用於契約產生與測試。

## 3. 參考應用集合

| 角色 | 應用與版本 | G0 路徑 |
| --- | --- | --- |
| 瀏覽器 | Firefox snap 156.0.1-1 rev 8969 | 原生 Wayland；XWayland 不進 EX-01 |
| 終端 | foot 1.16.2-2ubuntu0.1 | 原生 Wayland |
| 編輯器 | Kate 23.08.5（套件 `4:23.08.5-0ubuntu3`） | 原生 Wayland；EX-03 以真實未儲存文件＋剪貼簿 SHA-256 回讀 |

`tests/g0/lib/reference-apps.sh` 是 EX-01 與 EX-03 的共同啟動來源。參考機執行時三種角色缺一即失敗；開發環境的 foot 夾具不會被標成參考證據。

## 4. 平台安全與配額事實

| 事實 | 凍結值／結果 | 影響 |
| --- | --- | --- |
| systemd | 255.4 | user manager 可建立分層 cgroup 單元 |
| cgroup v2 | `cpuset cpu io memory hugetlb pids rdma misc dmem` | 記憶體、CPU、Tasks 三個配額案例均實測生效 |
| Landlock ABI | 7 | G3 仍須依實際規則回報 full／partial，不因 ABI 7 自動宣稱完整隔離 |
| bubblewrap | 0.9.0 | 後續隔離候選；G0 不宣稱生成沙箱已完成 |
| Secret Service | 可用 | 只是平台事實；秘密儲存屬 G2 |

舊開發 VM（kernel 5.15、Landlock ABI 1、CPU 控制器未委派、無 Secret Service）保留在[工具配額基線](resource-quota-baseline.md)作差異對照，不再是參考候選。這個差異也是「可以在其他機器開發，但不能混用出口數字」的實證理由。

### Codex 訂閱連線的開發環境相容性

這是 G2 起 Codex 連線的條件，不變更上表 G0 凍結的參考平台：需要 **Landlock ABI ≥6**，且系統允許安全隔離。以 `cargo build --locked --release -p ditto-confine` 建置後，執行 `./target/release/ditto-confine --landlock-abi` 查詢實際 ABI；負值或低於 6 不能使用 Codex 訂閱連線。ABI 足夠不代表其他隔離檢查已通過。

Coordinator 的 Ubuntu 24.04 kernel 6.8 VM 為 ABI 4。可安裝 `linux-generic-hwe-24.04`，重新開機後再探測；HWE 套件名稱與核心版本字串本身不保證 ABI 或安全設定。完整操作見[Codex 安裝與隔離相容性](../../packaging/reference-image/README.md#codex-隔離相容性)。開發安裝的 `--development` 不略過 ABI 警告；無法提供隔離時，桌面及 API 金鑰路徑仍可使用，Codex 不降級為未隔離執行。

## 5. 尚未形成的出口證據

平台與工具鏈已凍結不表示 G0 已出口。以下仍須依原判準取得：

- 從登入管理器實際進入 `Ditto G0 (Wayfire)`，完成實體鍵盤中文輸入、候選窗與三方剪貼簿驗證。
- Firefox／foot／Kate 的能力矩陣、20 次 Shell 重啟與三次 `wp_presentation` 幀時已在參考機的隔離 Wayfire／GLES2 路徑通過；變更進版後仍要以最終 commit 綁定 artifacts。
- 配額資料已成立；PSS 仍須在固定顯示模式下完成三次真正 cold login，自動 user-service 重啟不冒充 cold login。
- 真機 runner 的三個連續夜間綠燈。

這些缺口只影響相應出口門檻，不撤銷 D-01／D-03 已凍結的版本與機器範圍。
