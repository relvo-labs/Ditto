# D-19 真機 CI runner 取得方式

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-22 |
| 狀態 | 已決定並已註冊 |
| 決策者 | G0 owner Lei-k ＋ QA／平台工程 |

## 結論

以主要參考機 `ditto-ref-ws-rtx4060-01` 作 repository-level self-hosted runner。`ditto-refmachine` 專供需要凍結實體機的 nightly／weekly；`ditto-ci` 供一般 CI，未來其他開發機可加入後者，不把開發綁死在參考機。

Runner 以 user systemd service 執行並啟用 linger，不使用 system service。

## 依據

- GitHub runner API 已回報 runner 2.337.0 為 `online`，標籤包含 `self-hosted`、`Linux`、`X64`、`ditto-refmachine`、`ditto-ci`。
- service cgroup 為 `/user.slice/user-1000.slice/user@1000.service/app.slice/github-actions-ditto-ref.service`。
- 官方 archive 的 SHA-256 驗證通過；重建資料見 `packaging/reference-image/runner/README.md`。
- Firefox snap 在 system-service cgroup 下實測拒絕啟動；移至 user service 後，三應用能力矩陣可完整執行。

## 考慮過但沒選的方案

- **GitHub-hosted runner**：帳戶目前因 billing／spending limit 在 job 開始前失敗，且無實體 GPU／參考應用，不能產生 G0 真機證據。
- **runner 裝成 system service**：會破壞 Firefox snap 的參考應用路徑。
- **所有 CI 都要求 `ditto-refmachine`**：會把一般開發與昂貴真機工作耦合，因此另設 `ditto-ci`。

## 影響

- D-19 取得方式結案，R-19 從「沒有 runner」降為「需監看穩定度」。
- EX-09 仍必須由更新後的 nightly 連續三晚成功才能通過；註冊完成不等於三晚紀錄完成。
- 一般 CI 改用 `[self-hosted, ditto-ci]`，避開當前 GitHub-hosted billing 阻斷；其他開發機可分擔這個標籤。
