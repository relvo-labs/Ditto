# D-24 `ditto-qml-shell` 轉為 stable

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-22 |
| 狀態 | 已決定 |
| 決策者 | Shell ＋ G0 owner Lei-k |

## 結論

`ditto-qml-shell` 從 `draft` 轉為 `stable`。第 4 步的實際契約固定為：由角色素材 alpha 通道在建置期產生多矩形遮罩，Quickshell 以 Wayland surface input region 套用；透明區必須穿到下層視窗，實心區必須由角色收到。全域游標位置不可得時，注視只在角色互動區內生效，不加入高頻輪詢。

## 依據

- `tests/g0/avatar-hit-region/run.sh` 對 Shell 生產用的 24 個矩形直接做雙向點擊；2026-09-22 開發工作站實跑結果為 `passed_through: true`、`received_on_opaque: true`。
- `tools/compositor-probe/functional/hit-region.sh` 的合成器中立夾具在 Wayfire 上也通過雙向條件，結果已回寫 `docs/platform/compositor-capability-matrix.md` 的 C-07。
- `tools/avatar-mask/generate.py --check` 驗證遮罩是素材 alpha 的新鮮產物；Shell 啟動時確認套用 24 個區域。
- 熱路徑腳本確認待命、游標與拖曳期間不發 RPC；角色動畫留在 QML。

## 考慮過但沒選的方案

- **維持 draft 到實體輸入完成**：輸入來源不改變 Wayland input region 的命中語意；實體輸入仍是 G0 出口證據的一部分，但不再阻擋這份程序規則穩定化。
- **只引用一矩形夾具**：不能證明生產遮罩有接線，因此新增 24 矩形的直接測試後才轉 stable。
- **用角色視窗整個矩形接收輸入**：透明區會阻擋底下應用，違反本 skill 與 AVA-05。

## 影響

- D-24 結案；skill 索引同步標記 `stable`。
- nightly 增加生產遮罩測試，未來素材或 QML 接線退化會留下失敗證據。
- EX-04 的實體幀時與 EX-08 的實體鍵盤仍是獨立門檻，不因本決策自動通過。
