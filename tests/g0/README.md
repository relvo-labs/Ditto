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

## 在有 `systemd --user` 的主機執行

| script | 對應 | 說明 |
| --- | --- | --- |
| `quota-baseline/run.sh` | QA-03 | 記憶體、CPU、程序數三個配額案例與平台事實；開發 VM 上 CPU 配額因未委派控制器而未生效 |
| `measure/run.sh` | QA-01／EX-05 | 完整量測流程（冷啟動、暖機、採樣、三次重複、產生報告）。非參考機需 `DITTO_FORMAT_CHECK=1`，報告會標記為開發試跑 |

## 為什麼容器的結果不能當出口證據

容器是 headless、Pixman 軟體算繪、沒有 GPU、沒有實體輸入裝置、沒有輸入法，套件來自會變動的 Debian testing。幀時、記憶體、輸入法與點擊穿透都必須在凍結的參考機上重跑；見 [plan/02/01](../../plan/02/01-scope-and-exit-criteria.md) 的九項門檻。
