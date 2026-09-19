# ditto-compositor

合成器轉接。視窗、工作區與輸出是合成器擁有的狀態，這個 crate 只翻譯協定，不保存第二份真相，也不維護自己的布局。

| 後端 | 用途 |
| --- | --- |
| `sway` | 開發用的真實合成器路徑，經合成器專屬 IPC。座標（C-04）與工作區（C-05）沒有中立協定，因此這些能力標記 `bound_to: "sway-ipc"` |
| `fixture` | 沒有合成器時的記憶體實作。它刻意保留真實合成器的缺口（平鋪視窗沒有座標控制、沒有最小化與最大化），因此能在 fixture 上通過的消費者，在真實路徑上也會遇到相同的 `unsupported` |

換合成器時要重寫的只有後端檔案；`CompositorAdapter` 介面、Core 路由與 Shell 不動。

## 目前已知的合成器行為

- 中立的 `zwlr_foreign_toplevel_management_v1` 可以列舉與聚焦，但在 Sway 上 maximize 與 minimize 請求後狀態不變。
- 平鋪視窗的幾何屬於布局，因此 `move`／`resize` 對它回 `unsupported`，而不是「成功但沒動」。
- 視窗幾何以**含裝飾**的外框回報：合成器以裝飾原點定位視窗，若用內容框回報，每次成功的移動都會被誤判為回讀不一致。
- 視窗 ID 只在本次工作階段有效，型別名稱（`WindowSessionId`）就說明了這件事。

逐列證據見[能力差異表](../../docs/platform/compositor-capability-matrix.md)。
