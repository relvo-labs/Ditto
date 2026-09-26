# D-01 G0 參考平台與應用集合

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-22 |
| 狀態 | 已決定 |
| 決策者 | 產品 owner Lei-k ＋平台工程 |

## 結論

G0 以 `ditto-ref-ws-rtx4060-01` 為主要出口參考機：Ubuntu 24.04.2 LTS、kernel 6.17.0-40、Ryzen 9 7945HX、RTX 4060／NVIDIA 570.211.01、60.5 GiB RAM、NVMe。量測模式固定為 1920×1080、60 Hz、scale 1。

參考應用固定為 Firefox（原生 Wayland）、foot 與 Kate；XWayland 只做相容性對照，不進 EX-01 的參考應用集合。其他機器仍可開發與跑非出口測試；它們的結果標成 development evidence，不得與本機的三次重複量測合併。

## 依據

- 完整機器與版本指紋：[`packaging/reference-image/reference-machine.lock.json`](../../../packaging/reference-image/reference-machine.lock.json)。
- 可重建步驟與 preflight：[`packaging/reference-image/README.md`](../../../packaging/reference-image/README.md)。
- 工作站既有的 GPU、Qt／Quickshell／Wayfire 與平台事實實測：[`docs/platform/dev-wayland-environment.md`](../../../docs/platform/dev-wayland-environment.md)。
- 使用者於 2026-09-22 明確確認這台工作站是參考機之一，且開發不限定在參考機進行。

## 考慮過但沒選的方案

- **原規劃的 RTX 3060／16 GB 候選**：沒有可登入機器、版本指紋或 runner，不能產生出口證據；保留為未來新增參考機候選，不能與本機結果混算。
- **開發 VM**：沒有實體 GPU，Landlock、cgroup 委派與 Secret Service 結果也和工作站不同，只適合非圖形測試。
- **把所有開發機都視為參考機**：會讓幀時與 PSS 數字不可比較，因此拒絕。

## 影響

- G0-PLAT-01、D-03、D-06 與 EX-01／03／04／05／08／09 的證據都綁定此指紋。
- runner 使用 `ditto-refmachine` label；preflight 漂移即拒絕量測。
- 核心、GPU driver 或參考應用版本變動後，須建立新指紋與同機器的新量測序列，不能續接舊的三次重複。
