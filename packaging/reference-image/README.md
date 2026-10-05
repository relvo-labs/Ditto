# G0 參考機映像

這個目錄凍結 G0 出口量測使用的參考平台。其他 Linux 機器仍可開發、跑單元／契約測試與產生開發證據；只有 `preflight.sh` 與 `reference-machine.lock.json` 相符、並設定 `DITTO_REFERENCE_MACHINE=1` 的實體機結果可進 G0 出口評審。

G0 的主要參考機識別為 `ditto-ref-ws-rtx4060-01`。同一項三次重複量測不得混用不同機器；新增參考機時要給新的穩定識別並另存指紋，不能把不同硬體的數字合併。

## 凍結內容

- Ubuntu 24.04.2 LTS、kernel `6.17.0-40-generic`。
- AMD Ryzen 9 7945HX、RTX 4060 8 GiB／NVIDIA 570.211.01、60.5 GiB RAM、Crucial P3 Plus 2 TB NVMe。
- Wayfire 0.11.0（wlroots 0.20.2）、Qt 6.10.2、Quickshell 0.3.1。
- Rust 1.98.1、Node 22.23.2、pnpm 10.11.0。
- 參考應用：Firefox 156.0.1-1 rev 8969（原生 Wayland）、foot 1.16.2、Kate 23.08.5；XWayland 只做相容性對照，不屬 EX-01 的參考應用集合。
- 量測輸出固定為 1920×1080、60 Hz、scale 1；實體 Samsung LC34G55T 支援此模式。開發時可使用其他模式，但不得與出口量測混合。

完整且機械可讀的值見 [`reference-machine.lock.json`](reference-machine.lock.json)。

## 重建與驗證

