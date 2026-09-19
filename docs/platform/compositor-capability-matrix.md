# 合成器能力差異表

| 文件屬性 | 內容 |
| --- | --- |
| 狀態 | **未完成**。這是開發容器的探測結果，不是 D-02 的決策依據 |
| 對應工作包 | [G0-PLAT-03](../../plan/02/02-platform-and-compositor.md#4-合成器能力盤點g0-plat-03) |
| 探測對象 | Sway 1.12（開發容器、headless、Pixman 軟體算繪） |
| 產生方式 | `bash tests/g0/run-in-container.sh compositor-probe`，輸出於 `artifacts/g0/compositor-probe-<compositor>-<run_id>.json` |

這份表只記錄**已實際探測**的事實。開發容器沒有實體輸入裝置、沒有輸入法、沒有 X11 應用，因此 C-07、C-08、C-13 等列無法在此判定；它們列在 [§3](#3-尚未探測的列) 而不是被給一個看起來像通過的判定。四態（支援／部分支援／不支援／需轉接）只用於已探測的列。

## 1. 已判定的列

| 能力 | 協定／路徑 | 判定 | 證據 | 缺口處理方案 | 估計成本 | 綁定合成器 |
| --- | --- | --- | --- | --- | --- | --- |
| C-01 面板與 Dock 掛載 | `zwlr_layer_shell_v1` | 支援 | 功能探針：掛上 40 px exclusive zone 後，平鋪視窗恰好下移 40 px（`functional_results[C-01]`）；Shell 工作階段量到頂部 34 px、底部 56 px 兩個區域同時生效 | — | — | 否 |
| C-02 視窗列舉與中繼資料 | `zwlr_foreign_toplevel_management_v1` | 支援 | 功能探針經 Quickshell 的 toplevel 介面列舉到探測視窗，`app_id`、`title`、`activated` 皆有值 | — | — | 否（另有 `ext_foreign_toplevel_list_v1` 公告） |
| C-03 視窗控制 | `zwlr_foreign_toplevel_management_v1` | **部分支援** | 同一探針逐項請求並回讀：`activate` 成立、`fullscreen`／取消成立、**`maximize` 與 `minimize` 請求後狀態未改變** | 最大化與最小化在此合成器沒有對應狀態；能力目錄對 `desktop.windows.set_state` 的 minimize／maximize 回 `unsupported`，並在描述子標記 | 已實作（0） | 否 |
| C-04 視窗移動與調整大小 | 無中立協定 | **需轉接** | 中立協定不含座標操作；改經合成器 IPC 後，浮動視窗的 `move`／`resize` 回讀一致，平鋪視窗回 `unsupported`（`artifacts/g0/window-matrix-*.jsonl`） | 已以合成器 IPC 轉接實作；換合成器須重寫此路徑 | 已實作（0），換合成器約 0.5 人週 | **是**（`sway-ipc`） |
| C-05 工作區列舉與切換 | `ext_workspace_manager_v1`（公告）／合成器 IPC（實作） | **需轉接** | 全域列舉顯示 `ext_workspace_manager_v1` 存在，但 G0 沒有實作該協定的客戶端；目前列舉與切換走合成器 IPC，切換後以 `desktop.workspaces.get` 回讀一致 | 兩條路可選：實作中立協定客戶端（換合成器時省成本），或維持 IPC 轉接 | 中立客戶端估 1–2 人週（未核定） | **是**（`sway-ipc`） |
| C-06 輸出列舉 | `wl_output` | **部分支援** | 探針列舉到 1 個 1280×720、scale 1.0 的輸出；**熱插拔與縮放變更未在此環境測試** | 熱插拔須在實體參考機測；差異即為此列未完成的部分 | 待測 | 否 |

## 2. 與能力目錄的對應

能力目錄在 Core 連上合成器後才決定 `availability`，每項寫明所依賴的列與綁定路徑：

| capability_id | 差異表列 | G0 實際行為 |
| --- | --- | --- |
| `desktop.windows.list`／`get` | C-02 | 經合成器 IPC 讀取（含裝飾框幾何） |
| `desktop.windows.focus` | C-03 | 成功並以 `desktop.windows.get` 回讀 |
| `desktop.windows.set_state` | C-03 | 全螢幕與還原成立；minimize／maximize 回 `unsupported` |
| `desktop.windows.move`／`resize` | C-04 | 浮動視窗成立並回讀；平鋪視窗回 `unsupported` |
| `desktop.workspaces.*` | C-05 | 經合成器 IPC；`activate` 後回讀 `active` |
| `desktop.outputs.list` | C-06 | 經合成器 IPC 列舉 |
| `desktop.events.subscribe` | C-02／C-05／C-06 的事件 | 合成器事件觸發後重新查詢並送差異事件，不輪詢 |

## 3. 尚未探測的列

以下列**沒有判定**，不得在任何報告中當成通過或失敗：

| 能力 | 協定 | 為什麼還沒探測 | 需要什麼才能探測 |
| --- | --- | --- | --- |
| C-07 命中區與點擊穿透 | `wl_surface.set_input_region` | 開發容器的 headless seat 沒有指標裝置，`swaymsg seat - cursor` 不會產生事件 | 實體輸入裝置或虛擬指標工具；[SHELL-03 的雙向驗證](../../plan/02/04-shell-and-avatar.md#51-驗證怎麼做) |
| C-08 中文輸入 | `text_input_v3`＋`input_method_v2` | 容器未安裝輸入法（`zwp_text_input_manager_v3` 有公告） | fcitx5 與可見的候選視窗；EX-08 |
| C-09 焦點轉移 | `xdg_activation_v1` | 全域有公告，尚未做啟動後取得焦點的功能探測 | 啟動器路徑 |
| C-10 工作階段鎖定 | `ext_session_lock_manager_v1` | G0 只列舉 | — |
| C-11 截圖與螢幕分享 | `zwlr_screencopy_manager_v1`、portal | G0 只列舉 | — |
| C-12 呈現時間戳 | `wp_presentation` | 幀時交叉驗證屬於實體參考機 | 參考機與 GPU |
| C-13 XWayland 應用 | — | 容器沒有 X11 應用 | 凍結的參考應用集合 |
| C-14 閒置與抑制 | `ext_idle_notifier_v1` | G0 只列舉 | — |

## 4. 這份表還不能支持什麼

- **不能作為 D-02 的依據。** D-02 的預先承諾判準要求 C-01／02／03／06／07／08 六項都有結論；目前 C-07 與 C-08 沒有探測結果，C-03 與 C-06 是部分支援且差異尚未在實體環境確認。
- **不能作為支援矩陣的版本事實。** 容器的 Sway 1.12 來自會變動的 Debian testing 套件庫，不是凍結的參考平台。
- **不能推論效能。** 所有探測都在 Pixman 軟體算繪下執行。

下一步見 [plan/02 §7 的進度紀錄](../../plan/02/06-workplan.md#7-進度紀錄)。
