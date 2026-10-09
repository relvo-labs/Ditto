# D-44｜Codex app-server 的程序架構與記憶體上限

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-09 |
| 狀態 | 已決定；硬上限在參考機冷登入量測後套用 |
| 決策者 | 使用者／專案 owner Lei-k（採 [G2 評審](../gate-reviews/G2-exit.md) §5 提案） |

## 結論

- 程序架構依實作定案：Core 單例管理的 1 個 Node controller，加上至多 1 個在 `ditto-confine`（Landlock＋seccomp）裡的 Codex app-server，以及過濾的 session-bus proxy；無活動 5 分鐘後整組回收。
- 硬上限：整個 Agent scope 暫定 `MemoryMax` 256 MiB；參考機冷登入量測（EX2-14）確認餘裕之前不套用。暖態 Agent PSS 合計 ≤150 MiB 的預算不變。

## 依據

- 開發機量測：一個 turn 後 Agent 群組 102～115 MiB（controller 15.7～19.4、app-server 87.2～94.5、confine 0.5、proxy 0.5 MiB），各次之間差約 13 MiB；新啟動約 63 MiB（G2 評審 §5）。
- 程序邊界：[codex-backend-boundary](../../../docs/platform/codex-backend-boundary.md)；`ditto-confine` 在啟動者消失時停止後端（`b868329`）。
- 參考平台的 AppArmor 禁止非特權 user namespace，bubblewrap 與 Codex 內建 sandbox 不能用（評審 §4.2）。

## 考慮過但沒選的方案

- 現在就套 256 MiB：沒有參考機數據，可能在真實負載下殺掉後端，造成看似隨機的對話失敗。
- 更高的上限（512 MiB）：開發機數據顯示用不到，給太多等於沒有限制。
- 常駐 app-server：違反「Agent 退出不得中斷桌面」的另一面——桌面不需要它常駐，也違反 NFR-13 冷啟動的量測前提。

## 影響

- `milestones/01/05` 的 D-44 列改為已決定。
- EX2-14 完成後，依數據套用 `MemoryMax`（或附數據提出調整），寫回本紀錄與評審。
