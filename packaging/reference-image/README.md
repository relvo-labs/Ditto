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
5. 執行 `bash packaging/reference-image/install-session.sh`；它會以鎖定工具鏈建置 release Core，並安裝「Ditto G0 (Wayfire)」登入管理器項目。Core 以受控啟動器啟動 Shell，不使用 development token。
6. 從登入管理器選擇該工作階段登入，以實體鍵盤完成 `tests/g0/input-method/manual-session.sh`，再執行參考機驗證腳本。

`install-session.sh` 綁定執行當下的工作樹絕對路徑，所以重建者可把倉庫放在不同位置；開發機不需要安裝這個工作階段。登入後的 Wayfire 設定在 `session/wayfire.ini`，不借用使用者家目錄中的第二份配置。

這不是整個產品的安裝包。G0 沒有 Profile、Cordis、Agent 或救援模式；此目錄只重建 G0 原生可行性與出口量測環境。
