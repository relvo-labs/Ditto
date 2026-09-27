# G1 出口預檢

| 欄位 | 內容 |
| --- | --- |
| 預檢日期 | 2026-09-27；**尚未進行出口評審** |
| 來源版本 | `effbfb9` 加本工作樹未提交修改；下列本機測試只能算開發證據 |
| 判定 | **G1 未完成，EX1-01～15 均未取得完整出口證據** |
| 判準 | [plan/03/01 §3](../../../plan/03/01-scope-and-exit-criteria.md#3-出口門檻)、[milestones/01/04](../../../milestones/01/04-verification.md) |

本紀錄是逐項缺口預檢，不是正式出口裁決。「開發環境已完成」只代表程式或腳本可執行；實體參考機、已進版 commit、規定的重複次數及人工簽核仍須分別提供。D-37 允許 G0 出口前啟動 G1，但沒有降低任何 G0／G1 門檻。

## 1. 十五項門檻

| 門檻 | 預檢結果與現有證據 | 尚缺 |
| --- | --- | --- |
| EX1-01 手動跨插件切換與保存 | **未通過**；Core／Shell 有交易與供應者實作，`tests/g1/manual-switch/run.sh` 不存在 | 七步 GUI 腳本、真機回讀、視窗與 Kate 緩衝檢查、非實作者人工錄影 |
| EX1-02 安裝預檢拒絕 | **未通過**；`tests/g1/preflight-negative/run.sh` 的開發夾具與 Rust 負例已有紀錄（[測試說明](../../../tests/g1/README.md)） | 六項負例在參考機的插件中心逐項執行、產品文字檢查、已進版 CI 證據 |
| EX1-03 回復 | **未通過**；`tests/g1/rollback/run.sh` 有機制測試 | 視窗已關時撤銷布局的指定情境尚記為 `not_implemented`；跨插件真機回讀與非最新變更衝突證據 |
| EX1-04 清理壓力 | **未通過**；tasks 100 次夾具計數歸零，但 hostd PSS 中位數增加 **13.7%**、Mann-Kendall **p=0.012**（[測試說明](../../../tests/g1/README.md)） | 查明並修正 PSS 成長；Dock 100 次、realm 100 次、Shell PSS 與參考機完整數列 |
| EX1-05 無 Node 救援 | **未通過**；`artifacts/g1/rescue-no-node-2026-09-27T13:05:42Z-effb.json` 的隔離開發夾具 7 項通過（含受保護版本回復及正常模式重建 tasks 後讀回救援前的資料）、1 項環境不足 | 登入工作階段的 Shell 產品文字與參考機完整重跑 |
| EX1-06 跨語言契約 | **未通過**；共享向量與本機 Rust／TS 測試可執行（[測試說明](../../../tests/g1/README.md)） | 已進版 CI、完整 0.2 目錄一致性與跨宿主錯版／重連證據；本機通過不等於出口 |
| EX1-07 Cordis 服務獨立存活 | **未通過**；夾具中終止 Agent 替身後 tasks 事件約 51 ms 到達、hostd PID 不變（[測試說明](../../../tests/g1/README.md)） | 真 QML 面板、通知策略、Shell 終止／重啟與 PID／快照回讀的參考機腳本 |
| EX1-08 L-01～L-10 | **未通過**；Vitest 有 L-01～04、L-08 的檔案與正負例 | L-05～07、L-09～10 的真 Core／hostd 故障測試及各項 PR 快檢、nightly 證據 |
| EX1-09 持久故障 | **未通過**；fault build 的開發夾具正例可執行（[測試說明](../../../tests/g1/README.md)） | 容量受限 tmpfs 的實際寫滿案例及所有指定注入點在參考機回讀；套件暫存清理證據 |
| EX1-10 分層資源 | **未通過**；沒有 `resource-report` 三份；G0 的 D-06a 仍未核定（[G0 預檢](G0-exit.md)） | 四組狀態、三次真正冷登入、300 秒暖機與 600 秒採樣、完整程序清單與預算核定 |
| EX1-11 延遲與應用存活 | **未通過**；tasks 服務替換開發夾具 p95 約 9／8 ms（[測試說明](../../../tests/g1/README.md)） | 真機 200 次本機操作、100 次 Dock 切換、300 次期間參考應用與 Kate 緩衝不變的證據 |
| EX1-12 救援、監督與鎖定 | **未通過**；既有 `artifacts/g1/rescue-supervision-*` 與 `lock-*` 為不完整開發結果 | 登入工作階段的 SIGSTOP／風暴／故障插件、實體鎖定與密碼解鎖、人工錄影 |
| EX1-13 桌面基本面 | **未通過**；`output-hotplug` headless 夾具只證明 Wayfire 搬移視窗，角色可見性記為 `not_implemented` | `desktop-basics` 完整腳本、中文輸入／i18n／音量與網路／角色位置、第二螢幕實體拔插與人工簽核 |
| EX1-14 來源與授權 | **未通過**；`docs/upstream/cordis-port.md`、vendor 守門腳本及依賴清單存在 | 沿用對照表按現況更新、CI 實際擋下一次違規的紀錄、完整授權產物與人工審查 |
| EX1-15 CI 與 nightly | **未通過**；`.github/workflows/nightly-refmachine.yml` 有部分 G1 步驟 | PR 快檢涵蓋 L-01～10；nightly 包含 EX1-01／03／07／09 且連續五晚綠燈；VM 與每週 G1 套件完整接入 |

## 2. 工作包與開工依賴

[plan/03/07 §8](../../../plan/03/07-workplan.md#8-進度紀錄) 的實作方自評為：54 包中 40 包「開發環境已完成」、13 包「進行中」、1 包「未開始」（QA-05）。這是開發進度，並非 40 包獲得出口驗收。當前明確的進行中項目為 CORE-14／17、HOST-12、SHELL-02／05／11、PLAT-01／03／04、QA-02／03／06／07；QA-05 尚未開始。

G0 尚未正式出口：C-08 中文輸入、D-06a 冷登入 PSS、進版後的 nightly 與第二人重建／owner 核定仍見 [G0 預檢](G0-exit.md)。D-04／08／10／15／16／26／27／31 等提案也仍缺決策者核定；D-32／33 有開發決策紀錄，但 `milestones/01/05` 尚顯示待決。第二台實體螢幕尚未取得。這些不是可以靠本機單元測試解除的門檻。

## 3. 本次修補與驗證

- `desktop.profiles.export` 遇到遮蔽後無法反序列化的必要欄位時，現在拒絕匯出；完整匯出封裝另掃描 Profile 名稱等欄位，避免退回原始敏感值。新增兩個負例測試。
- 補上 `docs/contracts/profile-document.md`，明列 Core 所有權、欄位語意與 revision／匯出邊界。
- `tests/g1/rescue-no-node/run.sh` 不再把失敗呼叫的 JSON 與備援 JSON 串成無效輸出；夾具已使用不同 head、受保護版本與內容雜湊做回讀，另以真 hostd 驗證救援前後待辦資料持續存在。
- 救援夾具原先只隔離 socket，會使用預設 Ditto store。修補前的三次本機執行曾開啟該 store；最後一次讀回的 Profile head 在失敗的 `rescue.disable`／`restore_last_good` 前後未變，但 WAL 修改時間有更新，不能排除 Core 開機紀錄或套件盤點寫入。沒有擅自回滾或刪除該 store。現在使用 `mktemp` 專用的 `DITTO_DATA_DIR`，結束後清理該夾具；舊結果不列為出口證據。
- 本工作樹執行 `cargo test --workspace --locked --quiet`、`pnpm -r test`、`pnpm -r typecheck` 通過；這些是本機開發檢查，不能替代真機門檻。
- PR #10 的前一版 `vm-regression` 有五個 G0 夾具失敗：VM 的已登入 Core 持有預設 store 鎖，夾具只隔離 socket；修正為夾具 store 也獨立。身分測試同時更新到協定 0.2 的 JSON 輸出與握手版本；Shell 夾具載入內建套件並等啟動同步。本機重新執行 `window-matrix`、`identity-negative`、`shell-session`、`shell-restart-survival`、`hotpath` 通過；仍需 PR 新版 CI 重跑，且本機數字不是出口證據。

## 4. 下一輪驗證順序

先修 EX1-04 的 PSS 增長、補全 L-05～10 與救援／鎖定／GUI 腳本，再讓 PR 快檢與 nightly 覆蓋它們。參考機登入、第二螢幕與 D-06a 到位後執行實體情境及三次冷登入資源量測；最後累積連續五晚 nightly、非實作者簽核，逐項更新本表並舉行正式出口評審。任何未達標數字須保留原始資料與調整提案，不得自行放寬門檻。