1. 安裝 Ubuntu 24.04.2 LTS，套用 [`apt-packages.txt`](apt-packages.txt) 的套件集合。
2. 依 [`source-builds.lock`](source-builds.lock) 建置 Wayfire 私有前綴與 Qt／Quickshell。上游來源、tag／commit 與安裝位置都不得浮動。
3. 安裝 `rust-toolchain.toml`、`.nvmrc` 與根目錄 `packageManager` 指定的工具鏈。
4. 執行 `bash packaging/reference-image/capture-fingerprint.sh /tmp/current.json`，再執行 `bash packaging/reference-image/preflight.sh`。
5. 執行 `bash packaging/reference-image/install-session.sh`；它會以鎖定工具鏈建置 release Core、`ditto-supervisor` 與 `dittoctl`，建置 `packages/host-runtime` 的 hostd 與內建套件（`target/ditto-packages`），並安裝「Ditto (Wayfire)」登入管理器項目與 systemd user unit。Core 以受控啟動器啟動 Shell、hostd、救援介面與鎖定客戶端，不使用 development token。hostd 必須跑在 `.nvmrc` 凍結的 Node 上，安裝程式以 `DITTO_NODE`（未設時取 `PATH` 上的 `node`）的正規路徑寫進 unit，版本不符即停止——啟動器比對 `/proc/<pid>/exe`，包裝腳本會被拒絕。G0 的「Ditto G0 (Wayfire)」要在 54ef90b 上安裝，見[下方](#g1-工作階段從-g0-搬到哪裡)。
6. 從登入管理器選擇該工作階段登入，以實體鍵盤完成 `tests/g0/input-method/manual-session.sh`，再執行參考機驗證腳本。

`install-session.sh` 綁定執行當下的工作樹絕對路徑，所以重建者可把倉庫放在不同位置；開發機不需要安裝這個工作階段。登入後的 Wayfire 設定在 `session/wayfire.ini`，不借用使用者家目錄中的第二份配置。

這不是整個產品的安裝包。G0 沒有 Profile、Cordis、Agent 或救援模式；此目錄只重建 G0 原生可行性與出口量測環境。

## G1 工作階段：從 G0 搬到哪裡

G1-PLAT-02 把登入 script 從 `ditto-g0-session` 改為 `ditto-session`，並由它啟動 `ditto-session.target`，不再直接啟動 Core。Core、supervisor 與救援介面改為常駐的 systemd user unit（[`packaging/systemd/user/`](../systemd/user/)），因為 transient scope 沒有 `Restart=`、`StartLimit*`、`WatchdogSec` 與 `OnFailure=`（[plan/03/05 §2](../../plan/03/05-platform-supervision-and-rescue.md#2-systemd-user-unitg1-plat-02)）。

| G0（commit 54ef90b） | G1（本工作樹） |
| --- | --- |
| `/usr/local/libexec/ditto-g0-session`、登入項目「Ditto G0 (Wayfire)」（`ditto-g0.desktop`） | `/usr/local/libexec/ditto-session`、「Ditto (Wayfire)」（`ditto.desktop`） |
| `ditto-g0-end-sessions`、`ditto-g0-relogin`、`ditto-g0-logout`、`gdm.service.d/ditto-g0.conf` | `ditto-end-sessions`（同時結束 G0 與 G1 的孤兒工作階段）、`ditto-relogin`、`ditto-logout`、`gdm.service.d/ditto.conf` |
| `ditto-g0-wayfire.scope`、`ditto-g0-fcitx.scope` | `ditto-wayfire.scope`、`ditto-fcitx.scope`（仍由登入 script 啟動） |
| `ditto-g0-core.scope`（`systemd-run`） | `ditto-core.service`（`Type=notify`、`WatchdogSec=10`、`OnFailure=ditto-rescue.service`） |
| `ditto-g0-quickshell.scope`（前綴 `ditto-g0`） | `ditto-quickshell.scope`（Core 的受控啟動器，前綴 `ditto`；若 Core 改以 kind `shell` 啟動則為 `ditto-shell.scope`） |
| — | `ditto-supervisor.service`、`ditto-rescue.service`、`ditto-session.target` |
| 量測變體：`~/.config/ditto-g0/measure-variant` | `${DITTO_MEASURE_CONDITIONS:-$XDG_STATE_HOME/ditto/measure-conditions.json}` 的 `desktop_variant`（`standard`／`avatar-off`／`reduced-motion`／`rescue-no-node`）；不再讀 `XDG_CONFIG_HOME`。`rescue-no-node` 只用於 EX1-10（`tests/g1/measure/cold-login.sh`）：登入 script 在 `session.env` 寫入 `DITTO_CORE_MODE_ARGS=--mode rescue`，`ditto-core.service` 把它接在命令列末尾；驗證安裝的 relay（Node）在這個變體不啟動。其他登入不設這個變數，Core 的命令列不變 |
| Core 或 Wayfire 任一結束即結束工作階段 | 只有 Wayfire 結束才結束工作階段；Core 的重啟與救援都在工作階段內發生 |

G1 的安裝**不移除** G0 的登入項目與 `/usr/local/libexec/ditto-g0-*`，兩個項目可以並存。

**G0 證據只在 54ef90b 上可重現。** 已安裝的 G0 工作階段在登入時讀取工作樹中的 `wayfire.ini`、`target/release/ditto-core` 與 `shell/`，所以它跑的永遠是**當下**檢出的程式碼。要重跑 G0 的量測，先檢出 54ef90b（或以該 commit 的 worktree 並設 `DITTO_WORKSPACE`）再以該版本的 `install-session.sh` 安裝。下列 G0 腳本寫死 G0 名稱，在 G1 工作階段中**不適用**，也沒有被改寫：

- `tests/g0/measure/cold-login.sh`：`ditto-g0-*.scope` 與 `~/.config/ditto-g0/measure-variant`。
- `tests/g0/input-method/login-session-auto.sh`：`ditto-g0-wayfire.scope`、`ditto-g0-fcitx.scope`。
- `tools/dev-vm/lib.sh`、`tools/dev-vm/run.sh`：`ditto-g0-*.scope` 與 `/usr/local/libexec/ditto-g0-relogin`。
