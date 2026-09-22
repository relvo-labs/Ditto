# 無 GPU 的 Wayland 開發測試

這是 G0 開發用的 headless 工作階段：Debian testing 容器內以 Sway、wlroots headless backend 與 Pixman 軟體渲染啟動一個 1280×720 輸出，並安裝 Qt 6.10 系列與 Quickshell 0.3.1。它可用來測試 Wayland 客戶端、Quickshell QML 面板、視窗列舉、聚焦與工作區切換；不代表 D-01／D-02／D-03 的參考平台與工具鏈選型，也不產生 EX-04／05／09 的真機驗收數字。

主機、容器版本、驗證證據與未完成項目詳見 [平台環境紀錄](../../docs/platform/dev-wayland-environment.md)。

在倉庫根目錄執行：

```sh
bash tools/dev-wayland/run.sh smoke
```

需要查看桌面時執行：

```sh
bash tools/dev-wayland/run.sh vnc
```

VNC 只映射到主機 `127.0.0.1:5900`。在本機用 VNC 用戶端連接該位址；遠端操作時先自行建立 SSH 連接埠轉送。按 `Ctrl-C` 停止容器。

容器建置需要 Docker 與網路，容器的倉庫掛載為唯讀。**容器現在是次要夾具**：主要開發機是裝有 Qt、Quickshell 與 Wayfire 的[工作站](../../docs/platform/dev-wayland-environment.md)，容器保留給 Sway 這一側的對照探測，以及沒有工作站時重現 G0 腳本。Debian testing 沒有 wayfire 套件，Wayfire 一側的探測不能在容器內進行。`quickshell/shell.qml` 只是最初的測試夾具；實際的工作階段在 [`shell/`](../../shell/README.md)。此環境還沒有輸入法；實體 GPU、螢幕熱插拔、輸入法候選視窗位置、幀時與 PSS 預算仍須在 G0 參考機驗證。

煙霧測試執行[合成器探針](../compositor-probe/README.md)的第一層（Wayland global 列舉）。第二層功能探測與其他 G0 驗證腳本經 `bash tests/g0/run-in-container.sh <script>` 在同一個容器內執行。
