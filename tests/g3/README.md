# G3 開發驗證

| 命令 | 範圍 | 證據限制 |
| --- | --- | --- |
| `bash tools/dev-vm/test-artifact-collection.sh` | 唯讀套件證據的內容／來源權限保留、接收副本可刪除；不需 VM | CI checkout 回歸，不是候選執行證據 |
| `bash tests/g3/run.sh` | Rust 描述／資料／修復、固定模板與正式管理中心 QtTest、native runner 建置 | 兩組 QtTest 共 11 項；不能代替真實模型 |
| `node tests/g3/integration/run.mjs` | 正式 Core → 工作池 → 隔離 native 五關 → 發布；缺 Shell 啟用安全中止；三類未信任 archive 安裝／啟用拒絕 | 生產政策與故障交易的開發證據 |
| `DITTO_G3_TRUST_ONLY=1 DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/ditto-g3-test-bus node tests/g3/integration/run.mjs` | 真正不可用隔離的 QML／Node／原生 ELF 安裝矩陣、權威拒絕與 revision／執行見證 | 不模擬 full；同一矩陣也在 full／partial Core 整合執行 |
| `bash tests/g3/desktop/build.sh` | hostd／Agent 與內建套件建置 | 執行前先 `pnpm install --frozen-lockfile` |
| `bash tests/g3/desktop/run.sh` | 真 Wayfire／Shell／hostd：兩槽、升版 undo、連續兩次修改回第一版、相容回退保留新值、不可逆拒絕、移除保留資料、實際按鈕與原生應用存活 | headless 開發桌面；不是實體座位／效能驗收 |
| `bash tests/g3/restart/run.sh` | 兩個真實預覽中止 Core、回收舊 scope、回讀歷程並啟動新工作 | headless 開發故障證據 |
| `bash tests/g3/agent/run.sh` | 釘選 app-server + loopback，真實動態工具、一次性啟用 approval 且無永久 data grant、原生驗證、多輪修改、來源刪除與退出後存活 | 不使用真訂閱、外部模型或既有帳號；不計模型品質 |
| `python3 tests/g3/native-failures/driver.py` | 真 Qt runner 的 syntax／contract／load／focus／interaction 逐關失敗及非法 import；各自受實際 cgroup 與 confine 限制，後續關卡不執行 | 可信測試 fixture；不新增任意候選入口或正式 fault switch |
| `python3 tests/g3/host/rejection.py` | 缺 bus、非法命令／deadline／私有 runner 拒絕 | 不執行超限程式 |
| `bash tools/dev-vm/run-g3.sh` | 還原閒置 VM、建置、上述流程與十項 OS 故障 | D-25 開發 VM，保存所有失敗與未執行 |
| `DITTO_VM_SNAPSHOT=ditto-base DITTO_G3_EXPECT_OLD_ABI=1 bash tools/dev-vm/run-g3.sh` | ABI <6 的診斷與正式 Core partial 拒絕 | 完整候選執行刻意 `not_run`，runner 退出 2 |
| `bash tests/g3/host/run.sh` | cgroup、Landlock、seccomp、OOM／fork／timeout／取消／清理 | VM 先跑；參考機另保留桌面 PID／revision |

執行 Core 整合前 `cargo build --locked -p ditto-core -p ditto-test-host -p ditto-confine`，再 `bash tools/generation-host/build.sh`；桌面入口使用固定 Wayfire／Qt 前綴與 Quickshell。OS driver 在實際額度成立後才執行故障，原始 JSON、stderr 與 summary 留在 artifacts/g3；VM 收集至 artifacts/g3-vm。ExecStopPost 在候選工作區外保存 systemd 的終止原因，避免瞬時單位被回收後失去 timeout／OOM 事實。

新整合紀錄包含 git commit、dirty 與整棵來源 SHA256（含尚未追蹤檔）、kernel、native runner hash；validation 保存 service unit、cgroup、runner PID、實際政策與五關結果。診斷探針使用 diagnostic-v1，永遠沒有啟用資格；正式候選必須 generated-templates-v1/full 且清理完成。

VM 收集使用 `vm_collect_artifacts`，只增加接收證據副本的 owner 讀寫／目錄進入權限，保留來源內容、時間戳與 guest 唯讀套件；非 VM Core 整合則在停止私有 fixture 後恢復其測試 store 的 owner 寫入權限。兩者都保留原始證據，避免下一次 CI checkout 被 `0500` 套件目錄阻擋。

修復回歸包含三輪上限、同錯停止、無連續關卡進展／退步停止，以及重新開啟 Store 後同回合改接舊父版本／更換插件 ID 的拒絕。完整工作包與剩餘驗收見 [plan/05 完成缺口盤點](../../plan/05/07-completion-audit.md)。

真實模型與參考機完整流程仍依 #28／G3-exit 逐項記錄；腳本模型不可代替。首次交付時真實訂閱測試因既有帳號／外部傳送授權不明遭自動核准拒絕；本次取得使用者明確授權後，headless 真模型 oracle 已有 15 項通過證據，見 [後續評審](../../.agents/notes/gate-reviews/G3-followup-2026-10-14.md)。實體座位、資源 p95／動畫／中文與雙螢幕不由本套件宣告通過。

本次進一步修正實際 artifact 回讀與 coordinator 撤權檢查，新增 5 個 Core 交易測試（包含三個啟用失敗時點、資料提交失敗、兩次升版回退、不可逆／損壞快照拒絕及撤權），另補管理中心重開／進度／雙預覽鍵盤取消。最新真模型四回合 **19 項通過**；完整結果與版本差異見 [功能補齊紀錄](../../.agents/notes/gate-reviews/G3-functional-completion-2026-10-14.md)。前一輪 15 項仍保留原始計數。

`tests/g3/agent/real.sh` 與四回合 natural-language oracle 只在明確授權後設定 `DITTO_G3_ALLOW_REAL_MODEL=1` 及私有開發測試 `DITTO_G3_SUBSCRIPTION_STORE` 執行。它新建 default 測試 Profile，檢查實際面板與工作區按鈕，完成後獨立恢復原 Profile／設定、撤銷本次授予並逐項回讀；清理失敗也保留證據並退出失敗。不在 CI 自動執行。
