# 合成器能力差異表

| 文件屬性 | 內容 |
| --- | --- |
| 狀態 | **進行中**。這是開發環境的探測結果。D-02 已於 2026-09-22 依此決定方向（[紀錄](../../.agents/notes/decisions/2026-09-22-d02-compositor-wayfire.md)），但 C-08 未探測，G0 出口門檻尚未通過 |
| 對應工作包 | [G0-PLAT-03](../../plan/02/02-platform-and-compositor.md#4-合成器能力盤點g0-plat-03) |
| 探測對象 | **Wayfire 0.11.0**（選定；工作站、headless backend、`gles2` 實體 GPU）與 **Sway 1.12**（**已遺棄**；開發容器、headless、Pixman 軟體算繪，保留為決策對照） |
| 產生方式 | Wayfire：`DITTO_COMPOSITOR=wayfire bash tests/g0/compositor-probe/run.sh`；Sway：`bash tests/g0/run-in-container.sh compositor-probe`。輸出於 `artifacts/g0/compositor-probe-<compositor>-<run_id>.json` |

這份表只記錄**已實際探測**的事實。Wayfire 工作站能透過 `stipc` 注入合成指標，因此 C-07 已完成單矩形探針表面的透明與不透明區域雙向探測；Sway 容器沒有同等注入路徑，所以該側仍未探測。C-08 雖已安裝 fcitx5 並確認原生 Wayland 所需 global、session bus 與引擎可用，仍未完成 QML 文字輸入、終端與編輯器的實際輸入、候選視窗位置及剪貼簿互通驗證。這項環境就緒資訊來自[開發工作站紀錄](dev-wayland-environment.md)，目前探針產物對 C-08 仍使用靜態的「未安裝輸入法」原因，不能用來判斷工作站狀態。C-09～C-14 也只有列舉結果。未形成判定的列留在 [§4](#4-尚未探測的列)，不把環境就緒誤寫成通過。四態（支援／部分支援／不支援／需轉接）只用於已探測的列。

**兩次探測不在同一台機器、也不在同一個算繪路徑上。** Wayfire 跑在工作站的 GPU 上，Sway 跑在容器的 Pixman 軟體算繪上。協定的有無與請求的回讀結果可以對照；與算繪器相關的全域（`zwp_linux_dmabuf_v1`、`wp_linux_drm_syncobj_manager_v1`）差異**不是**合成器差異，任何效能數字都不可比。

## 1. 已判定的列

| 能力 | 協定／路徑 | Wayfire 0.11.0（選定） | Sway 1.12（已遺棄） | 對 Ditto 的意義 |
| --- | --- | --- | --- | --- |
| C-01 面板與 Dock 掛載 | `zwlr_layer_shell_v1` | **支援**（協定 v4）。掛上 40 px exclusive zone 後，輸出的 work area 頂緣由 0 移到 40 | **支援**（協定 v5）。同一操作後平鋪視窗恰好下移 40 px | 兩者都保留 exclusive zone，但**量法不同**，見下方說明 |
| C-02 視窗列舉與中繼資料 | `zwlr_foreign_toplevel_management_v1` v3 | **支援** | **支援** | 兩者都另有 `ext_foreign_toplevel_list_v1` v1；Wayfire 需載入 `ext-toplevel` plugin |
| C-03 視窗控制 | `zwlr_foreign_toplevel_management_v1` | **支援**。`activate`、`maximize`、`unmaximize`、`fullscreen`、`unfullscreen`、`minimize` **六項全部回讀成立** | **部分支援**。`maximize` 與 `minimize` 請求後狀態未改變 | **目前最大的差異**。能力目錄現在對 `desktop.windows.set_state` 的 minimize／maximize 回 `unsupported`，那是 Sway 的限制，不是協定的 |
| C-05 工作區模型 | `ext_workspace_manager_v1`／合成器 IPC | **不公告** `ext_workspace_manager_v1`。模型是每個 workspace set 一個固定格線（實測 3×3＝9 個），只能經 Wayfire 自己的 IPC 存取 | 公告 `ext_workspace_manager_v1` v1，但 G0 沒有實作該協定的客戶端；模型是動態具名清單（實測 1 個） | **兩者的工作區模型不同，不只是協定不同**。固定格線與具名動態清單對 PRD 的工作區需求是不同的對應關係，這項需要產品決定，不只是工程轉接 |
| C-06 輸出列舉 | `wl_output` | **部分支援**。列舉到 1 個 1280×720 輸出；其 IPC 的 `list-outputs` **不回報 scale**，轉接改讀啟動設定 | **部分支援**。列舉到 1 個 1280×720、scale 1.0 的輸出 | 兩者的熱插拔與縮放變更都未測 |
| C-07 命中區與點擊穿透 | `wl_surface.set_input_region` | **支援**。雙向實測：焦點在另一個視窗時，點擊透明區使下層視窗取得焦點且角色層未收到事件；點擊不透明區由角色層收到 | **未探測**。容器的 headless seat 沒有任何指標注入路徑 | Wayfire 的 `stipc` plugin 提供合成輸入，這一列因此第一次有判定；這也是 D-02 的決定性差異之一 |

C-04（視窗移動與調整大小）沒有中立協定，兩個合成器都必須走各自的 IPC。兩側現在都已實作並回讀驗證：Wayfire 經 `wayfire.rs`、Sway 經 `sway.rs`。能力矩陣的結果見 [§1.2](#12-能力矩陣的兩側結果)。

### 1.1 C-01 的量法差異

這一項值得單獨說明，因為它是誤判的入口。Sway 會平鋪視窗，所以「exclusive zone 是否生效」可以直接看視窗被推下多少。Wayfire 預設讓視窗浮動：面板出現後，**已存在的視窗不會移動**（實測 `window_shift: 0`），但輸出的 work area 頂緣確實從 0 變成 40（`usable_top: 40`）。

若沿用 Sway 的量法，Wayfire 會被記成 C-01 失敗——而那是錯的。探針因此改為：合成器有回報 work area 就量 work area，沒有就量平鋪視窗位置，並把 `measured_through` 寫進證據裡。兩種量法問的是同一個問題（40 px 有沒有被保留），但不可混為一談。

### 1.2 能力矩陣的兩側結果

同一份 `tests/g0/window-matrix` 對兩個合成器各跑一次，13 項能力 × 參考應用：

| | Wayfire 0.11.0 | Sway 1.12 |
| --- | --- | --- |
| 回讀驗證成功 | **12** | 8 |
| `unsupported` | **0** | 4（tiled 的 move／resize、maximize、minimize） |
| 送達（close_request） | 1 | 1 |
| 讀取 | 18 | 18 |

原始資料：`artifacts/g0/window-matrix-2026-09-21T18:21:19Z-35a1.jsonl`（Wayfire）與 `...T18:21:31Z-000.jsonl`（Sway）。

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

## 4. 尚未探測的列

以下列**沒有判定**，不得在任何報告中當成通過或失敗：

| 能力 | 協定 | Wayfire 的全域狀態 | 為什麼還沒探測 | 需要什麼才能探測 |
| --- | --- | --- | --- | --- |
| C-08 中文輸入 | `text_input_v3`＋`input_method_v2` | 公告 v1／v1，**但只在 `workarounds/enable_input_method_v2` 開啟時**；預設關閉 | fcitx5、session bus、chewing 引擎與原生 Wayland 路徑已就緒，但尚未在 QML 文字輸入、終端與編輯器逐一輸入，也未驗證候選視窗位置與剪貼簿互通 | 三處人工輸入、候選視窗及複製貼上證據；EX-08。另須記錄「Wayfire 視其為 workaround 選項」對支援承諾的影響 |
| C-09 焦點轉移 | `xdg_activation_v1` | 公告 v1（需 `xdg-activation` plugin） | 尚未做啟動後取得焦點的功能探測 | 啟動器路徑 |
| C-10 工作階段鎖定 | `ext_session_lock_manager_v1` | 公告 v1（需 `session-lock` plugin） | G0 只列舉 | — |
| C-11 截圖與螢幕分享 | `zwlr_screencopy_manager_v1`、portal | 公告 v3，另有 `ext_image_copy_capture_manager_v1` v1 | G0 只列舉 | — |
| C-12 呈現時間戳 | `wp_presentation` | 公告 v2 | 幀時交叉驗證屬於實體參考機 | 參考機與 GPU |
| C-13 XWayland 應用 | — | `xwayland_shell_v1` 公告 | 沒有 X11 應用 | 凍結的參考應用集合 |
| C-14 閒置與抑制 | `ext_idle_notifier_v1` | 公告 v2 | G0 只列舉 | — |

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

- **不能代表 G0 出口門檻已通過。** D-02 的預先承諾判準要求 C-01／02／03／06／07／08 六項都有結論。現在 C-01、C-02、C-03、C-07 有結論，C-06 是部分支援，**C-08 仍未探測**。2026-09-22 的[決策紀錄](../../.agents/notes/decisions/2026-09-22-d02-compositor-wayfire.md)因此把狀態寫成「方向已定」，不是門檻通過。
- **不能作為支援矩陣的版本事實。** Wayfire 0.11.0 與其依賴鏈是從上游 git tag 自行建置的組合，不對應任何發行版；容器的 Sway 1.12 來自會變動的 Debian testing 套件庫。兩者都不是凍結的參考平台。
- **不能推論效能。** Wayfire 側雖在 GPU 上執行，但工作站不是參考機，且沒有依 [驗收證據規範](../../.agents/skills/ditto-verification-evidence/SKILL.md)的流程量測。
- **Sway 那一欄不會再更新。** 它是決策當下的對照，不是維護中的支援目標；`sway.rs` 保留可編譯只為了讓這份對照能重現。

下一步見 [plan/02 §7 的進度紀錄](../../plan/02/06-workplan.md#7-進度紀錄)。
