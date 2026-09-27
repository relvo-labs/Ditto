# 合成器能力差異表

| 文件屬性 | 內容 |
| --- | --- |
| 狀態 | **進行中**。Wayfire 最新結果來自凍結參考機；D-02 已於 2026-09-22 決定方向（[紀錄](../../.agents/notes/decisions/2026-09-22-d02-compositor-wayfire.md)）。C-09／10／13 已完成實際功能流程；C-08 的協定啟用已探測但中文提交未成立，所以 EX-02 仍未通過 |
| 對應工作包 | [G0-PLAT-03](../../plan/02/02-platform-and-compositor.md#4-合成器能力盤點g0-plat-03) |
| 探測對象 | **Wayfire 0.11.0**（選定；`ditto-ref-ws-rtx4060-01`、headless backend、GLES2 實體 GPU）與 **Sway 1.12**（**已遺棄**；開發容器、headless、Pixman，保留為決策對照） |
| 產生方式 | Wayfire：`DITTO_COMPOSITOR=wayfire bash tests/g0/compositor-probe/run.sh`；Sway：`bash tests/g0/run-in-container.sh compositor-probe`。輸出於 `artifacts/g0/compositor-probe-<compositor>-<run_id>.json` |

這份表只記錄**已實際探測**的事實。參考機已完成 C-07 的夾具與生產遮罩、C-09／10／11／12／13／14 的 G0 探測；C-08 自動診斷只到協定與輸入上下文啟用，沒有中文提交。未完整的列放在 [§4](#4-尚未判定的列)，不會被填成看似通過的結果。

**兩次探測不在同一台機器、也不在同一個算繪路徑上。** Wayfire 跑在工作站的 GPU 上，Sway 跑在容器的 Pixman 軟體算繪上。協定的有無與請求的回讀結果可以對照；與算繪器相關的全域（`zwp_linux_dmabuf_v1`、`wp_linux_drm_syncobj_manager_v1`）差異**不是**合成器差異，任何效能數字都不可比。

## 1. 已判定的列

| 能力 | 協定／路徑 | Wayfire 0.11.0（選定） | Sway 1.12（已遺棄） | 對 Ditto 的意義 |
| --- | --- | --- | --- | --- |
| C-01 面板與 Dock 掛載 | `zwlr_layer_shell_v1` | **支援**（協定 v4）。掛上 40 px exclusive zone 後，輸出的 work area 頂緣由 0 移到 40 | **支援**（協定 v5）。同一操作後平鋪視窗恰好下移 40 px | 兩者都保留 exclusive zone，但**量法不同**，見下方說明 |
| C-02 視窗列舉與中繼資料 | `zwlr_foreign_toplevel_management_v1` v3 | **支援** | **支援** | 兩者都另有 `ext_foreign_toplevel_list_v1` v1；Wayfire 需載入 `ext-toplevel` plugin |
| C-03 視窗控制 | `zwlr_foreign_toplevel_management_v1` | **支援**。`activate`、`maximize`、`unmaximize`、`fullscreen`、`unfullscreen`、`minimize` **六項全部回讀成立** | **部分支援**。`maximize` 與 `minimize` 請求後狀態未改變 | **目前最大的差異**。能力目錄現在對 `desktop.windows.set_state` 的 minimize／maximize 回 `unsupported`，那是 Sway 的限制，不是協定的 |
| C-05 工作區模型 | `ext_workspace_manager_v1`／合成器 IPC | **不公告** `ext_workspace_manager_v1`。模型是每個 workspace set 一個固定格線（實測 3×3＝9 個），只能經 Wayfire 自己的 IPC 存取 | 公告 `ext_workspace_manager_v1` v1，但 G0 沒有實作該協定的客戶端；模型是動態具名清單（實測 1 個） | **兩者的工作區模型不同，不只是協定不同**。固定格線與具名動態清單對 PRD 的工作區需求是不同的對應關係，這項需要產品決定，不只是工程轉接 |
| C-06 輸出列舉 | `wl_output` | **部分支援**。參考 fixture 列舉到 1 個 1920×1080 輸出；IPC 的 `list-outputs` **不回報 scale**，轉接改讀啟動設定 | **部分支援**。列舉到 1 個 1280×720、scale 1.0 的輸出 | 兩者的熱插拔與縮放變更都未測 |
| C-07 命中區與點擊穿透 | `wl_surface.set_input_region` | **支援**。雙向實測：焦點在另一個視窗時，點擊透明區使下層視窗取得焦點且角色層未收到事件；點擊不透明區由角色層收到 | **未探測**。容器的 headless seat 沒有任何指標注入路徑 | Wayfire 的 `stipc` plugin 提供合成輸入，這一列因此第一次有判定；這也是 D-02 的決定性差異之一 |
| C-09 焦點轉移 | `xdg_activation_v1` | **支援**。以啟動器 surface 收到的真實指標 serial 取得 token，啟用目標 surface 後回讀焦點為 `ditto-activation-target` | Sway 對照未探測 | 不以「新視窗預設取得焦點」代替協定驗證 |
| C-10 工作階段鎖定 | `ext_session_lock_v1` | **支援（G0 最小流程）**。建立 lock、收到 `locked`，再立即送出 `unlock_and_destroy` | Sway 對照未探測 | 完整鎖屏 UI 與安全驗收屬 G1；此列只判定合成器流程 |
| C-11 截圖／螢幕分享介面 | `zwlr_screencopy_manager_v1`／`ext_image_copy_capture_manager_v1` | **支援（G0 列舉範圍）**。參考機功能探針列舉到兩個相符 global | Sway 對照只保留全域清單 | P1 實際截圖與 portal 流程另驗 |
| C-12 呈現時間戳 | `wp_presentation` | **支援**。參考機小型 surface 連續取得 presentation feedback；幀時腳本同時保存精確 compositor timestamp 與 QML `frameSwapped` | Sway 對照只保留全域清單 | EX-04 可用它檢查 QML 毫秒時鐘是否有系統性偏差 |
| C-13 XWayland 應用 | XWayland＋foreign-toplevel | **支援（G0 記錄範圍）**。xterm 以 XWayland map，title／app-id／state 可列舉，activate／maximize／unmaximize／fullscreen／unfullscreen／minimize 六項回讀皆成立 | Sway 對照未探測 | XWayland 只作相容性診斷，不進 EX-01 的凍結原生應用集合 |
| C-14 閒置／抑制介面 | `ext_idle_notifier_v1`／idle inhibit | **支援（G0 列舉範圍）**。參考機列舉到兩個相符 global | Sway 對照只保留全域清單 | 實際電源策略屬後續階段 |

C-04（視窗移動與調整大小）沒有中立協定，兩個合成器都必須走各自的 IPC。兩側現在都已實作並回讀驗證：Wayfire 經 `wayfire.rs`、Sway 經 `sway.rs`。能力矩陣的結果見 [§1.2](#12-能力矩陣的兩側結果)。

### 1.1 C-01 的量法差異

這一項值得單獨說明，因為它是誤判的入口。Sway 會平鋪視窗，所以「exclusive zone 是否生效」可以直接看視窗被推下多少。Wayfire 預設讓視窗浮動：面板出現後，**已存在的視窗不會移動**（實測 `window_shift: 0`），但輸出的 work area 頂緣確實從 0 變成 40（`usable_top: 40`）。

若沿用 Sway 的量法，Wayfire 會被記成 C-01 失敗——而那是錯的。探針因此改為：合成器有回報 work area 就量 work area，沒有就量平鋪視窗位置，並把 `measured_through` 寫進證據裡。兩種量法問的是同一個問題（40 px 有沒有被保留），但不可混為一談。

### 1.2 能力矩陣的兩側結果

同一份 `tests/g0/window-matrix` 對兩個合成器各跑一次，13 項能力 × 參考應用：

| | Wayfire 0.11.0（參考應用三角色） | Sway 1.12（舊單一終端夾具） |
| --- | --- | --- |
| 回讀驗證成功 | **30** | 8 |
| `unsupported` | **0** | 4（tiled 的 move／resize、maximize、minimize） |
| 送達（close_request） | 3 | 1 |
| 讀取 | 40 | 18 |

原始資料：`artifacts/g0/window-matrix-2026-09-22T15:03:52Z-6dfa.jsonl`（Wayfire 參考機）與 `...T18:21:31Z-000.jsonl`（Sway 歷史對照）。

矩陣現在對四種視窗狀態都發出請求，不只 Sway 有的那兩種——合成器沒有的狀態回 `unsupported`，而那個答案就是矩陣格，省略請求等於把差異藏起來。

一個要記下的限制：Wayfire 未載入平鋪 plugin 時所有視窗都是浮動的，因此矩陣的 `terminal` 與 `terminal-floating` 兩個角色在 Wayfire 上是同一種形態，**兩者的 move／resize 都成功不代表平鋪視窗也可以**。

## 2. 與能力目錄的對應

能力目錄在 Core 連上合成器後才決定 `availability`，每項寫明所依賴的列與綁定路徑。下表是 Wayfire 路徑（`wayfire.rs`）的實際行為，全部以 `desktop.*` 的回讀驗證：

| capability_id | 差異表列 | Wayfire 路徑的實際行為 | 綁定 |
| --- | --- | --- | --- |
| `desktop.windows.list`／`get` | C-02 | 由 `window-rules/list-views` 讀取，只取 `role == "toplevel"` 且已 map 的視窗 | `wayfire-ipc` |
| `desktop.windows.focus` | C-03 | `window-rules/focus-view`，以 `desktop.windows.get` 回讀 | `wayfire-ipc` |
| `desktop.windows.set_state` | C-03 | **四種狀態全部成立**：fullscreen 與 maximize（`tiled-edges=15`）經 `configure-view`，minimize 經 `wm-actions/set-minimized` | `wayfire-ipc` |
| `desktop.windows.move`／`resize` | C-04 | `configure-view` 的 geometry，回讀一致；已平鋪的視窗回 `unsupported` | `wayfire-ipc` |
| `desktop.workspaces.list`／`get` | C-05 | 由輸出的格線展開，ID 帶座標（`wayfire-ws-<output>-<column>-<row>`），名稱是格線的閱讀順序 | `wayfire-ipc` |
| `desktop.workspaces.activate` | C-05 | `vswitch/set-workspace`，切換後回讀 `active` | `wayfire-ipc` |
| `desktop.outputs.list` | C-06 | `window-rules/list-outputs`；**scale 改讀啟動設定**，執行期經其他路徑的變更看不到 | `wayfire-ipc` |
| `desktop.events.subscribe` | C-02／C-05／C-06 的事件 | `window-rules/events/watch`，事件只用來決定重讀哪一段狀態，不轉送給消費者 | `wayfire-ipc` |

## 3. Wayfire 路徑的已知缺口

轉接已實作（`crates/ditto-compositor/src/wayfire.rs`），但有三個缺口要記在這裡而不是留在程式碼裡：

- **視窗屬於哪個工作區是推導的。** Wayfire 把格線鋪在同一個座標空間，轉接因此以「目前格位＋視窗偏移了幾個輸出寬度」計算，sticky 視窗算在目前工作區。這是 Wayfire 自己的規則，但合成器不逐視窗回報這件事，所以它仍是推導。
- **輸出 scale 不是即時值。** 來源是啟動設定，不是合成器的當下狀態。
- **需要的 plugin 是硬需求。** `ipc`、`ipc-rules` 缺了就連不上；`wm-actions` 缺了 minimize 無路徑；`vswitch` 缺了工作區切換無路徑。夾具設定見 [`tools/dev-wayland/wayfire.ini`](../../tools/dev-wayland/wayfire.ini)。

探針與夾具是合成器中立的（`tools/compositor-probe/functional/compositor.sh`），Core 這一層也已補齊；`CompositorAdapter` 介面、Core 路由與 Shell 在加入 Wayfire 後端時都沒有改動。

## 4. 尚未判定的列

以下列**沒有判定**，不得在任何報告中當成通過或失敗：

| 能力 | 協定 | Wayfire 的全域狀態 | 目前證據／缺口 | 需要什麼才能判定 |
| --- | --- | --- | --- | --- |
| C-08 中文輸入 | `text_input_v3`＋`input_method_v2` | 公告 v1／v1，**但只在 `workarounds/enable_input_method_v2` 開啟時**；預設關閉 | Fcitx 5.1.7 與 Qt text-input-v3 已啟用，但 `stipc` 注入得到原始 `nihao `、無候選窗；尚不能區分虛擬鍵盤限制與 relay 缺陷 | 依[輸入法報告](input-method-report.md)以實體鍵盤重跑，再完成 QML／參考終端／參考編輯器與剪貼簿；另須記錄 workaround 選項對支援承諾的影響 |

## 5. 全域列舉的差異

Wayfire 載入能力差異表所需的協定 plugin 後有 51 個 global，Sway 有 55 個。**Sway 有而 Wayfire 沒有**的與 G0 有關者：

| 全域 | 影響 |
| --- | --- |
| `ext_workspace_manager_v1` | C-05：中立工作區協定在 Wayfire 上沒有，只能走 IPC |
| `ext_foreign_toplevel_image_capture_source_manager_v1` | C-11 的一條路徑；G0 只列舉 |
| `ext_transient_seat_manager_v1`、`wl_fixes`、`wp_alpha_modifier_v1`、`wp_content_type_manager_v1`、`wp_tearing_control_manager_v1`、`xdg_toplevel_tag_manager_v1` | 目前沒有對應的差異表列 |

`zwp_linux_dmabuf_v1`、`wp_linux_drm_syncobj_manager_v1`、`xwayland_shell_v1` 只出現在 Wayfire 一側，但 Wayfire 跑在 GPU 上而 Sway 跑在軟體算繪上，**這是環境差異，不能記為合成器差異**。

Wayfire 的協定多數由 plugin 提供，因此「Wayfire 支援什麼」這個問題沒有脫離設定的答案：[`tools/dev-wayland/wayfire.ini`](../../tools/dev-wayland/wayfire.ini) 載入的清單即是本表的前提，換一份設定會得到另一張表。

## 6. 這份表還不能支持什麼

- **不能代表 G0 出口門檻已通過。** D-02 的預先承諾判準要求 C-01／02／03／06／07／08 六項都有結論。現在 C-01、C-02、C-03、C-07 有結論，C-06 是部分支援；**C-08 只確認協定啟用，中文提交尚未成立**。2026-09-22 的[決策紀錄](../../.agents/notes/decisions/2026-09-22-d02-compositor-wayfire.md)因此把狀態寫成「方向已定」，不是門檻通過。
- **不能把 source build 泛化為其他發行版。** Wayfire 0.11.0 與依賴鏈是本參考機的凍結組合；容器 Sway 只保留決策對照。
- **不能只靠此表推論效能。** `wp_presentation` 已可用，但 EX-04 仍要依固定互動腳本的三次完整結果判定。
- **Sway 那一欄不會再更新。** 它是決策當下的對照，不是維護中的支援目標；`sway.rs` 保留可編譯只為了讓這份對照能重現。

下一步見 [plan/02 §7 的進度紀錄](../../plan/02/06-workplan.md#7-進度紀錄)。

## 7. G1 探測：C-15～C-19（開發證據，headless）

> **開發證據（headless）。** 以下結果來自 `ditto-ref-ws-rtx4060-01` 上的 headless Wayfire 0.11.0（`WLR_BACKENDS=headless`、`WLR_RENDERER=pixman`、合成輸入經 `stipc`），不是實體登入工作階段，也不是任何出口門檻的結果。run_id `2026-09-27T09:30:54Z-54ef`：commit 為 `54ef90b`，但探測腳本當時尚未進版（工作樹）。探測對象的 plugin 清單見 [`tools/compositor-probe/g1/wayfire.ini`](../../tools/compositor-probe/g1/wayfire.ini)（G0 夾具加上 `command`；`simple-tile` 刻意不預載）。
>
> 重跑：`bash tools/compositor-probe/g1/run.sh [c15 c16 c17 c18 c19]`，輸出於 `artifacts/g1-dev/compositor-probe/`（每項一份 JSON 與合成器日誌）。

| 能力 | 路徑 | 觀察結果（開發證據（headless）） | 證據 | 對 Ditto 的意義 |
| --- | --- | --- | --- | --- |
| C-15 平鋪策略切換 | `wayfire/set-config-options` 改 `core/plugins`；`simple-tile/get-layout`／`set-layout`；`window-rules/configure-view` | **執行期可切換，但既有視窗要由呼叫端處理。** ① 執行期載入 `simple-tile` 回 `ok`，`get-layout` 隨即可用；**已存在的兩個視窗不會被平鋪**（幾何仍為 100,100 700×500、`tiled-edges=0`），之後新開的視窗才平鋪（0,0 1920×1080、`tiled-edges=15`）。② `set-layout` 把三個視窗放進同一棵樹後，回讀為三欄（x=0／645／1285），包含先前的浮動視窗。③ `set-layout` 移出某視窗後，它**離開樹但仍回報 `tiled-edges=15` 與平鋪時的幾何**；plugin 自己的 `<super> KEY_T` 切換則會還原為 100,100 700×500、`tiled-edges=0`。④ 載入中把 `simple-tile/tile_by_default` 設為 `none`，新視窗浮動。⑤ **平鋪中卸載 plugin，視窗停在平鋪幾何、`tiled-edges=15`**，`get-layout` 變成 `No such method found!`；此時對每個視窗送 `configure-view {"tiled-edges":0,"geometry":…}` 可回到浮動幾何。⑥ 重新載入後樹是空的，已存在的視窗不會自動回到樹中 | `artifacts/g1-dev/compositor-probe/c15-2026-09-27T09:30:54Z-54ef.json` | 布局切換可以做成受控交接（D-33 提案），但 Wayfire 不會替既有視窗完成交接：浮動→平鋪要以 `set-layout` 放入既有視窗，平鋪→浮動要先清空樹、再以 `configure-view` 還原呼叫端記下的浮動幾何。另見下方「對現有轉接的影響」 |
| C-16 全域快捷鍵綁定 | `command/register-binding`／`unregister-binding`；`command/bindings`（經 `set-config-options`） | **執行期可新增、觸發、移除，兩條路徑都成立。** ① IPC 綁定 `<super> KEY_F9` 帶 `command`：`stipc` 觸發後命令執行；註冊的連線關閉後仍會觸發（持久）；`unregister-binding` 後不再觸發。② 不帶 `command` 的綁定只把 `{"event":"command-binding","binding-id":…}` 送給註冊的連線。③ **同一組合鍵註冊兩次，兩個命令都執行**：合成器不維持單一擁有者。④ 經 `set-config-options` 寫入 `command/bindings` 後觸發成立，`get-config-option` 可回讀整份清單；寫入空物件後不再觸發、回讀為 `[]`。⑤ **沒有列舉 IPC 綁定的方法**（`command/list-bindings` 回 `No such method found!`）；`binding-id` 是合成器程序內的位址值，重啟後不沿用 | `artifacts/g1-dev/compositor-probe/c16-2026-09-27T09:30:54Z-54ef.json` | G1-R4 的快捷鍵部分不成立：不需要 layer-shell 鍵盤獨占。可回讀的路徑是 `command/bindings` 選項，單一擁有者須由 Core 的預檢保證（合成器不擋重複）。「連線關閉後綁定仍在、被移除」的行為是讀原始碼（`command.cpp` 的 `on_client_disconnect`），本探測沒有觀察臨時綁定在斷線後的移除 |
| C-17 輸出縮放與排列變更 | `wayfire/set-config-options` 改 `output:<name>/scale`、`output:<name>/position` | **執行期可變更並回讀。** scale 1.0→1.25：`list-outputs` 的邏輯幾何由 1920×1080 變為 1536×864；`xdg_output` 同樣回報 1536×864；`wl_output` 的整數 scale 由 1 變 2；`output-layout-changed` 事件帶 `"scale": 1.25`。position 改為 100,50：`list-outputs` 與 `xdg_output` 都回讀 100,50；`wl_output` 的 x／y 仍為 0,0。還原後三處都回到初值。`zwlr_output_manager_v1` v4 有公告，但本機沒有 `wlr-randr`，**該協定路徑沒有測** | `artifacts/g1-dev/compositor-probe/c17-2026-09-27T09:30:54Z-54ef.json` | C-06「scale 只能讀啟動設定」有了執行期的讀取來源：`output-layout-changed` 事件的 `configuration[].scale`，或 `get-config-option output:<name>/scale`。限時回復可用同一個 `set-config-options` 寫回舊值。headless 的 1.25 在實體螢幕上的呈現未驗 |
| C-18 輸出熱插拔事件 | `window-rules/events/watch`；`wayfire/create-headless-output`／`destroy-headless-output` | **headless 模擬成立，實體拔插未測。** 以 IPC 新增 1280×720 的 `HEADLESS-2`：watch 連線收到 `output-layout-changed`（兩個輸出），**沒有收到 `output-added`**。把視窗移到 `HEADLESS-2` 後刪除該輸出：收到 `view-set-output`、`output-removed`、`output-layout-changed`；**視窗被合成器移回 `HEADLESS-1`**（幾何約 100,100）。啟動時的 `HEADLESS-1` 不能以此方法刪除（`Output is not a headless output created from an IPC command!`） | `artifacts/g1-dev/compositor-probe/c18-2026-09-27T09:30:54Z-54ef.json` | Core 應以 `output-layout-changed`＋`output-removed` 觸發重讀，不能只等 `output-added`。視窗搬移在這個情境下由 Wayfire 自己完成，Core 的工作是回讀並處理無法搬移的（平鋪中）視窗。EX1-13 ⑤ 仍需第二台實體螢幕 |
| C-19 鎖定客戶端死亡 | `ext_session_lock_v1` | **headless 下仍維持鎖定，桌面內容未暴露。** 鎖定客戶端以不透明洋紅色 lock surface 鎖定：截圖 100% 洋紅，按鍵不進入 foot 視窗，一般 `command` 綁定不觸發。`SIGKILL` 鎖定客戶端後：截圖為黑底加 Wayfire 的 💥 圖案（黑色約 66%），**基準畫面的桌面顏色占比 0%**；按鍵仍不進入視窗；`focus-view` 回 `ok` 但輸入沒有送達。之後啟動第二個鎖定客戶端，**可以接手鎖定並解鎖**，解鎖後輸入恢復；鎖定期間送出的按鍵事後也沒有出現在視窗中。`exec-always` 的綁定在三種鎖定狀態下**都會執行** | `artifacts/g1-dev/compositor-probe/c19-2026-09-27T09:30:54Z-54ef.json` 與同名的四張 `.png` | G1-R6 在 headless 下沒有出現。但：① 殭屍鎖定畫面沒有解鎖介面，**使用者只能等 Core 重啟 `ditto-lock`**；② 任何能連上 `ext_session_lock_manager_v1` 的客戶端都能接手並解鎖，這個 global 的存取必須受限；③ 截圖經 screencopy 取得，代表合成器的輸出內容，不代表實體螢幕；EX1-12 ④ 仍須在實體登入工作階段以錄影確認，且本探測只終止了鎖定客戶端，沒有同時終止 Shell |

### 7.1 對現有轉接的影響

- `crates/ditto-compositor/src/wayfire.rs` 目前把 `tiled-edges == 15` 當成「最大化」。`simple-tile` 載入後，平鋪視窗同樣回報 `tiled-edges=15`（C-15），兩者在 `list-views` 裡**無法區分**。要分辨，須另以 `simple-tile/get-layout` 查該視窗是否在樹中。
- `command/bindings` 與 `core/plugins` 經 `set-config-options` 寫入後會被**鎖定**（`opt->set_locked(true)`，讀自 `ipc-utility-methods.hpp`），之後重新讀取 `wayfire.ini` 不會覆寫它們。它們也不會寫回檔案，合成器重啟後回到 `wayfire.ini` 的值；權威仍在 Profile，由 Core 每次啟動後重新套用。
- 具體的 IPC 呼叫與回讀方式見 [D-33 提案](../../.agents/notes/decisions/2026-09-27-d33-layout-strategy-path.md)。

### 7.2 本節不能支持什麼

- 不能代表 EX1-01 ③、EX1-12 ④、EX1-13 ⑤ 任一項通過。三者都要求實體參考機工作階段（④ 另需錄影，⑤ 需第二台實體螢幕）。
- headless 的 pixman 算繪路徑與參考機的 GPU／DRM 路徑不同；C-19 的「未暴露」只對 screencopy 看到的內容成立。
- `zwlr_output_manager_v1` 路徑（C-17）與臨時綁定在斷線後的移除（C-16）沒有觀察，只讀了原始碼或只確認 global 存在。
