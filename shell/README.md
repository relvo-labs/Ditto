# Ditto Shell（G0）

Quickshell／QML 的桌面工作階段：背景、頂部面板、底部 Dock、角色層。對應 [plan/02/04](../plan/02/04-shell-and-avatar.md) 的 G0-SHELL-01～04。

## 這個工作階段目前做到什麼

- 面板與 Dock 以 layer-shell 掛載，exclusive zone 生效（實測：平鋪視窗被擠到面板與 Dock 之間）。
- 視窗與工作區資料**只**來自 `desktop.events.subscribe` 的快照與後續事件；啟動後的整個閒置、游標與拖曳期間不再發出任何請求。
- 角色的呼吸、眨眼、注視與點擊回彈全部在本機插值；**終止 `ditto-core` 後角色照常動**。
- 角色視窗的輸入區來自 `avatar/layers/hit-mask.json`，由 alpha 通道在建置期產生（24 個矩形）。
- 能力不可用時不顯示會失敗的按鈕；Core 未連線時面板顯示真實狀態，不假裝有資料。

## 這個工作階段還沒做到什麼

- **幀時尚未形成出口數字**：熱路徑 RPC 已是 0，但 EX-04 還需要參考機固定條件的三次幀時結果。
- 登入管理器項目已可安裝，但仍需從實體登入管理器進入一次，完成參考應用與輸入法驗證。
- 連線中斷後無法自動復原：一次性 token 已用掉，介面會顯示「需重新啟動工作階段」。工作階段監督是 G1。
- 只有一個 Dock 供應者。第二個供應者（DES-10）屬於 G1，現在做會把還沒定案的契約寫死。
- 角色只有待命狀態。思考／執行等狀態沒有對應任務，AVA-04 禁止用動畫表示它們。

## 執行

Core 自己啟動 Shell，身分由啟動器綁定：

```sh
ditto-core serve --compositor wayfire \
  --launch "quickshell 0.3.1 /usr/bin/quickshell -p shell/shell.qml"
```

開發時也可以先啟動 `ditto-core serve --development`（共用 token，**不是身分證據**），再自行執行 `quickshell -p shell/shell.qml`。

控制路徑（合成器的快捷鍵綁在這上面）：

```sh
shell/tools/recall.sh                 # 角色被遮住時喚回
shell/tools/recall.sh "workspace 2"   # 與點擊面板同一條能力路徑
```

環境開關：`DITTO_REDUCED_MOTION=1`、`DITTO_REDUCED_TRANSPARENCY=1`、`DITTO_FRAME_PROBE=1`。

## 結構

| 路徑 | 內容 |
| --- | --- |
| `shell.qml` | 各表面的宣告；背景、面板、Dock、角色視窗、控制 socket |
| `core/DittoClient.qml` | 唯一的桌面資料來源：握手、能力目錄、訂閱、投影、重連 |
| `core/RpcCounter.qml` | 每個請求都計數並印出時間戳，供熱路徑驗證腳本判讀 |
| `jelly/Tokens.qml` | token 最小集；每個顏色有降低透明度版本，每個時長有減少動畫版本 |
| `avatar/` | 角色元件、命中遮罩、幀時取樣 |
| `providers/panel_top`、`providers/dock_bottom` | 兩個表面供應者（目錄名用底線：QML 模組名不接受連字號） |

素材來源與授權狀態見 [`avatar/layers/SOURCES.md`](avatar/layers/SOURCES.md)。

命中區有兩層證據：合成器中立的一矩形夾具，以及 `tests/g0/avatar-hit-region/run.sh` 對生產用 24 矩形遮罩的直接測試；兩者都要求透明區穿透、實心區接收事件。
