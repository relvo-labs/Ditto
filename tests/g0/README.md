# G0 驗證腳本

每個腳本都印出它證明了什麼、以及它**不能**證明什麼。在開發容器或開發 VM 取得的結果是開發證據，出口門檻的判定只接受凍結的實體參考機。

## 在開發容器內執行

```sh
bash tests/g0/run-in-container.sh <script>
```

會先在主機建置二進位檔，再以唯讀掛載的方式在 Wayland 開發容器內執行。

| script | 對應 | 這次執行證明了什麼 |
| --- | --- | --- |
| `window-matrix` | EX-01 | 能力 × 視窗形態的每一格都有明確結果：回讀一致的成功，或 `unsupported`。輸出 `artifacts/g0/window-matrix-<run_id>.jsonl` |
| `identity-negative` | EX-07 | 啟動器啟動的客戶端可用；複製的 token、沒有綁定的連線、自填身分三種都被明確拒絕 |
| `shell-session` | SHELL-01／03／04 | 工作階段啟動、exclusive zone 生效、命中遮罩套用、熱路徑零請求、喚回路徑可達、Core 終止後角色仍存活 |
| `shell-restart-survival` | EX-03 | 20 次重啟（10 次正常、10 次 `SIGKILL`）後參考應用全部存活、未儲存內容雜湊不變 |
| `hotpath` | EX-04 | 四段互動腳本的逐段幀間隔與請求數；動畫期間 0 個請求，5 次明確命令各 1 個 |
| `compositor-probe` | EX-02 | 兩層探針（全域列舉＋功能探測）的結構化輸出；未能探測的列標明原因 |
| `input-method` | EX-08 的自動化診斷 | 記錄 Wayfire 協定、Qt text-input-v3 啟用、Fcitx 引擎與 QML 實際文字；未提交中文即保留 JSON／截圖並失敗。`stipc` 不能代替實體鍵盤；登入後由 `manual-session.sh` 一次完成 QML／foot／Kate、三處候選位置與三方剪貼簿 |
| `avatar-hit-region` | G0-SHELL-03 生產遮罩 | 對 Shell 實際的 24 個 alpha 遮罩矩形做雙向點擊：透明區穿到下層、實心區由角色收到 |

## 在有 `systemd --user` 的主機執行

| script | 對應 | 說明 |
| --- | --- | --- |
| `quota-baseline/run.sh` | QA-03 | 記憶體、CPU、程序數三個配額案例與平台事實；開發 VM 上 CPU 配額因未委派控制器而未生效 |
| `measure/run.sh` | QA-01／EX-05 | 暖機、採樣、三次重複與報告；以三個 user service 提供穩定 cgroup 歸屬。非參考機需 `DITTO_FORMAT_CHECK=1`。自動 runner 只重啟服務、不是登入管理器 cold login，因此現行條件檔會誠實標成不可作 EX-05 最終證據 |

## 為什麼容器的結果不能當出口證據

容器是 headless、Pixman 軟體算繪、沒有 GPU、沒有實體輸入裝置、沒有輸入法，套件來自會變動的 Debian testing。幀時、記憶體、輸入法與點擊穿透都必須在凍結的參考機上重跑；見 [plan/02/01](../../plan/02/01-scope-and-exit-criteria.md) 的九項門檻。

輸入法另有 `tests/g0/input-method/manual-session.sh`。它只能從實際 Ditto Wayfire 登入工作階段中的 foot 執行，會保留實體鍵盤在 QML／foot／Kate 的提交結果、三處候選窗位置、QML 候選窗截圖與三方剪貼簿結果；它不會啟動或替換目前的合成器、D-Bus 或 Fcitx。EX-08 仍須另附同次流程的錄影位置。
