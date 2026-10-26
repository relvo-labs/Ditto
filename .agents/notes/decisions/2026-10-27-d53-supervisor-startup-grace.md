# D-53 supervisor 的 Shell 啟動寬限

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-27 |
| 狀態 | 已決定（coordinator 依 owner 指示修正 #226，待 owner 檢視） |
| 決策者 | coordinator；owner Neil 2026-10-27 指示「一進桌面就會到救援模式，深入分析並修正此問題」 |

## 結論

`ditto-supervisor` 對每一代剛武裝的 Shell 給 60 秒啟動寬限：寬限內要連續 10 次無回應（約 19～21 秒）才判定無回應；寬限結束後維持 [plan/03/05 §3](../../../plan/03/05-platform-supervision-and-rescue.md) 的連續 3 次（約 6～7 秒）。門檻依每次無回應被觀察到的時間決定，連續次數跨過寬限結束不歸零。

## 依據

- [#226](https://github.com/relvo-labs/Ditto/issues/226) 的重現：v0.7.0-preview.1 安裝後的磁碟在 QEMU TCG 上登入即進入救援（`reason=shell_unresponsive`），journal 顯示武裝後約 8 秒就以 3 次規則觸發；KVM 五組設定都正常。
- 拿掉觸發後以 200 ms 間隔量 ping 往返（TCG）：Core handshake 前後停頓 6.1 秒，開機供應者 commit 後停頓 5.1 秒，再接 2.05 秒、1.09 秒的慢回覆，約 25 秒後穩定在 0.3 秒以下；KVM 最大 0.5 秒。以 1 秒期限、2 秒間隔計，最長可能連續約 5 次無回應。
- 10 次約為最長單次停頓的 3 倍、最長慢回覆區間的 2 倍；60 秒約為所有實測停頓結束時間的 2 倍以上。寬限長度只決定套用哪個門檻，不影響卡死的上限。
- 修正前，第一次回 `pong` 之前卡住的 Shell 本來就不在 supervisor 的 6 秒範圍內（README 交給 Core 的啟動就緒檢查）；這次把剛武裝後的啟動期改為有界的較寬門檻，而不是放任。

## 考慮過但沒選的方案

- 全面把 `--misses` 調高：會放寬常態期，違反 NFR-08 的 10 秒，也違反「量測不得自我放寬」。
- 等 Shell 回報 `shell.report` 或開機 commit 完成才武裝：supervisor 要依賴 Core 或 Shell 的狀態，違反 supervisor 獨立於被監督者；且第二次停頓就在開機 commit 之後。
- 寬限內完全不觸發：啟動中真的卡死就永遠不進救援。
- 跨過寬限結束的連續無回應沿用啟動門檻：寬限邊界附近卡死的 Shell 會得到比常態寬鬆的處理，常態規則被變相放寬。
- 降低 Shell 主執行緒停頓（供應者非同步載入等）：是根本改善，但改動 Shell，另開 follow-up；supervisor 仍需要對慢機器有容忍。

## 影響

- `crates/ditto-supervisor`：新增 `--startup-grace-ms`（預設 60000，0 為關閉）與 `--startup-misses`（預設 10，不得小於 `--misses`）；日誌以 `phase` 區分 `startup` 與 `steady`，並記 `grace_ended`。既有旗標與預設不變。
- plan/03/05 §3「Shell 無回應」一列加上例外。常態期與 NFR-08 不變；啟動寬限內卡死到觸發的上限約 21 秒，救援介面啟動時間另計。這段時間只有單元測試證據，VM 驗收由 #226 追蹤。
- 已知限制：新 Shell 若在一個 ping 間隔內取代舊 Shell、supervisor 沒觀察到「不存在」，不會重新寬限。
