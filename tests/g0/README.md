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
| `shell-session` | SHELL-01／03／04 | 受控啟動器以經驗證、提交並回讀的 ChangeSet 固定舊角色；只採計 pin 後新載入的 24 矩形遮罩，再驗 exclusive zone、熱路徑零請求與喚回；Core 終止後同一 Shell 與舊角色繼續產生幀 |
| `shell-restart-survival` | EX-03 | 20 次重啟（10 次正常、10 次 `SIGKILL`）後參考應用全部存活、未儲存內容雜湊不變 |
| `hotpath` | EX-04 | 四段互動腳本的逐段幀間隔與請求數；動畫期間 0 個請求，5 次明確命令各 1 個 |
| `compositor-probe` | EX-02 | 兩層探針（全域列舉＋功能探測）的結構化輸出；未能探測的列標明原因 |
| `input-method` | EX-08 的自動化診斷 | 記錄 Wayfire 協定、Qt text-input-v3 啟用、Fcitx 引擎與 QML 實際文字；未提交中文即保留 JSON／截圖並失敗。`stipc` 不能代替實體鍵盤；登入後由 `manual-session.sh` 一次完成 QML／foot／Kate、三處候選位置與三方剪貼簿 |
| `avatar-hit-region` | G0-SHELL-03 生產遮罩 | 對 Shell 實際的 24 個 alpha 遮罩矩形做雙向點擊：透明區穿到下層、實心區由角色收到 |

`shell-session` 的 check 1／5 保留舊角色語意（#96），不量 D-48 的預設助理入口。它需要 Node 執行由 Core 以 `dittoctl` 身分啟動的 pin driver，使用啟動器認證，不用 development token，也不改既有 `pin_legacy_avatar` 呼叫。Shell 完成 boot sync 後先記錄 log 行位移，再放行 driver；ChangeSet 必須 committed 且 Profile 回讀一致，遮罩必須出現在該位移之後。Core 終止並回收後重新記錄行位移與時間；check 5 要求原 Shell PID 存活，且 2 秒穩定期後至少有兩筆新的舊角色 FrameProbe 正間隔樣本。缺少遮罩／幀或 pin 失敗都以非 0 結束並印出原因。這只是功能存活證據，幀時與動畫品質仍交參考機量測；handoff 使用 fixture runtime 下每次執行專屬的暫存目錄，結束時清除；45 秒 pin watchdog 從放行 driver 後起算。check 1 輸出附 `change_id` 與 `committed_revision`，讓 runner artifact 可追溯；原始遮罩與幀仍在 runtime 的 `core.log`。

不需實體座位的判定回歸：`bash tests/g0/shell-session/test.sh`。以合成 log 夾具驗證 pin 前遮罩不能通過、新遮罩可以通過、Core 終止前的舊幀與單次斷線重繪不能充當動畫存活證據；此結果不能取代 `fixture-shell-session` 的 Wayfire／Quickshell 實跑。

## 在有 `systemd --user` 的主機執行

| script | 對應 | 說明 |
| --- | --- | --- |
| `quota-baseline/run.sh` | QA-03 | 記憶體、CPU、程序數三個配額案例與平台事實；開發 VM 上 CPU 配額因未委派控制器而未生效 |
| `measure/run.sh` | QA-01／EX-05 | 暖機、採樣、三次重複與報告；以三個 user service 提供穩定 cgroup 歸屬。非參考機需 `DITTO_FORMAT_CHECK=1`。自動 runner 只重啟服務、不是登入管理器 cold login，因此現行條件檔會誠實標成不可作 EX-05 最終證據 |
| `measure/cold-login.sh` | EX-05 | 每次從登入管理器登入後量一次：`prepare <狀態>` 選下一次登入的桌面狀態（`standard`／`avatar-off`／`reduced-motion`），登入後 `sample` 開啟參考應用、暖機 300 秒、採樣 600 秒；同一狀態累積三次不同登入後 `report <狀態>`。Wayfire、Core、Shell、Fcitx 由登入 script 各放在自己的 user scope，依 cgroup 分層；登入超過 600 秒或狀態不符即拒絕 |

## 為什麼容器的結果不能當出口證據

容器是 headless、Pixman 軟體算繪、沒有 GPU、沒有實體輸入裝置、沒有輸入法，套件來自會變動的 Debian testing。幀時、記憶體、輸入法與點擊穿透都必須在凍結的參考機上重跑；見 [plan/02/01](../../plan/02/01-scope-and-exit-criteria.md) 的九項門檻。

輸入法另有 `tests/g0/input-method/manual-session.sh`。它只能從實際 Ditto Wayfire 登入工作階段中的 foot 執行，會保留實體鍵盤在 QML／foot／Kate 的提交結果、三處候選窗位置、QML 候選窗截圖與三方剪貼簿結果；它不會啟動或替換目前的合成器、D-Bus 或 Fcitx。EX-08 仍須另附同次流程的錄影位置。
