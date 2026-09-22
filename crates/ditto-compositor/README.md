# ditto-compositor

合成器轉接。視窗、工作區與輸出是合成器擁有的狀態，這個 crate 只翻譯協定，不保存第二份真相，也不維護自己的布局。

| 後端 | 狀態 | 用途 |
| --- | --- | --- |
| `wayfire` | **主要** | D-02 選定的合成器。座標（C-04）與工作區（C-05）沒有中立協定，因此這些能力標記 `bound_to: "wayfire-ipc"` |
| `sway` | **已遺棄** | 保留為 D-02 的對照證據，不接受新功能，預設路徑與 G0 腳本不再走它。見[決策紀錄](../../.agents/notes/decisions/2026-09-22-d02-compositor-wayfire.md) |
| `fixture` | 測試用 | 沒有合成器時的記憶體實作。它刻意保留真實合成器的缺口，因此能在 fixture 上通過的消費者，在真實路徑上也會遇到相同的 `unsupported` |

換合成器時要重寫的只有後端檔案；`CompositorAdapter` 介面、Core 路由與 Shell 不動。這一點在 2026-09-22 被實際驗證過一次：加入 Wayfire 後端時，介面、Core 與 Shell 都沒有改動。

## Wayfire 後端需要的 plugin

這些是硬需求，不是建議：

| plugin | 沒有它會怎樣 |
| --- | --- |
| `ipc`、`ipc-rules` | 沒有任何查詢與事件路徑，Core 連不上 |
| `wm-actions` | `desktop.windows.set_state` 的 minimize 無路徑 |
| `vswitch` | `desktop.workspaces.activate` 無路徑 |

## 目前已知的合成器行為

- Wayfire 的 `zwlr_foreign_toplevel_management_v1` 六項請求（含 maximize 與 minimize）回讀全部成立；Sway 的 maximize 與 minimize 請求後狀態不變，這是 D-02 的決定性差異之一。
- **工作區模型不同**：Wayfire 是每個輸出一個固定格線，工作區 ID 因此帶座標（`wayfire-ws-<output>-<column>-<row>`）；Sway 是具名動態清單。
- **視窗屬於哪個工作區是推導的**，不是合成器回報的：Wayfire 把格線鋪在同一個座標空間，因此視窗的格位＝目前格位加上它偏移了幾個輸出寬度。sticky 視窗算在目前工作區。這條規則是 Wayfire 自己的，但它仍是推導，C-05 記錄了這一點。
- 已平鋪的視窗幾何屬於布局，因此 `move`／`resize` 對它回 `unsupported`，而不是「成功但沒動」。Wayfire 未載入平鋪 plugin 時所有視窗都是浮動的，這個分支因此不會在預設設定下觸發。
- 輸出的 scale 不在 Wayfire 的 IPC 回報範圍內，改讀它啟動時的設定；執行期經其他路徑改變的 scale 看不到，這個缺口屬於 C-06。
- 視窗幾何在 Sway 後端以**含裝飾**的外框回報：合成器以裝飾原點定位視窗，若用內容框回報，每次成功的移動都會被誤判為回讀不一致。
- 視窗 ID 只在本次工作階段有效，型別名稱（`WindowSessionId`）就說明了這件事。

逐列證據見[能力差異表](../../docs/platform/compositor-capability-matrix.md)。
