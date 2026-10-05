# G1 合成器探針（C-15～C-19）

對 headless Wayfire 執行 plan/03/05 §6.1 的五項探測。每項各自啟動一個合成器（啟動方式同 `tests/g0/lib/session.sh`，設定改用本目錄的 `wayfire.ini`），輸出一份 JSON 與合成器日誌：

```sh
bash tools/compositor-probe/g1/run.sh            # 全部
bash tools/compositor-probe/g1/run.sh c15 c19    # 指定項目
```

輸出於 `artifacts/g1-dev/compositor-probe/<項目>-<run_id>.json`（`DITTO_G1_DEV_ARTIFACTS` 可改）。結果一律是**開發證據（headless）**，不是出口門檻結果；判讀見[差異表 §7](../../../docs/platform/compositor-capability-matrix.md#7-g1-探測c-15c-19開發證據headless)。

| 檔案 | 作用 |
| --- | --- |
| `c15-tile.py` | `simple-tile` 執行期載入／卸載、`set-layout`、逐視窗切換，每步回讀幾何 |
| `c16-bindings.py` | `command` plugin 的 IPC 綁定與 `command/bindings` 選項：新增、觸發、移除 |
| `c17-output-config.py` | 輸出 scale／position 變更，從 IPC、`wayland-info` 與事件三處回讀 |
| `c18-hotplug.py` | 以 IPC 建立／刪除 headless 輸出，記錄事件與視窗去向 |
| `c19-lock-client-death.py`＋`lock-holder.c` | 鎖定後 `SIGKILL` 鎖定客戶端，以截圖、輸入與綁定判斷是否仍鎖定 |
| `wfipc.py` | 常駐連線的 Wayfire IPC 客戶端（事件與臨時綁定需要它） |

需要：`~/wayfire` 的凍結 Wayfire、`foot`、`python3`、`wayland-info`、`grim`、C 編譯器、`wayland-scanner`、`wayland-protocols`。`wlr-randr` 不是必要項；沒有它時 C-17 不測 `zwlr_output_manager_v1` 路徑，並在 JSON 中記錄。
