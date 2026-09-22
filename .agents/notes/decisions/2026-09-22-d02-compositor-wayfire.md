# D-02 合成器選擇：Wayfire，Sway 遺棄

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-22 |
| 狀態 | 已決定（方向），**C-08 仍未探測**，見下方「尚未成立的部分」 |
| 決策者 | 產品 |

## 結論

**Ditto 以 Wayfire 為合成器。Sway 支援標為遺棄**：`crates/ditto-compositor/src/sway.rs` 保留為 D-02 的對照證據，不再是支援目標，不接受新功能，預設路徑與測試不再走它。

## 依據

這是 G0 第一次有兩個合成器的實測可以比較。原始資料：

- `artifacts/g0/compositor-probe-wayfire-0.11.0-d3990237-2026-09-21T18:23:44Z-35a1.json`
- `artifacts/g0/compositor-probe-sway-1.12-2026-09-21T18:04:11Z-000.json`
- `artifacts/g0/window-matrix-2026-09-21T18:21:19Z-35a1.jsonl`（Wayfire）與同日的 Sway 版本
- 逐列對照見[能力差異表](../../../docs/platform/compositor-capability-matrix.md)

決定性的三項差異：

1. **C-03 視窗控制。** Wayfire 六項請求（activate／maximize／unmaximize／fullscreen／unfullscreen／minimize）全部回讀成立；Sway 的 maximize 與 minimize 請求後狀態不變。能力矩陣的結果一致：Wayfire `verified=12 unsupported=0`，Sway `verified=8 unsupported=4`。
2. **C-07 命中區與點擊穿透。** Wayfire 的 `stipc` plugin 能注入指標事件，因此這一列第一次有判定：透明區的點擊穿到下層視窗並使其取得焦點，不透明區的點擊由角色層接收，雙向都成立。Sway 在開發容器內沒有任何指標注入路徑，這一列至今無法探測。
3. **C-04 座標。** Wayfire 的視窗預設浮動，`move`／`resize` 對一般視窗即成立；Sway 必須先 `floating enable`，平鋪視窗回 `unsupported`。

## 考慮過但沒選的方案

- **Sway**：C-03 少兩個狀態、C-07 在既有環境無法探測，且工作區雖有 `ext_workspace_manager_v1` 公告卻無客戶端實作，中立協定的優勢在 G0 沒有兌現。它的 IPC 成熟、文件完整，若 Wayfire 在 G1 出現阻斷級問題，這是第一個會被重新提起的選項——`sway.rs` 因此保留而不刪除。
- **Hyprland**：Quickshell 對它的整合最完整（工作區、全域快捷鍵、focus grab 都有專門支援），但它的設定與外觀模型強勢，與「桌面的外觀由插件組成」的產品前提衝突，且 API 變動頻率高於 Wayfire。沒有實測資料，這是依據上游文件與發布節奏的判斷。
- **自寫合成器**：不在 G0～G5 的範圍，成本與風險都超出 MVP。

## 尚未成立的部分

**D-02 的預先承諾判準要求 C-01／02／03／06／07／08 六項都有結論，目前 C-08 沒有。** 已知的事實是：Wayfire 把 `text_input_v3` 與 `input_method_v2` 放在 `workarounds/enable_input_method_v2` 選項後面，預設關閉；開啟後兩個 global 出現，但 fcitx5、候選視窗位置與三個應用的實測尚未進行（G0-PLAT-04）。

因此這份紀錄的狀態是「方向已定」，不是「G0 出口門檻已通過」。若 C-08 在 Wayfire 上出現阻斷級問題，本決策須重新評估，屆時寫新紀錄並指向本檔。

## 影響

- `crates/ditto-compositor/src/wayfire.rs` 成為主要後端；`sway.rs` 標為遺棄但保留編譯與測試，確保上述對照證據可重現。
- 預設合成器（Core 的偵測順序、`DITTO_COMPOSITOR`、G0 腳本）改為 Wayfire。
- 開發容器只有 Sway，因此它不再是主要驗證環境；主要開發機是[工作站](../../../docs/platform/dev-wayland-environment.md)。
- Ditto 在 Wayfire 上需要的 plugin 是硬需求，不是建議：`ipc`、`ipc-rules`（查詢與事件）、`wm-actions`（minimize）、`vswitch`（工作區切換）。缺少後兩者時對應能力回 `unsupported`。
- Quickshell 沒有 Wayfire 的工作區整合（R-01），Ditto 因此不依賴它：工作區一律經 Core 的 `desktop.workspaces.*`，而那條路徑已由 `wayfire.rs` 實作並回讀驗證。
