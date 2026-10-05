# D-33 布局策略在 Wayfire 上的實作路徑

| 欄位 | 內容 |
| --- | --- |
| 提案日期 | 2026-09-27 |
| 狀態 | **提案**（未決定）。決策時點依 [plan/03/08](../../../plan/03/08-decisions-and-risks.md) 為 W3，由平台＋產品核定；核定後才回寫 `milestones/01/05` 與 plan/03 |
| 提案者 | 平台工程 |

## 結論（提案）

Wayfire 0.11.0 可以在執行期切換平鋪策略，所以 `layout.strategy` 的切換**做成受控交接**（prepare → 切換 → 幾何回讀），不降為工作階段重啟等級。G1-R4 的平鋪部分不觸發，EX1-01 ③ 的語意不需要改。

條件是：**既有視窗的交接由轉接層自己做**。Wayfire 載入或卸載 `simple-tile` 時不會替既有視窗處理：載入後既有視窗維持浮動，卸載時已平鋪的視窗停在平鋪幾何。轉接層必須用 `set-layout` 與 `configure-view` 明確完成兩個方向的交接，並記住每個視窗平鋪前的浮動幾何。

快捷鍵（C-16）也有執行期路徑，G1-R4 的快捷鍵部分同樣不觸發；建議路徑見下方「實作說明」第 2 節。

## 依據

全部是**開發證據（headless）**，不是出口門檻結果：

