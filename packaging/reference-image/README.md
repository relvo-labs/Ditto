# G0 參考機映像

這個目錄凍結 G0 出口量測使用的參考平台。其他 Linux 機器仍可開發、跑單元／契約測試與產生開發證據；只有 `preflight.sh` 與 `reference-machine.lock.json` 相符、並設定 `DITTO_REFERENCE_MACHINE=1` 的實體機結果可進 G0 出口評審。

G0 的主要參考機識別為 `ditto-ref-ws-rtx4060-01`。同一項三次重複量測不得混用不同機器；新增參考機時要給新的穩定識別並另存指紋，不能把不同硬體的數字合併。

## Codex 訂閱連線

Codex 是選用項目；沒有安裝或無法隔離時，桌面仍可使用，也可在 AI 設定改用 API 金鑰。訂閱連線需要 [`tools/codex/pin.json`](../../tools/codex/pin.json) 指定的 `0.160.0`、`x86_64-unknown-linux-musl` 二進位；不要用官方安裝程式目前自動取得的最新版代替。

從倉庫根目錄下載 GitHub release `rust-v0.160.0` 的資產 `codex-x86_64-unknown-linux-musl.tar.gz`。Coordinator 已核對解出的單一檔案 `codex-x86_64-unknown-linux-musl` 與 pin 的 SHA-256 一致；以下步驟仍會在本機重新核對。檔案放在 Ditto 專用資料夾，不覆蓋終端使用的 Codex CLI：

```sh
set -eu
codex_download="$(mktemp -d)"
codex_dir="$HOME/.local/share/ditto/codex/0.160.0"
curl --fail --location --output "$codex_download/codex.tar.gz" \
  https://github.com/openai/codex/releases/download/rust-v0.160.0/codex-x86_64-unknown-linux-musl.tar.gz
tar --extract --gzip --file "$codex_download/codex.tar.gz" --directory "$codex_download" \
  codex-x86_64-unknown-linux-musl
codex_candidate="$codex_download/codex-x86_64-unknown-linux-musl"
printf '%s  %s\n' "$(jq -r .sha256 tools/codex/pin.json)" "$codex_candidate" | sha256sum --check -
install -D -m 0755 "$codex_candidate" "$codex_dir/codex"
DITTO_CODEX_BINARY="$codex_dir/codex" bash packaging/reference-image/install-session.sh
```

SHA-256 必須核對 pin 的 `12eb3e81114588aca3b7998f4f19e8997b056aca08e57a7ca7c8a3ec8c652aad`；核對失敗就停止，不跳過檢查。同 release 另有 `.sigstore` 資產。安裝後登出桌面，再選擇 Ditto 登入；只換檔案而不重跑安裝程式，不會更新原工作階段的路徑。開發 VM 在上述安裝指令末端加上原本的 `--development`；它只略過參考機指紋檢查，仍會探測隔離相容性。

安裝程式也支援未設定 `DITTO_CODEX_BINARY` 時讀取 `~/.local/bin/codex`，但這是次要選項：該位置可能是官方安裝程式管理的自動更新連結。覆寫會改變使用者在終端執行的版本；後續自動更新又可能令 SHA-256 不符。建議持續使用上述 Ditto 專用位置與 `DITTO_CODEX_BINARY`。

### Codex 隔離相容性

Codex 訂閱連線需要 **Landlock ABI ≥6**，且 Landlock 必須可用；版本門檻來自 `crates/ditto-confine/src/main.rs` 的 `MINIMUM_ABI`。核心版本字串不能取代實際 ABI 探測，也不能只因 ABI 足夠就宣稱其他隔離機制均可用。建置後可查詢：

```sh
cargo build --locked --release -p ditto-confine
./target/release/ditto-confine --landlock-abi
```

輸出為 ABI 整數；低於 6 或負值表示這台電腦尚不能提供所需隔離。查詢本身不啟動 Codex、不建立隔離程序。安裝程式即使加了 `--development` 也會印英文警告，並把查詢結果放入登入後的 `$XDG_RUNTIME_DIR/ditto/session.env`：`DITTO_CODEX_LANDLOCK_ABI`，符合 pin 但隔離不足時的 `DITTO_CODEX_STATUS` 為 `isolation_unavailable`。這是安裝時的相容性結果；執行期仍以 Core 回讀為準。

Coordinator 在 Ubuntu 24.04 預設 kernel 6.8 的 VM 實測為 ABI 4。可先安裝 HWE 核心，再重新開機、重跑上述查詢；仍須 ABI ≥6 並確認 Landlock 已啟用：

```sh
sudo apt-get update
sudo apt-get install linux-generic-hwe-24.04
```

確認可用後重跑 Ditto 安裝程式並重新登入。不能升級或系統仍不允許安全隔離時，改用 API 金鑰；不降低隔離要求，也不阻擋桌面使用。

## 凍結內容

- Ubuntu 24.04.2 LTS、kernel `6.17.0-40-generic`。
- AMD Ryzen 9 7945HX、RTX 4060 8 GiB／NVIDIA 570.211.01、60.5 GiB RAM、Crucial P3 Plus 2 TB NVMe。
- Wayfire 0.11.0（wlroots 0.20.2）、Qt 6.10.2、Quickshell 0.3.1。
- Rust 1.98.1、Node 22.23.2、pnpm 10.11.0。
- 參考應用：Firefox 156.0.1-1 rev 8969（原生 Wayland）、foot 1.16.2、Kate 23.08.5；XWayland 只做相容性對照，不屬 EX-01 的參考應用集合。
- 量測輸出固定為 1920×1080、60 Hz、scale 1；實體 Samsung LC34G55T 支援此模式。開發時可使用其他模式，但不得與出口量測混合。

