# 開發工作站與 Wayland／Qt／Quickshell 環境

| 項目 | 紀錄 |
| --- | --- |
| 日期 | 2026-09-22 |
| G0 整體 owner | Lei-k |
| 用途 | G0 的**主要開發機**：原生桌面切片、合成器能力探測與除錯都在這台執行 |
| 狀態 | 已建置並通過下列實測；**不是** G0 參考機，也不是凍結的支援矩陣 |

這份文件記錄目前環境的實測事實。G0-PLAT-01／02 的正式版本凍結、[支援矩陣](../../plan/02/02-platform-and-compositor.md#2-凍結維度g0-plat-01)及 D-01／D-02／D-03 決策尚未完成。以下版本只屬於這台工作站，不能直接作為產品支援版本或 G0 出口證據。

2026-09-19 的紀錄描述的是一台沒有 GPU 的 KVM 開發 VM，Qt 與 Quickshell 只存在於容器內、主機不做改動。**那個安排已經被取代。** 主要開發機改為下述工作站，Qt、Quickshell 與 Wayfire 直接裝在其上；開發容器降為已遺棄路徑的對照，見 [§5](#5-開發容器已遺棄的對照)。

## 1. 工作站

| 項目 | 實測值 |
| --- | --- |
| OS | Ubuntu 24.04.2 LTS |
| 核心 | `6.17.0-40-generic`（HWE meta 已 `apt-mark hold`，見下） |
| CPU／記憶體 | 32 執行緒／60 GiB |
| GPU | NVIDIA RTX 4060（驅動 570.211.01）＋ AMD Raphael iGPU；`/dev/dri` 有 `card0`、`card1`、`renderD128`、`renderD129` |
| 桌面工作階段 | GNOME on Wayland（`loginctl` 回報 `Type=wayland`、seat0） |

**核心被固定在 6.17.0-40。** NVIDIA 570.211.01 的 DKMS 模組無法對 kernel 7.0 編譯（`nv-mmap.c: VMA_LOCK_OFFSET undeclared`，7.0 改了 vma refcount API），因此 `linux-generic-hwe-24.04`、`linux-image-generic-hwe-24.04`、`linux-headers-generic-hwe-24.04` 三個 meta 套件處於 hold。解除 hold 的前提是 NVIDIA 出能編過 7.0 的驅動；在那之前這台不會收到核心更新。

GNOME／Mutter 不提供 `wlr-layer-shell`，所以 Ditto Shell **不能**掛在登入後的桌面工作階段上；面板與 Dock 需要一個 wlroots 系合成器，見 [§2](#2-合成器wayfire)。

## 2. 合成器：Wayfire

D-02 已於 2026-09-22 決定採用 Wayfire，Sway 支援標為遺棄（[決策紀錄](../../.agents/notes/decisions/2026-09-22-d02-compositor-wayfire.md)）。Ubuntu 24.04 套件庫只有 `0.8.0+git20240110`（2024-01 快照），拿它判定一個要活到 G5 的決策不成立，所以改從源碼建置上游版本。

| 元件 | 版本 | 來源 |
| --- | --- | --- |
| Wayfire | `0.11.0-d3990237` | 上游 `v0.11.0` tag，meson 建置，前綴 `~/wayfire` |
| wlroots | `0.20.2` | Wayfire 的 meson subproject |
| libwayland | `1.26.0` | 私有前綴（Ubuntu 為 1.22.0，低於 wlroots 0.20 要求的 1.24） |
| wayland-protocols | `1.49` | 私有前綴（Ubuntu 為 1.45，低於要求的 1.47） |
| libdrm | `2.4.134` | 私有前綴（Ubuntu 為 2.4.125，低於要求的 2.4.129） |
| pixman | `0.46.4` | 私有前綴（Ubuntu 為 0.42.2，低於要求的 0.43） |
| libxkbcommon | `1.9.2` | 私有前綴（Ubuntu 為 1.6.0，低於要求的 1.8） |

整條鏈都裝在 `~/wayfire`，不覆蓋系統套件。執行前需要：

```sh
export PATH=~/wayfire/bin:$PATH LD_LIBRARY_PATH=~/wayfire/lib
```

**這條依賴鏈不對應任何發行版的組合**，因此它適合用來探測 Wayfire 的協定與行為，不適合用來推論封裝可行性；`packaging/reference-image/` 的版本凍結仍須另行處理。

合成器夾具設定在 [`tools/dev-wayland/wayfire.ini`](../../tools/dev-wayland/wayfire.ini)。Wayfire 把多數 Wayland 協定放在 plugin 後面，只載少數 plugin 量到的是那份清單而不是合成器本身，因此夾具載入的是能力差異表有對應列的協定 plugin。

## 3. Qt 與 Quickshell

Ubuntu 24.04 的 Qt 是 6.4.2，低於 [Quickshell 的 Qt 6.6 最低需求](https://github.com/quickshell-mirror/quickshell/blob/master/BUILD.md)，且 Quickshell 連結 Qt private API、必須與執行時的 Qt 同版重建，因此兩者都不走 apt。

| 元件 | 版本 | 位置 |
| --- | --- | --- |
| Qt | `6.10.2`（`qtshadertools`、`qtimageformats` 模組） | `~/Qt/6.10.2/gcc_64`，aqtinstall 取得 |
| Quickshell | `0.3.1`（revision `1a4716c`） | 安裝進同一個 Qt 前綴；`quickshell`、`qs` symlink 於 `~/.local/bin` |
| cpptrace | 源碼建置，開啟 `CPPTRACE_UNWIND_WITH_LIBUNWIND` | `/usr/local`；Quickshell 的崩潰回溯要求 signal-safe unwind |

Qt 版本刻意與開發容器一致（6.10.2），因此容器與工作站的 Shell 行為可以互相對照。Quickshell 安裝在 Qt 前綴內，是為了讓「重建 Quickshell」與「換 Qt」成為同一件事：升 Qt 就是裝一棵新的 Qt 樹再重建，舊的不受影響。

其餘工具鏈：Rust `1.98.1`（`rust-toolchain.toml` 釘選）、Node `22.23.2`（`.nvmrc`，nvm 的 `default` 別名已指向它）、pnpm `10.11.0`、Docker `28.1.1`。

## 3.1 開發與驗證工具

| 用途 | 套件 | 版本 |
| --- | --- | --- |
| 輸入法（C-08／EX-08） | `fcitx5`、`fcitx5-chewing`、`fcitx5-chinese-addons`、`fcitx5-config-qt`、`fcitx5-frontend-qt5`／`qt6` | 5.1.x |
| 中文字型 | `fonts-noto-cjk` | 20230817 |
| 參考應用：終端機 | `foot` | 1.16.2 |
| 參考應用：瀏覽器 | `firefox`（snap，原生 Wayland）、`google-chrome-stable`（XWayland 對照） | 1snap1／148.0 |
| 參考應用：編輯器 | `kate`（原生 Wayland GUI，`.kate-swp` 可外部檢查）、`neovim`（swap 檔可外部檢查） | 23.08.5／0.9.5 |
| XWayland 對照（C-13） | `xterm`、`x11-apps` | 390 |
| 剪貼簿與截圖 | `wl-clipboard`、`grim`、`slurp` | 2.2.1／1.4.0／1.5.0 |
| 沙箱與秘密（G3／D-09） | `bubblewrap`、`gnome-keyring`、`libsecret-tools` | 0.9.0／46.1／0.21.4 |
| 量測與除錯 | `perf`（`linux-tools-6.17.0-40-generic`）、`gdb` | 6.17.13／15.0 |

**參考應用集合尚未凍結。** 上表是候選，D-01 才決定哪一組進 EX-01／EX-03。編輯器一欄放了兩個，因為 [2.1 的判準](../../plan/02/02-platform-and-compositor.md#21-參考應用集合)要求未儲存緩衝可從外部檢查，而這兩個都做得到、其餘常見編輯器做不到。

### 輸入法：兩條路只有一條可用

Wayland 原生路徑成立：fcitx5 以 `libwaylandim.so` 走 `zwp_input_method_v2`，應用走 `zwp_text_input_v3`，Qt 在 Wayland 上不需要額外的輸入法 plugin，`QT_IM_MODULE` 應**保持未設定**。夾具內實測：兩個 global 都公告、fcitx5 常駐、其 D-Bus 介面回應，注音（chewing）等引擎可用。

Qt plugin 路徑**不可用**：系統的 `libfcitx5platforminputcontextplugin.so` 是對 Ubuntu 的 Qt 6.4.2 編的，載入 Qt 6.10.2 時失敗：

```
undefined symbol: _ZN22QWindowSystemInterface22handleExtendedKeyEvent... , version Qt_6_PRIVATE_API
```

這與 Quickshell 是同一條規則——連結 Qt private API 的東西必須對執行時的 Qt 重建。要走這條路就得自行重建 fcitx5-qt；在 Wayland 原生路徑可用的前提下沒有必要。

### 工作階段用的 D-Bus

fcitx5 需要 session bus。G0 夾具原本沒有，現在 `tests/g0/lib/session.sh` 會自己起一個 `dbus-daemon --session`（不借用開發者的現有工作階段，避免測試伸手進去），並在收尾時關掉。沒有 `dbus-daemon` 時夾具照常運作，只是需要它的項目無法測。

夾具內 fcitx5 仍會對 `org.freedesktop.portal.Settings` 報錯——那是因為夾具沒有 xdg-desktop-portal，不影響輸入法本身。

## 3.2 登入管理器的 Wayfire 工作階段

Wayfire 與其依賴鏈裝在 `~/wayfire`，不是系統套件，所以工作階段必須自己設定路徑：

| 檔案 | 內容 |
| --- | --- |
| `/usr/local/bin/wayfire-ditto` | 包裝腳本：設定 `PATH`、`LD_LIBRARY_PATH`、`XDG_CURRENT_DESKTOP`、`XMODIFIERS`，並確保 `QT_IM_MODULE` 未設定 |
| `/usr/share/wayland-sessions/wayfire-ditto.desktop` | 登入畫面的「Wayfire (Ditto development)」項目 |
| `~/.config/wayfire.ini` | 真實工作階段的設定，載入 Core 轉接需要的 `ipc`、`ipc-rules`、`wm-actions`、`vswitch`，並開啟 `enable_input_method_v2` |

**工作階段只啟動合成器**，不自動啟動 Core 與 Shell。工作階段監督是 G1；讓登入工作階段自動拉起一個沒有監督的 Core，失敗會變成一片黑畫面而不是可讀的錯誤。要移除這個登入項目，刪掉上面前兩個檔案即可。

這個項目**尚未實際登入驗證過**——它在 headless 後端下起得來，但用實體螢幕、實體輸入裝置從登入管理器進入的流程還沒跑過。

## 4. 已驗證結果

### 4.1 Rust 與契約

CI 的全部檢查在這台通過：`cargo fmt --check`、`cargo clippy -D warnings`、`cargo test --workspace`、`export-schema --check`、`pnpm install --frozen-lockfile`、`check:generated`、`typecheck`、`@ditto/protocol` 測試、avatar hit-mask `--check`、`lint-skills --check`。

`ditto-core` 訂閱測試家族原本約每十次失敗一次（`ConnectionReset`）。原因是測試自身的競態：`finish()` 關閉 socket 時連線可能還在寫已發布的事件。已修正——那是測試自己造成的關閉，其餘錯誤仍然失敗。修正後連跑 15 次全過。

### 4.2 合成器探測

Wayfire 以 headless backend ＋ `gles2`（實體 GPU）啟動 1280×720 輸出，兩層探針都跑完：

```sh
export PATH=~/wayfire/bin:$PATH LD_LIBRARY_PATH=~/wayfire/lib
DITTO_COMPOSITOR=wayfire DITTO_WORKSPACE=$PWD \
DITTO_ARTIFACTS=$PWD/artifacts/g0 DITTO_BINARIES=$PWD/target/debug \
WLR_RENDERER=gles2 bash tests/g0/compositor-probe/run.sh
```

結果與 Sway 的對照見[能力差異表](compositor-capability-matrix.md)。原始文件在 `artifacts/g0/compositor-probe-wayfire-0.11.0-d3990237-*.json`。

### 4.3 G0 腳本

在工作站對 Wayfire 跑通：`compositor-probe`（含 C-07）、`window-matrix`、`shell-session`、`identity-negative`、`hotpath`。已遺棄的 Sway 路徑在容器內仍可重現，結果與改動前一致。

`quota-baseline` 在這台**第一次三個案例全部生效**（容器沒有 `systemd --user`，舊 VM 的 CPU 配額不生效）：記憶體、CPU（20% 配額取得 0.202 wall time）、程序數。同時量到 Landlock ABI 7 與可用的 Secret Service，兩者都與舊 VM 相反。逐項見[工具配額基線](resource-quota-baseline.md)。

## 5. 開發容器（已遺棄的對照）

容器定義在 [Dockerfile](../../tools/dev-wayland/Dockerfile)，Debian testing 基底，內含 Sway 1.12、Qt 6.10.2、Quickshell 0.3.1、foot、wayvnc、wayland-utils。**Debian testing 沒有 wayfire 套件**，所以容器內只有已遺棄的 Sway 路徑。

它現在的唯一用途是重現 D-02 決策所依據的 Sway 對照；`tests/g0/run-in-container.sh` 因此明確帶入 `DITTO_COMPOSITOR=sway`，不吃預設值。新的驗證都在工作站上跑。

## 6. 尚待補齊

- **參考機與真機 runner**：硬體、驅動、實體螢幕、套件快照與 nightly runner 尚未凍結；目前沒有 EX-04／05／09 可用的幀時、PSS 或 nightly 數據。這台工作站是開發機，不是參考機——即使它有 GPU，結果仍是開發證據。
- **C-08 中文輸入**：工具已備齊且鏈路在夾具內接得起來（見 [3.1](#31-開發與驗證工具)），但 **[G0-PLAT-04](../../plan/02/02-platform-and-compositor.md#6-輸入法鏈路g0-plat-04) 的五個步驟一個都還沒跑**：輸入法群組未設定、沒有在 QML 文字元件／終端／編輯器三處輸入過中文、候選視窗位置未驗、剪貼簿互通未驗。`docs/platform/input-method-report.md` 尚不存在。**這是 D-02 唯一未結的判準。**
- **C-07 的驗證範圍**：雙向點擊已在 Wayfire 上成立，但用的是單矩形夾具，不是角色層實際的 24 個矩形；實體輸入裝置也還沒測。
- **版本可重建性**：Qt 來自 aqtinstall、Wayfire 與其依賴鏈來自上游 git tag，兩者都不是凍結快照；G0-PLAT-01／02 必須另行固定來源與版本指紋。
- **登入管理器工作階段**：登入項目已建立（[3.2](#32-登入管理器的-wayfire-工作階段)），但**還沒有真的從登入管理器進去過**；目前的探測都是從既有 GNOME 工作階段內以 headless backend 啟動，沒有實體輸入裝置與實體螢幕。
