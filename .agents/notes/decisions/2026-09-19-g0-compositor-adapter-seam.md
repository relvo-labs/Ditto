# G0 合成器轉接的實作路徑（不是 D-02）

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-19 |
| 狀態 | 已決定（僅限 G0 開發路徑） |
| 決策者 | Runtime（Core） |

## 結論

`crates/ditto-compositor` 定義合成器中立的 `CompositorAdapter` 介面，G0 先實作兩個後端：開發容器用的 **Sway IPC** 後端與無合成器時用的 **fixture** 後端；視窗座標與工作區經合成器專屬 IPC 達成，並在能力描述子標記 `bound_to`。

**這不是 D-02。** `milestones/01/05` 的 D-02 傾向是優先驗證 Wayfire，而 Wayfire 至今沒有任何探測結果。本決策只決定「轉接怎麼寫」，不決定「用哪個合成器」。

## 依據

- 功能探針結果（`artifacts/g0/compositor-probe-sway-1.12-*.json` 與 [能力差異表](../../../docs/platform/compositor-capability-matrix.md)）：中立協定涵蓋 C-01、C-02，`zwlr_foreign_toplevel_management_v1` 的 maximize／minimize 在 Sway 上請求後狀態不變；座標（C-04）沒有任何中立協定。
- 能力矩陣實跑（`artifacts/g0/window-matrix-*.jsonl`）：23 格全部有明確結果，寫操作不是回讀一致就是 `unsupported`。
- `ditto-capability-contract` 要求每項能力湊齊 Definition／Provider／Consumer，且不可回讀者不得宣稱成功。

## 考慮過但沒選的方案

- **只用中立 Wayland 協定**：C-04 完全無路徑、C-05 的 `ext_workspace_manager_v1` 雖有公告但 G0 沒有客戶端實作，會讓 DES-03／04 的一半能力在 G0 直接消失。
- **在 Core 內自寫布局管理**：違反所有權邊界（視窗幾何是合成器的狀態），且等於自寫第二套視窗管理器。
- **把 Sway 當成選型答案**：探測資料只涵蓋一個合成器，且在開發容器內取得；用它取代 D-02 會把「碰巧可用」寫成「已決定」。

## 影響

- G1 若 D-02 選了別的合成器，需重寫的只有 `sway.rs`（IPC 綁定的部分），介面、Core 路由與 Shell 不動；重跑探針約 2 天的假設仍成立。
- 能力目錄的 `availability` 由 Core 連線時決定，`bound_to` 欄位讓消費者事前看得到綁定關係。
- C-05 若改走 `ext_workspace_manager_v1` 客戶端，估 1–2 人週（未核定），列入 D-02 的成本比較。