完整且機械可讀的值見 [`reference-machine.lock.json`](reference-machine.lock.json)。

鎖定值變更紀錄：2026-10-09 `memory_kib` 63468948→63468952（`MemTotal` 多 4 KiB，同一硬體與核心；核心保留的記憶體隨韌體／開機變動）。owner 核准後更新。

## 重建與驗證

1. 安裝 Ubuntu 24.04.2 LTS，套用 [`apt-packages.txt`](apt-packages.txt) 的套件集合。
2. 依 [`source-builds.lock`](source-builds.lock) 建置 Wayfire 私有前綴與 Qt／Quickshell。上游來源、tag／commit 與安裝位置都不得浮動。
3. 安裝 `rust-toolchain.toml`、`.nvmrc` 與根目錄 `packageManager` 指定的工具鏈。
4. 執行 `bash packaging/reference-image/capture-fingerprint.sh /tmp/current.json`，再執行 `bash packaging/reference-image/preflight.sh`。
5. 執行 `bash packaging/reference-image/install-session.sh`；它會以鎖定工具鏈建置 release Core、`ditto-supervisor` 與 `dittoctl`，建置 `packages/host-runtime` 的 hostd 與內建套件（`target/ditto-packages`），並安裝「Ditto (Wayfire)」登入管理器項目與 systemd user unit。Core 以受控啟動器啟動 Shell、hostd、救援介面與鎖定客戶端，不使用 development token。hostd 必須跑在 `.nvmrc` 凍結的 Node 上，安裝程式以 `DITTO_NODE`（未設時取 `PATH` 上的 `node`）的正規路徑寫進 unit，版本不符即停止——啟動器比對 `/proc/<pid>/exe`，包裝腳本會被拒絕。G0 的「Ditto G0 (Wayfire)」要在 54ef90b 上安裝，見[下方](#g1-工作階段從-g0-搬到哪裡)。
6. 從登入管理器選擇該工作階段登入，以實體鍵盤完成 `tests/g0/input-method/manual-session.sh`，再執行參考機驗證腳本。

`install-session.sh` 綁定執行當下的工作樹絕對路徑，所以重建者可把倉庫放在不同位置；開發機不需要安裝這個工作階段。登入後的 Wayfire 設定在 `session/wayfire.ini`，不借用使用者家目錄中的第二份配置。

這不是整個產品的安裝包。G0 沒有 Profile、Cordis、Agent 或救援模式；此目錄只重建 G0 原生可行性與出口量測環境。

## 畫面分享與遠端存取

Wayfire 工作階段的 xdg-desktop-portal 原本只有 GTK 後端，沒有 ScreenCast，RustDesk 登入時報 `No such interface "org.freedesktop.portal.ScreenCast"`。`install-session.sh` 安裝兩個設定：

- `session/wayfire-portals.conf` → `/etc/xdg/xdg-desktop-portal/wayfire-portals.conf`：ScreenCast 與 Screenshot 交給 `xdg-desktop-portal-wlr`（讀 Wayfire 的 wlr-screencopy），其餘維持 GTK。
- `session/xdpw-wayfire.conf` → `/etc/xdg/xdg-desktop-portal-wlr/Wayfire`：`chooser_type=none`，不跳選擇視窗，直接分享第一個輸出。

取捨：遠端連線時座位上沒有人可以按同意，所以不設選擇器；代價是這個工作階段裡任何程式要求擷取螢幕都會直接得到畫面。owner 於 2026-10-09 為了遠端存取接受。RustDesk 的輸入走它自己的 uinput，不經 portal。

畫面全黑（2026-10-09 查明）：Ubuntu 24.04 的 `xdg-desktop-portal-wlr` 0.7.1 在用戶端重新連上同一個 screencast stream 時，第一個 buffer 的 `pts` 是 0；GStreamer 的 `pipewiresrc`（PipeWire 1.0.5）以 0 為起點，對下一個真實時間戳（CLOCK_MONOTONIC，開機至今數十小時）做時鐘等待，於是只交出一幀就停住，xdpw 端接著連續 `out of buffers`。RustDesk 每次連線都在一秒內對同一個 stream 重建數次擷取 pipeline（偵測螢幕、`SWITCH` 重整），所以每次都黑。不經 RustDesk 也能重現：同一個 portal session 依序開四個 pipeline，第二個以後只拿到 1 幀。上游 0.8.4 送出正確時間戳，但它的 ext-image-copy 路徑在重連時對同一 session 建第二個 frame，Wayfire 回協定錯誤、portal 退出；`tools/xdpw/` 以 0.8.4 加兩個修補建置（見 `pin.json`），`install-session.sh` 安裝到 `/usr/local/libexec` 並以 user unit drop-in（`session/xdpw-service.conf`）取代發行版的執行檔。修正後同一重現連跑五輪、每輪四次重連都持續出幀（4 秒約 238 幀），RustDesk 恢復畫面。

先前排除的方向：NVIDIA 硬體編碼（改軟體 AV1 仍黑）、RustDesk 的 restore token、重啟 xdpw（偶爾因時機剛好躲過重連）。參考機的螢幕接在 NVIDIA（`card1`），wlroots 預設卻用開機 VGA（AMD iGPU）繪圖再跨 GPU 複製；`ditto-session` 讓 Wayfire 只用 `DITTO_DRM_VENDOR`（預設 NVIDIA `0x10de`）的 GPU，起不來時退回 wlroots 自己的選擇——這與黑畫面無關，是顯示路徑本身的修正。

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
