# D-03 G0 工具鏈凍結

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-22 |
| 狀態 | 已決定 |
| 決策者 | 產品 owner Lei-k ＋Core／Shell |

## 結論

G0 凍結 Rust 1.98.1、Node 22.23.2、pnpm 10.11.0、Qt 6.10.2、Quickshell 0.3.1（commit `1a4716cde794a59928d9d9fc15f2afc7a95de360`）與 Wayfire 0.11.0（build `d3990237`，wlroots 0.20.2）。

## 依據

- 倉庫鎖定：`rust-toolchain.toml`、`.nvmrc`、`package.json#packageManager`、`Cargo.lock` 與 `pnpm-lock.yaml`。
- 私有前綴與上游 revision：[`packaging/reference-image/source-builds.lock`](../../../packaging/reference-image/source-builds.lock)。
- 本機等價 CI 實跑：Rust 41 項與 TS 9 項測試、fmt、clippy、schema freshness、能力目錄、avatar mask 與 skill lint 全部通過。
- Node 22.23.2 落在未來 Cordis／Harness 所要求的 `>=22.19.0` 範圍內；G0 桌面工作階段本身仍不常駐 Node。

## 考慮過但沒選的方案

- **Ubuntu 內建 Qt 6.4.2**：低於 Quickshell 的最低需求，且不能載入已以 Qt 6.10.2 建置的 Quickshell。
- **浮動 latest**：無法重建、也會讓 runner 的幀時與 PSS 序列失去可比性。
- **把 Fcitx Qt 6.4 plugin 載入 Qt 6.10**：Qt private ABI 不相容，已實測失敗；Quickshell 先走原生 Wayland text-input 路徑。

## 影響

- reference preflight 與 CI 以這組版本拒絕漂移。
- 任一版本升級都要重新跑契約、窗口矩陣、輸入法、幀時與資源量測；不是單純更新文件。
