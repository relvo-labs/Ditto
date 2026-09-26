# 參考機 GitHub Actions runner

- Runner：2.337.0，Linux x64。
- 官方 archive SHA-256：`70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613`。
- GitHub 名稱：`ditto-ref-ws-rtx4060-01`。
- 自訂標籤：`ditto-refmachine`（真機工作流）、`ditto-ci`（一般 CI；其他開發機也可提供）。
- 安裝位置：`$HOME/actions-runner-ditto-ref`；work 目錄 `_work`。

服務必須以 `systemd --user` 執行。若裝成 system service，job 會落在 `system.slice`，Firefox snap 會拒絕啟動，EX-01 的瀏覽器證據無效。安裝後把本目錄的 unit 複製到 `$HOME/.config/systemd/user/`，執行 `systemctl --user enable --now github-actions-ditto-ref.service`，並以 `loginctl enable-linger` 確保登出後仍接工作。

註冊 token 是短效秘密，不寫入倉庫或日誌。重建時從 GitHub repository runner API 取得，先驗 archive checksum，再以 `config.sh --unattended` 註冊。每次 nightly 開始仍須跑 reference preflight；runner 在線本身不代表指紋相符。
