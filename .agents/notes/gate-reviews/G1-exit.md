# G1 出口預檢

| 欄位 | 內容 |
| --- | --- |
| 預檢日期 | 2026-10-05（前一版 2026-09-27）；**尚未進行出口評審** |
| 來源版本 | `main` `082aaf8`（PR #10 合併；CI 全綠）與其後的 `cb97f72`（參考機夾具修正，量測後進版）；G0 量測分支 `g0/ex05-sample-span` |
| 參考機 | `ditto-ref-ws-rtx4060-01`，每份結果都通過 preflight 並附指紋，`evidence_class: reference-machine` |
| 判定 | **G1 尚未出口。** 十五項的自動化部分在參考機上大多已通過；仍缺的是人工簽核與錄影、第二台實體螢幕、連續五晚 nightly、EX1-10 的預算核定，以及 G0 的 C-08／D-06a |
| 判準 | [plan/03/01 §3](../../../plan/03/01-scope-and-exit-criteria.md#3-出口門檻)、[milestones/01/04](../../../milestones/01/04-verification.md) |

本紀錄仍是逐項預檢，不是出口裁決。下表的「參考機自動化通過」是指：已進版 commit、在參考機上執行、每個自動子檢查都是 `pass`；表中另列的 `operator`／`environment` 項目未完成前，該門檻不算通過。D-37 允許 G0 出口前啟動 G1，但沒有降低任何 G0／G1 門檻。

## 1. 十五項門檻

| 門檻 | 現況與參考機證據（`artifacts/g1/`） | 尚缺 |
| --- | --- | --- |
| EX1-01 手動跨插件切換與保存 | **參考機自動化通過**：`manual-switch-2026-10-05T02:52:59Z-082a.json`，11 項 pass。七步全以合成按鍵經 Wayfire 操作組合中心與個人化設定，每步經 Core 回讀；Firefox／foot／Kate 未終止，Kate 未儲存緩衝雜湊不變，快捷鍵與命令沒有重複擁有者 | 非實作者照步驟人工執行一次並錄影（`operator`） |
| EX1-02 安裝預檢拒絕 | 參考機：`preflight-negative-2026-10-05T02:50:52Z-082a.json`，5 項 pass；PR 快檢 `rust.yml` 已在 PR #10 與 `main` 執行並通過 | ④ 每個負例在插件中心的產品文字與診斷區契約 ID（`operator`） |
| EX1-03 回復 | **參考機通過**：`rollback-2026-10-05T02:50:54Z-082a.json`，6／6。③「撤銷布局時視窗已關」已實作：合成器參與者在切換策略時記下視窗位置，撤銷時放回，已關的視窗列為 `not_restored`／`window_closed`，結果為 `partial` | —（另見 EX1-15 的 nightly 次數） |
| EX1-04 清理壓力 | **參考機通過**：`cleanup-stress-2026-10-05T02:56:35Z-cb97.json`。① Dock A／B 100 次（真實 Shell）：Shell PSS 中位數 +0.27%、Mann-Kendall p=0.72；② tasks 100 次：hostd −5.1%、p=0.074；③ realm 100 次：hostd −4.7%、p=1.0；三組首尾計數相同。hostd 的成長原因是 V8 新生代容量與兩次完整回收之間的舊代垃圾，不是洩漏；以 `hostd.node-flags`（固定 4 MiB semi-space）與卸載後一次完整 GC 修正 | ② 的 p=0.074 接近 0.05，建議出口評審前再跑兩次確認 |
| EX1-05 無 Node 救援 | **參考機通過**：`rescue-no-node-2026-10-05T02:56:56Z-cb97.json`，8／8。④ 由真實 Shell 在救援模式下顯示「待辦服務暫不可用」「通知規則暫不可用，通知會全部顯示。」，經 Shell 控制 socket 的唯讀 `services` 行讀回 | — |
| EX1-06 跨語言契約 | **參考機通過**：`contract-vectors-2026-10-05T02:50:46Z-082a.json`，11／11；`contracts.yml` 修好後（原檔案是無效 YAML，G1 期間從未執行）在 PR #10 與 `main` `082aaf8` 都通過 | — |
| EX1-07 Cordis 服務獨立存活 | **參考機通過**：`cordis-independent-2026-10-05T02:56:31Z-cb97.json`，4／4。替身終止後外部寫入 64 ms 出現在 QML 面板；通知策略照常抑制；Shell 被 `SIGKILL` 後重啟的 Shell 從快照取得期間的變化；hostd PID 三個時點相同 | 2 秒判準取自用戶端時鐘（QML 面板沒有 Core 時間戳），已在結果中註明 |
| EX1-08 L-01～L-10 | **參考機通過**：`lifecycle-2026-10-05T02:52:23Z-082a.json`，12／12；`lifecycle.yml` 在 PR #10 與 `main` 通過。L-05 不可用轉換 29～44 ms（開發機量測） | nightly 紀錄（見 EX1-15） |
| EX1-09 持久故障 | **參考機通過**：`persistence-faults-2026-10-05T02:51:03Z-082a.json`，5／5，含 80 MiB tmpfs 真實寫滿回 `storage_full`、head 與內容雜湊不變 | — |
| EX1-10 分層資源 | 工具完成（`tests/g1/measure/`）；參考機冷登入序列進行中，結果見 §6 | 三份報告；預算達標或調整提案在評審前核定；G0 的 D-06a |
| EX1-11 延遲與應用存活 | **參考機通過**：`latency-2026-10-05T02:53:33Z-082a.json`。① 200 次本機操作 accepted→readback p95 4.1 ms（Core 時鐘）；② Dock A↔B 100 次 prepared→committed p95 5 ms；Cordis 服務替換 p95 8 ms 另列；③ 300 次期間 Firefox／foot／Kate PID 不變、Kate 緩衝不變 | UI 首幀參考值未記錄；啟動器切換 30 次（plan/03/06 §6）未做 |
| EX1-12 救援、監督與鎖定 | **參考機登入工作階段自動化通過**：`rescue-supervision-2026-10-05T05:35:53Z-cb97.json` 4／4（`SIGSTOP` → 可操作救援介面 p95 7.0 s／30 次、應用與 Kate 緩衝保留、連續崩潰插件被停用、Core 重啟風暴 → 救援介面 → 離線恢復 → Core 掛上恢復的版本）；`lock-2026-10-05T05:42:34Z-cb97.json` ④⑤ 自動部分 pass | 以密碼解鎖並錄影一次（`operator`） |
| EX1-13 桌面基本面 | ⑤ 的 headless 替代版在參考機 pass（`output-hotplug-…-082a.json`，視窗與角色都回到剩餘輸出）；D-34 狀態項目可同時掛上（`status-items-…-082a.json`） | 第二台實體螢幕的 `--automated` 與 `--physical`；`desktop-basics` 腳本與人工檢查清單（中文輸入、i18n、音量／網路、快捷鍵） |
| EX1-14 來源與授權 | ① `docs/upstream/cordis-port.md` 逐套件紀錄；② `milestones/01/02 §2` 加上 G1 實作位置欄；③ **CI 實際擋下一次**：PR #11 的 `node` run 37252708548 拒絕未記錄的 vendor 修改（第一次嘗試 37247658718 沒擋下，暴露守門只比整段範圍，已改為逐 commit）；④ `licenses.yml` 在 PR #10／`main` 通過 | 授權清單的人工審查 |
| EX1-15 CI 與 nightly | ① PR 快檢（contracts、rust 含預檢負例與 store 遷移、lifecycle、node、vm-regression）在 PR #10 全綠；② nightly 已加入 EX1-01，EX1-03／07／08／09 在 `main`；③ `vm-regression.yml` 跑 G1 非圖形套件 | **連續五晚** nightly 成功（自 2026-10-05 起計）；必要檢查的分支保護設定 |

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

## 5. 2026-09-28 開發 VM 複核（非出口證據）

來源為 `2b1e99e` 加未提交工作樹；所有結果的 `evidence_class` 為 `development-vm`。VM 每次還原 `ditto-base` 快照、同步工作樹、建置後測試，結束即關機。此輪沒有改變上表任何 EX1 門檻的「未通過」結論。

| 檢查 | 結果與原始證據 | 出口限制 |
| --- | --- | --- |
| Rust／Node 工作區與協定向量 | 以 CI 同指令重跑，三組通過，協定向量 11 項通過；[摘要](../../../artifacts/g1-vm/2026-09-28T05:10:06Z-2b1e/summary.jsonl)、[VM 畫面](../../../artifacts/g1-vm/2026-09-28T05:10:06Z-2b1e/vm-test-status.png) | 工作樹未進版；不等於 L-01～L-10 或真機整合通過 |
| 預檢、回復、服務獨立性、延遲、救援 | 各套件有已通過子檢查，也各有 `operator`、`environment` 或 `not_implemented`；[完整 VM 摘要](../../../artifacts/g1-vm/2026-09-28T04:49:09Z-2b1e/summary.jsonl) 與 [逐項原始結果](../../../artifacts/g1-vm/2026-09-28T04:49:09Z-2b1e/vm-artifacts/) | 缺口仍依 §1 逐項追蹤；VM 結果不能替代實體參考機 |
| EX1-09 持久故障 | 修正啟動恢復競態及滿碟錯誤回報後，`prepared`／`applying`／`verifying` 崩潰恢復、`SQLITE_FULL`／`SQLITE_IOERR`、解壓失敗與真實 tmpfs 滿碟共 5 項通過；真滿碟回 `storage_full`，Profile head 和內容雜湊不變。[結果與原始回讀](../../../artifacts/g1-vm/2026-09-28T04:59:28Z-2b1e/vm-artifacts/) | 尚須已進版來源與參考機重跑 |
| EX1-04 清理壓力 ② | 100 次 tasks 停用／啟用後計數首尾相同，但 hostd PSS 中位數增幅 14.6%（門檻 ≤10%），Mann-Kendall p=0.001（門檻 ≥0.05）；`Pss_Anon` 16,056→29,416 KiB，`Pss_File` 25,709→22,671 KiB。[快照與判定](../../../artifacts/g1-vm/2026-09-28T05:02:33Z-2b1e/vm-artifacts/)、[VM 畫面](../../../artifacts/g1-vm/2026-09-28T05:02:33Z-2b1e/vm-test-status.png) | **未達標**。目前只能判定成長主要在匿名記憶體；不能據此指定 V8、allocator 或物件殘留為原因。Dock、realm、Shell PSS 與真機數列亦未完成 |

滿碟失敗最初是 `run_proposal` 在草稿寫入前的錯誤被誤報為 `timeout/unknown`；修正後實際滿碟回讀已通過。hostd 終態交易紀錄保留舊 fiber 參照的問題也已修正，但同條件 VM 重跑 PSS 仍未達標（14.9%）；因此不得把該修正宣稱為 EX1-04 的解決。下一步須針對匿名記憶體與 V8 heap／原生配置做分離診斷，再在參考機按原門檻重測。

`vm-regression.yml` 已加上 Rust／Node 工作區及契約向量的 VM PR 快檢，但修改尚未進版，也沒有 CI 執行紀錄，EX1-15 仍未通過。參考機使用凍結工具鏈的 preflight 可通過；檢查時 seat0 停在 GDM，沒有可用的 Ditto 登入工作階段，故本輪未對使用者工作階段執行 Shell、鎖定、雙螢幕或實體資源量測。

## 6. EX1-10 分層資源（參考機，2026-10-05）

（序列完成後填入：四組狀態各三次冷登入的報告路徑與數字。）

## 7. 2026-10-04～05 這一輪找到並修正的產品缺陷

每項都由上表的腳本在真實程序上發現，修正後同一腳本重跑通過；細節在各 commit 訊息。

| 範圍 | 缺陷 | 修正 |
| --- | --- | --- |
| Shell | 換 Dock 時新 Dock 以 on-demand 鍵盤互動映射，搶走使用中視窗的鍵盤焦點 | 面板與 Dock 先以無鍵盤互動映射，映射後才改 on-demand |
| Shell | 匯入文字區困住 Tab；按下「套用」等會消失的按鈕後焦點遺失 | Tab 離開文字區；焦點移到最近的前一個控制項 |
| Core | 保留快捷鍵（救援、鎖定）從未綁定到合成器；開機綁定失敗後，每個合成器變更都因快捷鍵回讀不符而回復 | 保留鍵與 Profile 一起綁定；合成器表格與已提交不一致時重新綁定 |
| Core／Shell | 監督者終止卡住的 Shell 後，Shell 在同一次登入中再也起不來（`Conflicts=` 讓死掉的 transient scope 保持載入）；救援介面無法回到一般桌面，也連不上 Core | 新能力 `desktop.rescue.resume_shell`（目錄 revision 4）；救援 unit 改以 `ExecStartPre` 停 Shell；Core 執行中時由 Core 啟動已連線的救援介面 |
| Core | hostd 在 prepare 後死亡仍往死連線 commit；回復時讀回送到舊連線；呼叫方在受理前離線仍執行提案；舊 hostd 連線在新連線前仍可送心跳 | 見 L-05～L-10 的修正 commit |
| Core | 合成器事件串流在突發下被 Wayfire 斷線；`--launch` 的子程序成為殭屍 | 獨立讀取執行緒並合併重讀；回收子程序 |
| hostd | PSS 隨啟用／停用往返成長 | 固定新生代大小，卸載後一次完整 GC |
| Profile／Shell | D-34 的 5 個 QML 狀態項目宣告的 `ui.status_item` 不存在，啟用後什麼都沒掛上 | 多條目區域 `ui.status_item`，掛在頂部面板的狀態區（無面板時用 Shell 自己的狀態列） |
| CI | `contracts.yml` 是無效 YAML，G1 期間從未執行；vendor 守門只比整段範圍；lifecycle 在 CI 讀不到 Vitest 數字 | 修正 YAML；逐 commit 判定；改讀 JSON 報告 |
| 量測 | G0 EX-05 的取樣只跨 595 秒；G0 工作階段範本寫死主倉庫路徑 | 多取一點；範本改用安裝時替換的路徑（`g0/ex05-sample-span`） |

已知未解：內建套件內容改變但版本號不變時，已有舊版本的 store 會拒絕重新安裝，工作階段因而執行舊的供應者。參考機量測前已把舊 store 移到 `~/.local/share/ditto.before-ref-2026-10-05`（保留未刪）。正式做法應是內容變更必須升版並由 CI 檢查，尚未實作。
