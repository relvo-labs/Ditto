# D-25 自動化測試以開發 VM 為第一線

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-27 |
| 狀態 | 已決定 |
| 決策者 | 使用者（參考機 owner）＋平台工程 |

## 結論

G0 的自動化測試先在參考機上的 libvirt 開發 VM `ditto-g0-vm` 執行（`tools/dev-vm/run.sh`）：還原快照、安裝目前的工作樹、跑 G0 夾具、登入層檢查與 cold-login 流程格式檢查，跑完即關機。會中斷工作階段、重啟 GDM 或需要重複登入的測試，一律先在 VM 通過，才上實體參考機。

**這不改變任何出口門檻。** VM 的結果一律標為 `development-vm`，不是 EX-01～EX-09 的證據。出口數字仍只在凍結的實體參考機上取得（plan/02/01、D-01）；EX-08 仍要實體鍵盤並錄影，第二人重建仍由另一個人在符合資格的機器上完成。

## 依據

- 2026-09-26 在參考機上除錯時，多次需要登出、重啟 GDM、結束工作階段，每次都打斷使用者，也讓一次登入量不到 EX-05。使用者於 2026-09-27 要求把 VM 列為優先的自動化測試方案。
- VM 內已實測：
  - GDM 自動登入後進入 Ditto 工作階段，Wayfire 從自己的 user scope 取得 seat（DRM backend），四個分層 scope 都成立。
  - SIGKILL GDM 主程序後，drop-in 會結束孤兒工作階段，新的自動登入正常。
  - cold-login 流程可跑完三次登入並產生報告，也在第一次實跑時抓到跨次 exclusion 名稱不一致的缺陷。
- VM 建置時發現 `apt-packages.txt` 漏列 `libjemalloc2`、`libliftoff0`、`libseat1`，這正是第二人重建會踩到的缺口。

## 考慮過但沒選的方案

- **只在參考機上自動化（GDM 自動登入＋runner 排程）**：仍然需要，但只用在正式量測；日常回歸若也放在參考機，會與使用者的工作階段和 nightly 量測互相干擾。
- **VM 結果經換算後當出口證據**：沒有實體 GPU，核心、Landlock 與 cgroup 事實也不同，違反「量測不得自我放寬」，因此拒絕。

## 影響

- 新增 `tools/dev-vm/`（建立、佈建、執行）與 `.github/workflows/vm-regression.yml`（self-hosted `ditto-ci`，PR 與每日排程）。
- VM 與參考機量測不得同時執行：`run.sh` 結束時一律關機；runner 只有一台，工作本來就逐一執行。
- VM 使用 Ubuntu 24.04.5／kernel 6.8，Wayfire、Qt／Quickshell、Node 直接複製參考機的凍結前綴；它驗證的是流程與行為，不是平台指紋。
