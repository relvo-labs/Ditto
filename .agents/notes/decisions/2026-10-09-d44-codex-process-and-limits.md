# D-44｜Codex app-server 的程序架構與記憶體上限

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-09 |
| 狀態 | 已決定；2026-10-13 先套寬鬆上限，收緊待 #35 |
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

## 2026-10-13 更新（owner）

- 參考機冷登入（G2 評審 §3.6）：暖態 Agent p95 88.6～89.2 MiB，在 150 MiB 預算內；turn 進行中 app-server 單程序 PSS 達 159～209 MiB、controller 37～38 MiB。暫定的 256 MiB 不足以涵蓋活動中的峰值，且 cgroup 另計檔案快取與 kernel 記憶體。
- 決定：現階段以驗證功能為主，不採嚴格上限。Codex 後端 scope（`ditto-agent-backend.scope`：`ditto-confine`＋app-server）套 `Quota::agent_backend()`＝`MemoryMax=1G`、`CPUQuota=200%`、`TasksMax=256`；controller 維持 D-06b 的 256M／50%／32。暖態 PSS ≤150 MiB 的預算不變。
- 之後的優化（#35）：記錄 `memory.current`／`memory.peak`、兩個 scope 改掛同一 Agent slice、依數據收緊並設 `MemoryHigh`、正式 session 強制 `DITTO_REQUIRE_QUOTA`、OOM 故障測試。
