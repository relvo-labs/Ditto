# D-47 G3 出口依開發 VM 證據通過

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-17 |
| 狀態 | 已決定；G3 階段完成，未涵蓋項目轉 G4 |
| 決策者 | 使用者／專案 owner |
| 證據 commit | `17f5d76dc043d7d8117f1e99458a9a0c9255354b`（PR #40 head，合併為 `main@39da297`） |

## 結論

owner 接受開發 VM 證據，G3 出口通過。此次 VM 沒有涵蓋的真模型訂閱登入、實體座位重新登入與參考機量測，列為 G4 交接（[#44](https://github.com/relvo-labs/Ditto/issues/44)）。G4 在 PR #40 合併後從 `main` 開始，不採 stacked 分支。

## 依據

- owner 在結構化確認中選擇「接受 VM 證據，G3 出口通過，未涵蓋項列為 G4 交接」，並選擇「等 PR #40 合併後從 main 開始」G4。記錄於 [PR #40 留言](https://github.com/relvo-labs/Ditto/pull/40#issuecomment-6229867828)。
- VM 執行：參考機上的 `ditto-g0-vm`，從 `ditto-g2` 快照還原，在 `17f5d76` 跑 `tools/dev-vm/run-g3.sh`，exit 0，15 步全部 `pass`、`evidence_class=development-vm`：restore、sync、build、foundation、unavailable-trust、rejection、native-failures、native-pipeline-failures、host、production、dependencies、packages、desktop、restart、agent。agent 一步使用釘選 Codex 0.160.0（sha256 `12eb3e81…`）加本機腳本模型，不是真模型。
- 2026-10-14 在 PR 較早的 head 已有實體座位證據（[G3 實體座位驗收](../gate-reviews/G3-reference-seat-2026-10-14.md)）；兩輪審查修正後的 `17f5d76` 沒有重跑實體座位。
- 2026-10-16 兩次參考機 `stage` 在 preflight 停下（`normal active session missing`）：當時登入的是 Ubuntu GNOME，不是「Ditto (Wayfire)」，`systemd --user` 環境沒有 `XDG_SESSION_ID`（來源：[#44 背景](https://github.com/relvo-labs/Ditto/issues/44)）。owner 隨後改為用 VM 驗收。

## 考慮過但沒選的方案

- 有條件通過，之後在參考機補跑未涵蓋項：owner 選擇直接通過，未涵蓋項由 G4 承接。
- 暫不裁定、先寫 G3-exit 報告：owner 選擇當下裁定。

## 影響

- `milestones/01/03` 的 G3 五項出口標為通過，附本紀錄；G3-exit 與專案現況更新。
- **適用範圍只到 G3。** G4 的效能、動畫與資源指標依 [04 §4](../../../milestones/01/04-verification.md#4-ci-與真機-runner) 仍須實體參考機量測；本決策不放寬任何門檻，不把 VM 數字當成 NFR 或 AT-25 證據。
- 真模型 AT-06、實體座位故障與重新登入在 G4 的 [#44](https://github.com/relvo-labs/Ditto/issues/44)、[#56](https://github.com/relvo-labs/Ditto/issues/56) 於合併後的 `main` 重跑。
- #15～#34 的關閉由 owner 另行決定；本紀錄不自動關閉追蹤 issue。
- 為 2026-10-17 切換參考機工作階段而開啟的 GDM 自動登入與預設 `ditto` 工作階段，依 owner 選擇暫時保留；來源及還原清單見 [#44](https://github.com/relvo-labs/Ditto/issues/44)，不把暫時保留當成長期配置核定。