- C-15：`artifacts/g1-dev/compositor-probe/c15-2026-09-27T09:30:54Z-54ef.json`。逐步回讀見[差異表 §7](../../../docs/platform/compositor-capability-matrix.md#7-g1-探測c-15c-19開發證據headless)。
- C-16：`artifacts/g1-dev/compositor-probe/c16-2026-09-27T09:30:54Z-54ef.json`。
- 探測腳本：`tools/compositor-probe/g1/`（`bash tools/compositor-probe/g1/run.sh c15 c16`）。
- IPC 參數與行為另讀 Wayfire 0.11.0 原始碼（`d3990237`）：`plugins/tile/tile-ipc.hpp`、`plugins/ipc-rules/ipc-utility-methods.hpp`、`plugins/single_plugins/command.cpp`。

C-15 的關鍵觀察：

1. `wayfire/set-config-options {"core/plugins": "… simple-tile"}` 回 `ok`，`simple-tile/get-layout` 隨即可用。
2. 已存在的視窗不會被平鋪，新開的視窗才會。`set-layout` 可以把既有視窗放進樹，回讀為預期的三欄。
3. 平鋪中卸載 plugin，視窗停在平鋪幾何、`tiled-edges=15`。對每個視窗送 `configure-view {"tiled-edges":0,"geometry":…}` 可以回到浮動幾何。
4. `set-layout` 移出某視窗後，它離開樹，但仍回報 `tiled-edges=15` 與舊幾何。所以「移出樹」和「回到浮動」是兩個步驟。
5. 重新載入 plugin 後樹是空的。

尚未探測：非目前工作區（格線中其他格）的 `set-layout`、多輸出（多個 wset）、最小化與全螢幕視窗進入樹、實體 GPU 工作階段。

## 考慮過但沒選的方案

- **降為工作階段重啟等級**：C-15 顯示執行期可以切換，沒有理由接受 EX1-01 ③ 的語意變更。
- **`simple-tile` 常駐，只切 `simple-tile/tile_by_default`（`all`／`none`）**：C-15 ④ 證實 `none` 時新視窗浮動，也不必重新載入 plugin。沒選的原因是浮動策略下 `simple-tile` 自己的綁定（`<super> KEY_T`、`<super> BTN_LEFT` 等）仍然有效，而且浮動策略就不再等於 G0 能力矩陣量過的「無平鋪 plugin」狀態。若 W3 前發現 plugin 卸載有副作用，這是第一備案；但要另外探測能不能把那些綁定關掉。
- **寫 Wayfire C++ 外掛補能力**（D-33 的原備案）：現有 IPC 已經夠用，不需要接手維護合成器外掛。
- **以重啟合成器套用**：plan/03/05 §6.2 明文禁止。

## 影響

- `crates/ditto-compositor` 需要新增兩個 `core_builtin` 供應者：`wayfire-floating` 與 `wayfire-simple-tile`。`LayoutStrategyInfo.runtime_switchable` 在 Wayfire 上為 `true`。
- **現有轉接要改一處判斷**：`wayfire.rs` 的 `window_state()` 把 `tiled-edges == 15` 當成 `Maximized`，`floating_geometry()` 把非零 `tiled-edges` 當成平鋪。`simple-tile` 載入後，平鋪視窗也回報 15，最大化與平鋪在 `list-views` 裡無法區分。平鋪策略啟用時，要以 `get-layout` 的樹判斷視窗是否平鋪，樹外的 15 才是最大化。
- 快捷鍵：Profile `shortcuts` 的綁定與回讀可以留在合成器轉接中，不需要 Shell 的 layer-shell 鍵盤獨占。
- 核定後回寫：`milestones/01/05` 的 D-33 列、plan/03/08 的 D-33／G1-R4、plan/03/05 §6.1。

## 實作說明（給 `crates/ditto-compositor`）

框架與 G0 相同：4 位元組原生位元組序長度標頭，加一個 JSON 物件，`{"method": …, "data": {…}}`。`W` 是 wset-index（`window-rules/list-outputs` 的 `wset-index`），`(X, Y)` 是格線座標。

### 1. `layout.strategy`

**浮動 → `wayfire-simple-tile`**

prepare（不改任何狀態）：

```json
{"method": "wayfire/configuration", "data": {}}
```

以回應的 `plugin-path` 確認 `<plugin-path>/libsimple-tile.so` 存在；不存在就在 prepare 失敗，原因是合成器缺少 plugin。

```json
{"method": "wayfire/get-config-option", "data": {"option": "core/plugins"}}
```

記下 `value`，回復要用。同時以 `window-rules/list-views` 記下每個 toplevel 的 `geometry`，作為之後還原浮動幾何的依據。這份資料是執行期狀態，不是權威，放在轉接層記憶體即可。

切換：

```json
{"method": "wayfire/set-config-options", "data": {"core/plugins": "<原值> simple-tile"}}
```

plugin 在合成器的下一個 idle 才載入。輪詢 `simple-tile/get-layout`，直到回 `{"result":"ok",…}`，上限約 1 秒；逾時就當 prepare 失敗並回復。

```json
{"method": "simple-tile/get-layout", "data": {"wset-index": 1, "workspace": {"x": 0, "y": 0}}}
```

接著把既有視窗放進樹。每個有視窗的格位送一次；視窗屬於哪一格沿用現有轉接的推導：

```json
{"method": "simple-tile/set-layout", "data": {"wset-index": 1, "workspace": {"x": 0, "y": 0},
  "layout": {"vertical-split": [{"weight": 1.0, "view-id": 3}, {"weight": 1.0, "view-id": 5}]}}}
```

`weight` 必須是數字；只有一個視窗時也用 `vertical-split` 包一層。不要把未 map 的視窗放進樹（回 `Cannot tile pending-unmapped views!`），同一視窗也不能出現兩次。

readback：

- 每一格的 `simple-tile/get-layout` 樹中含有預期的 `view-id`。
- `window-rules/list-views` 中，這些視窗的 `tiled-edges == 15`，幾何落在輸出的 `workarea` 內。
- 兩者都成立才算完成。

**`wayfire-simple-tile` → 浮動**

1. 對每個有樹的格位清空樹：
   ```json
   {"method": "simple-tile/set-layout", "data": {"wset-index": 1, "workspace": {"x": 0, "y": 0}, "layout": {"vertical-split": []}}}
   ```
2. 對每個原本在樹中的視窗還原浮動幾何。幾何取自平鋪前的記錄；沒有記錄的（平鋪後才開的視窗），轉接層在 `workarea` 內給一個預設位置：
   ```json
   {"method": "window-rules/configure-view", "data": {"id": 3, "tiled-edges": 0, "geometry": {"x": 100, "y": 100, "width": 700, "height": 500}}}
   ```
3. 卸載 plugin：
   ```json
   {"method": "wayfire/set-config-options", "data": {"core/plugins": "<不含 simple-tile 的清單>"}}
   ```
4. readback：`simple-tile/get-layout` 回 `{"error":"No such method found!",…}`（plugin 已卸載），且 `list-views` 中所有 toplevel 的 `tiled-edges == 0`、幾何等於第 2 步送出的值。

**順序不能反過來**：先卸載再還原也能回到浮動（C-15 ⑤），但卸載與還原之間會有一段視窗停在平鋪幾何、卻已不受任何布局管理的狀態。

**回復**：用 prepare 時記下的 `core/plugins` 原值與幾何，走反方向的同一套步驟。

**注意事項**

- `set-config-options` 會**鎖定**被寫入的選項，之後重新讀取 `wayfire.ini` 不會覆寫它；也不會寫回檔案。合成器重啟後會回到 `wayfire.ini` 的值，所以 Core 每次連上合成器都要依 Profile 重新套用。登入 script 的 `wayfire.ini` 應以浮動（不含 `simple-tile`）為起點。
- `window-rules/events/watch` 有 `view-tiled` 事件可用來觸發重讀，本次沒有探測它。
- 平鋪策略啟用時，`desktop.windows.move`／`resize` 對樹中的視窗照 G0 回 `unsupported`；判斷依據改成「在不在樹中」，不再看 `tiled-edges`（見「影響」）。

### 2. 快捷鍵

Wayfire 沒有列舉 IPC 綁定的方法（C-16 ⑤），兩條路徑的回讀能力不同：

**建議：Core 自己連線上的臨時綁定。** 不帶 `command` 的綁定不啟動任何程序，只把事件送回註冊的連線，綁定的生命週期也和 Core 的連線相同：

```json
{"method": "command/register-binding", "data": {"binding": "<super> KEY_F9"}}
```

回應 `{"result":"ok","binding-id":<u64>}`。觸發時同一條連線收到 `{"event":"command-binding","binding-id":<u64>}`，Core 以 `binding-id` 對應到 Profile 的 `command_id`。解綁：

```json
{"method": "command/unregister-binding", "data": {"binding-id": 94889928095328}}
```

- 回讀只有註冊回應裡的 `binding-id`。合成器端沒有清單可讀，所以 `shortcuts` 的完成判斷是「每一組都有 `binding-id`、且 Core 的對照表與 Profile 一致」。這比其他能力的回讀弱，應在能力描述中如實寫明。
- `binding-id` 是合成器程序內的位址值，合成器重啟後全部失效，要重綁。
- 這條連線同時會收到 `events/watch` 的事件與方法回應；轉接層的讀取迴圈要能分辨兩者（有 `event` 鍵的是事件），可參考 `tools/compositor-probe/g1/wfipc.py`。**同一條連線同時 watch 與註冊臨時綁定的組合，C-16 沒有探測。**
- 綁定字串格式是 Wayfire activator，例如 `<super> KEY_F9`、`<ctrl> <alt> KEY_T`。不合法時回 `Invalid binding!`，可在 prepare 階段先驗證。

**替代：`command/bindings` 選項。** 它可以完整回讀，但每次觸發都要啟動一個 shell 命令。無 token 的 `dittoctl` 依 SEC-09 不能連 Core，所以這條路徑沒辦法把觸發送回 Core。只有當綁定本身就是「啟動某個程式」時才適用：

```json
{"method": "wayfire/set-config-options", "data": {"command/bindings": {"ditto_launcher": {"command": "<命令>", "binding": "<super> KEY_SPACE"}}}}
```

```json
{"method": "wayfire/get-config-option", "data": {"option": "command/bindings"}}
```

回讀值是 `[["ditto_launcher", "<命令>", "<super> KEY_SPACE"]]`。寫入會**整份取代**這個選項，所以 Core 必須擁有整份清單：`wayfire.ini` 不寫 `command/bindings`，或由 Core 合併。

**兩條路徑共同的限制**

- 同一組合鍵註冊兩次時，兩個命令都會執行（C-16 ③）。單一擁有者只能靠 Core 的預檢第 10 項保證。
- `"exec-always": true` 的綁定在鎖定中、以及鎖定客戶端死亡後仍會執行（C-19）。Core 保留的「喚出救援」**不應**設為 exec-always，否則鎖定畫面上就能叫出救援介面；一般快捷鍵都不設。
