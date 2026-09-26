# G0 合成器探針

兩層，合成器中立：換合成器時只換標籤，不改探針程式碼。

| 層 | 做什麼 | 為什麼需要它 |
| --- | --- | --- |
| 全域列舉 | `wayland-info` 列出所有 Wayland global 與版本 | 快、可完全自動化；但**公告存在不等於實作完整** |
| 功能探測 | 對每項能力實際執行一次最小操作並回讀 | 唯一能分辨「支援」與「部分支援」的方法 |

在已登入的 Wayland 工作階段中執行：

```sh
tools/compositor-probe/run.sh <compositor-label>               # 只做第一層
tools/compositor-probe/run.sh <compositor-label> --functional  # 兩層合併成一份 JSON
```

功能層對合成器的每一次查詢都經過 [`functional/compositor.sh`](functional/compositor.sh)，由 `DITTO_COMPOSITOR` 選後端（`sway` 或 `wayfire`）。後端不把自己的模型轉換成另一個的形狀——工作區是具名清單還是固定格線、exclusive zone 從視窗位置還是 work area 量到，都照實記錄，因為這些差異正是合成器決策的依據。Wayfire 沒有相容於 sway 的 IPC，其查詢走 [`functional/wayfire-ipc.py`](functional/wayfire-ipc.py)。

工作站上對 Wayfire 的完整流程（自行啟動合成器並保存 artifacts）：

```sh
export PATH=~/wayfire/bin:$PATH LD_LIBRARY_PATH=~/wayfire/lib
DITTO_COMPOSITOR=wayfire DITTO_WORKSPACE=$PWD \
DITTO_ARTIFACTS=$PWD/artifacts/g0 DITTO_BINARIES=$PWD/target/debug \
WLR_RENDERER=gles2 bash tests/g0/compositor-probe/run.sh
```

開發容器內對 Sway 的對照流程：

```sh
bash tests/g0/run-in-container.sh compositor-probe
```

## 功能探測目前做了什麼

| 列 | 做法 |
| --- | --- |
| C-01 | 掛上 40 px exclusive zone 的 layer-shell 面板，比較同一個視窗在面板出現前後的位置；**必須恰好位移 40 px**，這樣才不會把視窗裝飾誤認成 exclusive zone |
| C-02／C-03 | 以中立的 foreign-toplevel 介面列舉視窗，再逐項請求 activate／maximize／fullscreen／minimize 並回讀協定回報的狀態 |
| C-04／C-05 | 記錄中立協定是否涵蓋；座標與工作區的實際結果來自[視窗能力矩陣](../../tests/g0/window-matrix/run.sh) |
| C-06 | 輸出列舉（熱插拔屬於實體參考機） |
| C-07 | 以合成器可用的合成輸入雙向驗證透明區穿透與實心區接收 |
| C-08 | 交由獨立輸入法診斷與實體鍵盤流程；本探針只如實標記未判定 |
| C-09 | 以真實指標 serial 取得 `xdg_activation_v1` token，啟用另一個 surface 並回讀焦點 |
| C-10 | 發出最小 session lock，收到 `locked` 後立即 `unlock_and_destroy` |
| C-11／C-14 | 依 G0 範圍列舉對應後端與 global |
| C-12 | 建立 surface 並取得三次 `wp_presentation` feedback |
| C-13 | 啟動 xterm，以 XWayland 視窗重跑 C-02／C-03 |

輸出的 `coverage` 會是 `globals_only` 或 `globals_and_functional`。沒有功能結果的列不會得到四態判定；差異表見 [`docs/platform/compositor-capability-matrix.md`](../../docs/platform/compositor-capability-matrix.md)。

需要套件：`python3`、`wayland-utils`、`jq`，功能層另需 `quickshell`、`xterm`、C 編譯器、`wayland-scanner` 與 `wayland-protocols`。正式參考機的套件版本在平台凍結時記錄。
