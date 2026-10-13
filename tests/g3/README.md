# G3 開發驗證

| 命令 | 範圍 | 證據限制 |
| --- | --- | --- |
| `bash tests/g3/run.sh` | Rust 描述／資料／修復、Qt lint／QtTest、固定 native runner 建置 | 固定模板單元測試，不能代替真實模型 |
| `node tests/g3/integration/run.mjs` | 正式 Core → 工作池 → 隔離 native 五關 → 發布；缺 Shell 啟用安全中止 | 生產政策與故障交易的開發證據 |
| `bash tests/g3/desktop/build.sh` | hostd／Agent 與內建套件建置 | 執行前先 `pnpm install --frozen-lockfile` |
| `bash tests/g3/desktop/run.sh` | 真 Wayfire／Shell／hostd：資料、預覽、兩槽／排隊／取消、升版、資料快照 undo、實際按鈕切工作區與原生應用存活 | headless 開發桌面；不是實體座位／效能驗收 |
| `bash tests/g3/restart/run.sh` | 兩個真實預覽中止 Core、回收舊 scope、回讀歷程並啟動新工作 | headless 開發故障證據 |
| `bash tests/g3/agent/run.sh` | 釘選 Codex app-server + loopback 腳本模型，真實動態工具／授權／原生驗證／啟用／多輪修改／來源刪除／退出後存活 | 不使用真訂閱、外部模型或既有帳號；不計模型品質 |
| `python3 tests/g3/host/rejection.py` | 缺 bus、非法命令／deadline／私有 runner 拒絕 | 不執行超限程式 |
| `bash tools/dev-vm/run-g3.sh` | 還原閒置 VM、建置、上述流程與十項 OS 故障 | D-25 開發 VM，保存所有失敗與未執行 |
| `DITTO_VM_SNAPSHOT=ditto-base DITTO_G3_EXPECT_OLD_ABI=1 bash tools/dev-vm/run-g3.sh` | ABI <6 的診斷與正式 Core partial 拒絕 | 完整候選執行刻意 `not_run`，runner 退出 2 |
| `bash tests/g3/host/run.sh` | cgroup、Landlock、seccomp、OOM／fork／timeout／取消／清理 | VM 先跑；參考機另保留桌面 PID／revision |

執行 Core 整合前 `cargo build --locked -p ditto-core -p ditto-test-host -p ditto-confine`，再 `bash tools/generation-host/build.sh`；桌面入口使用固定 Wayfire／Qt 前綴與 Quickshell。OS driver 在實際額度成立後才執行故障，原始 JSON、stderr 與 summary 留在 artifacts/g3；VM 收集至 artifacts/g3-vm。ExecStopPost 在候選工作區外保存 systemd 的終止原因，避免瞬時單位被回收後失去 timeout／OOM 事實。

新整合紀錄包含 git commit、dirty 與整棵來源 SHA256（含尚未追蹤檔）、kernel、native runner hash；validation 保存 service unit、cgroup、runner PID、實際政策與五關結果。診斷探針使用 diagnostic-v1，永遠沒有啟用資格；正式候選必須 generated-templates-v1/full 且清理完成。

真實模型與參考機完整流程仍依 #28／G3-exit 逐項記錄；腳本模型不可代替。既有帳號／外部傳送的真實訂閱測試本次遭自動核准拒絕，須取得使用者明確授權後執行。資源 p95／動畫／實體中文與雙螢幕不由本套件宣告通過。

已準備 `tests/g3/agent/real.sh` 與四回合 natural-language oracle；只在明確授權後設定 `DITTO_G3_ALLOW_REAL_MODEL=1` 及私有開發測試 `DITTO_G3_SUBSCRIPTION_STORE` 執行。它新建 default 測試 Profile，完成後恢復原 Profile／設定並撤銷本次授予；不在 CI 自動執行。
