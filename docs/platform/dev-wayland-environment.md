# 開發 VM 的 Wayland／Qt／Quickshell 測試環境

| 項目 | 紀錄 |
| --- | --- |
| 日期 | 2026-09-19 |
| G0 整體 owner | Lei-k |
| 用途 | 在沒有 GPU 的開發 VM 上，先驗證 Wayland 客戶端與最小 Quickshell QML 面板能啟動，供 G0 實作與除錯 |
| 狀態 | 開發測試環境已建置並通過下列煙霧測試；**不是** G0 參考機或正式支援矩陣 |

這份文件記錄目前環境的實測事實。G0-PLAT-01／02 的正式版本凍結、[支援矩陣](../../plan/02/02-platform-and-compositor.md#2-凍結維度g0-plat-01)及 D-01／D-02／D-03 決策尚未完成。以下版本只屬於這個開發容器，不能直接作為產品支援版本或 G0 出口證據。

## 主機與容器

主機是 Ubuntu 22.04.5 LTS 的 KVM VM，Linux `5.15.0-186-generic`、8 vCPU、約 11 GiB RAM；目前沒有 `/dev/dri`、實體顯示輸出或既有 Wayland 登入工作階段。Docker 可用，主機帳號沒有免密碼 `sudo`。主機套件來源提供的 Qt 6.2.4 低於 [Quickshell 的 Qt 6.6 最低需求](https://github.com/quickshell-mirror/quickshell/blob/master/BUILD.md)，因此 Qt 與 Quickshell 安裝在開發容器內，主機不需改動。

容器定義在 [Dockerfile](../../tools/dev-wayland/Dockerfile)，以 `debian:testing@sha256:16faa8d1cd99fcb2d30eebe90454e26b20499055fa7094e9b55d32d1a7666f08` 為基底。2026-09-19 建置時，映像的系統標示為 Debian `forky/sid`，已安裝版本如下：

| 元件 | 容器內版本 | 用途 |
| --- | --- | --- |
| Sway | `1.12-1` | wlroots 合成器；僅作開發夾具，不代表 D-02 選型 |
| Qt Base／Declarative／Wayland | `6.10.2` 系列 | Qt Quick 與原生 Wayland 平台外掛；含開發標頭 |
| Quickshell | `0.3.1-1` | 載入最小 QML 面板 |
| foot | `1.28.0-1` | 原生 Wayland 測試視窗 |
| wayvnc | `0.10.1-1` | 檢視 headless 畫面 |
| Weston | `16.0.0-1` | 後續開發探測可用；本次未測試 |
| Xwayland | `2:24.1.13-1` | 後續對照測試可用；本次未測試 |
| wayland-utils | `1.3.0-1` | `wayland-info` 全域列舉 |
| Python | `3.14.7-3` | 探針 JSON 輸出 |

後續加入 `wayland-utils` 與 `python3`，供 [合成器探針](../../tools/compositor-probe/README.md)列舉 globals。2026-09-19 重新建置容器並重跑煙霧測試，`wl_compositor` 出現在結構化輸出中；這仍不是 C-01～C-14 的功能判定。

容器以 `WLR_BACKENDS=headless`、`WLR_RENDERER=pixman`、`WLR_HEADLESS_OUTPUTS=1` 啟動一個 1280×720 的虛擬輸出，並以 `QT_QPA_PLATFORM=wayland`、`QT_QUICK_BACKEND=software` 執行 QML。這些設定只為無 GPU 的功能除錯；Qt 的[軟體 scene graph](https://doc.qt.io/qt-6/qtquick-visualcanvas-adaptations.html)不代表正式 GPU 渲染路徑。容器的倉庫掛載為唯讀，VNC 只映射到主機 `127.0.0.1:5900`。

## 重現與已驗證結果

在倉庫根目錄執行：

```sh
bash tools/dev-wayland/run.sh smoke
```

煙霧測試啟動 Sway、建立原生 Wayland `foot` 視窗，再以 `swaymsg` 回讀輸出、視窗焦點與工作區狀態；隨後載入 [Quickshell 測試面板](../../tools/dev-wayland/quickshell/shell.qml)。2026-09-19 的結果：1280×720 輸出、視窗列舉與聚焦、切換至工作區 2、Quickshell QML 載入及程序存活，全部通過。另以 VNC 的原始 framebuffer 回讀確認頂部面板的像素為測試 QML 設定的 `#253447`，因此不只驗證了程序啟動，也驗證了面板實際出現在畫面上。

需要查看畫面時執行：

```sh
bash tools/dev-wayland/run.sh vnc
```

在同一台主機用 VNC 用戶端連接 `127.0.0.1:5900`；若從遠端操作，先自行設定 SSH 連接埠轉送。按 `Ctrl-C` 停止容器。執行方式與範圍見 [測試工具說明](../../tools/dev-wayland/README.md)。

## 尚待補齊

- **參考機與 GPU**：Lei-k 將另行準備實體 GPU／參考機。硬體、驅動、實體螢幕、真機 runner 和套件快照尚未凍結；目前沒有 EX-04／05／09 可用的幀時、PSS 或 nightly 數據。
- **正式桌面能力**：這個容器現在也用來跑 [Ditto Shell](../../shell/README.md)、Core 與[兩層合成器探針](../../tools/compositor-probe/README.md)；`tools/dev-wayland/quickshell/shell.qml` 仍只是最初的面板夾具。已取得 C-01～C-06 的功能探測結果，**C-07（點擊穿透）與 C-08（輸入法）在此環境無法探測**，登入管理器工作階段也尚未建立。`swaymsg` 的觀察不能代替[功能探測](../../plan/02/02-platform-and-compositor.md#4-合成器能力盤點g0-plat-03)。
- **輸入與相容性**：尚未安裝或驗證 fcitx5 中文輸入、候選視窗位置、實體輸入裝置、螢幕熱插拔、Xwayland 對照組及 Wayfire；這些仍需依 G0 計畫逐項測試。
- **版本可重建性**：Docker 基底 digest 已固定，但 `apt-get` 仍讀取會變動的 Debian testing 套件庫。這是暫時的開發環境，不能充當 `packaging/reference-image/` 所要求的可重建參考映像；G0-PLAT-01／02 必須另行固定倉庫快照、套件版本與版本指紋。

後續實體機到位後，依 [G0 平台計畫](../../plan/02/02-platform-and-compositor.md)建立正式支援矩陣與 runner；本文件保留為 VM 開發環境紀錄，不將測試結果升格為出口通過。
