# G3 階段收尾與出口評審資料

| 欄位 | 內容 |
| --- | --- |
| 日期／狀態 | 2026-10-17；**owner 依 D-47 接受開發 VM 證據，G3 出口通過** |
| 計畫／追蹤 | [plan/05](../../../plan/05/README.md)；[#34](https://github.com/relvo-labs/Ditto/issues/34)，相關 #15～#33 與 G2 follow-up #35～#39 已逐項閱讀 |
| PR | [#40：受限生成、隔離驗證與版本回退](https://github.com/relvo-labs/Ditto/pull/40) |
| 分支 | `codex/g3-restricted-generation`；整合實作 `5ed55b8c44d94bae6e3dd70841c7961b85b25eb2`；G2 PR #13 已合併，本次 PR 以 `main` 為基底 |
| G2 交接 | owner 依 [D-46](../decisions/2026-10-13-d46-g2-functional-acceptance-and-g3-integration.md) 接受功能完成；PR #13 已提供 G2 參考機量測，D-44 後端寬鬆上限已為 1G；剩餘 #35～#39 保留 |
| 歷史 | 獨立基礎設施 `d77b4e7`、證據 `27abec9`；先前未接線的狀態保留於 [歷史快照](G3-foundation-2026-10-13.md) |
| 評審者 | owner；本紀錄提供事實與缺口，不代替 owner 裁定 |

2026-10-14 後續：已修正 CI checkout 證據權限與無進展修復預算，補齊 enforcement 共用向量；使用者明確授權後，真實訂閱模型四回合及實際面板／按鈕／清理回讀 **15 項通過**。詳見 [後續評審](G3-followup-2026-10-14.md) 與 [證據摘要](G3-followup-evidence-2026-10-14.json)。本機修正尚未推送，實體座位與 owner 出口仍待驗。下方 §3.1～3.3 保留首次 PR 交付時的歷史證據與拒絕結果，不代表後續真模型仍未執行。

同日再次功能盤點：實作 `9e6e37d` 修正實際 artifact 升版回讀、序列化接受點撤權檢查及管理中心工作恢復／進度／雙預覽取消。新增 Core 失敗補償、真 native 七負例、三態九格信任矩陣與兩次修改回第一版；最終完整 VM **14 步通過**，管理中心 QtTest **6 項**，新 Core 真模型 **19 項通過**。詳見 [功能補齊紀錄](G3-functional-completion-2026-10-14.md) 及其 evidence JSON；前段 15 項與未推送敘述保留其時間點，出口仍未由 owner 裁定。

最新進度：使用者明確授權中斷實體測試登入後，已完成[實體座位驗收](G3-reference-seat-2026-10-14.md)及其[原始證據索引](G3-reference-seat-evidence-2026-10-14.json)。真訂閱 **19 項**、桌面 **45 項**、固定 Qt **7 案例**、OS 故障 **10 項**、三態九格信任矩陣與雙預覽實際鍵盤取消通過。實作 `bcc7264` 修正實際逾時誤報及失敗工作文案；本機 Rust **258 項**、Node **184 項**、Qt **13 項**。下表更新為目前證據狀態，§3 的首次交付歷史仍保留，不代替 owner 裁定。

## 2026-10-17 當前裁定

owner 依 [D-47](../decisions/2026-10-17-d47-g3-exit-vm-evidence.md) 接受 `17f5d76` 的開發 VM 證據（15 步 pass、exit 0），G3 出口通過；PR #40 合併為 `main@39da297`。此次 VM 沒有涵蓋的真模型訂閱登入、實體座位重新登入、參考機量測由 [#44](https://github.com/relvo-labs/Ditto/issues/44) 與 [plan/06](../../../plan/06/README.md) 承接。D-17 也已[補錄](../decisions/2026-10-14-d17-g3-generated-plugin-selection.md)。以下逐項表格與「待 owner」敘述保留 2026-10-14 的原始時間點，當前裁定以本節為準。

## 1. 五項出口

| 原出口門檻 | 本次結果 | 證據與剩餘驗收 |
| --- | --- | --- |
| AT-06：生成待辦摘要與快捷動作面板，有新產物、驗證與預覽，可啟用並繼續修改 | **實體真模型驗收證據通過，待 owner 裁定** | physical-03：真訂閱四回合 19 項，新 artifact、五關、真預覽、啟用、修改、未要求欄位保留、實際面板／服務／工作區按鈕與恢復回讀 |
| AT-07：無效 QML／逾時／非法 imports 不進主 Shell；顯示失敗且桌面可用 | **實體負例與可見失敗證據通過，待 owner 裁定** | final-faults-01：25 項，三種真故障、關卡與後續未執行、禁止發布、主 Shell／hostd／Core／合成器／原生應用同 PID／starttime，revision 不變；真管理中心失敗／下一步與鍵盤診斷入口 |
| AT-18：三類固定上游能力運行，功能、來源、相容性與修改均可追溯 | **文件與實際運行齊備，待 owner 文件審查** | [九欄／四欄沿用矩陣](../../../docs/upstream/g3-adoption.md)、9 檔 hash、vendor guard、模型／工具／會話及真實 app-server 多輪；vendored source 修改 0 |
| AT-22：新插件資料 schema 升級後回退，依快照／相容政策回復 | **實體資料／外觀回讀證據通過，待 owner 裁定** | physical-03 及 final-desktop-01 各 45 項：連續兩次修改回第一版、快照、相容保留新值、不可逆拒絕、舊版不可誤讀與移除保留資料；另有 Core 提交失敗／損壞快照補償回歸 |
| 生成插件在隔離宿主中受檔案／網路／程序與時間邊界限制；無法執行時降為可檢視候選 | **實體 OS／三態證據通過，待 owner 裁定** | 實際 generated-templates-v1 配額、Landlock／seccomp／整組清理、OS 十探針桌面存活；真缺 Qt 允許目錄 partial、真缺 native helper unavailable，均禁止發布；三態九格未信任 archive 封鎖 |

AT-26：兩個生成工作、第三個排隊、排隊取消、雙預覽鍵盤取消與 OS 超限桌面存活已有實體證據；Core 崩潰後回收舊 scope／禁止重播／恢復接單另有 VM／headless 證據。AT-29 的三態九格 archive 矩陣已完成實體驗收；舊 ABI 負例保留 VM 分類。以上均非 PSS／呈現時間達標量測。

## 2. 交付與相關 issue

| issue | 本次可審查交付 | 尚待完成 |
| --- | --- | --- |
| #15 | plan/05、G2 交接快照、D-45／D-46、依賴與估算提案 | 估算與待決策項由 owner 核定；歷史表格不回填為量測通過 |
| #16／17／18 | 獨立 native 宿主、512 MiB／0 swap／1 CPU／64 tasks、實際 enforcement／原因、deadline、OOM／取消／清理、Core 重啟對帳；實體故障與桌面見證通過 | owner 審查；資源 p95 不由故障測試推定 |
| #19 | Rust-first 9 個 development 能力，Definition／Core Provider／Agent 與 CLI Consumer、動態 schema／共用向量／授權拒絕及序列化接受點撤權測試；真 app-server 一次性 approval | owner 審查；G2 既有授權矩陣保留其證據分類 |
| #20 | 內容地址完整 bundle、來源最小化、父版本、驗證／預覽／啟用歷程、Store v4 與舊保留表遷移、對話刪除遮蔽來源 | 備份／匯出等跨功能隱私驗收；遮蔽不等於磁碟鑑識抹除 |
| #21 | 資料 CAS、schema／版本檢查、快照／相容／不可回退政策、與 Profile 原子提交及桌面 undo；實體 45 項回退／版本／資料確認通過 | owner 審查 |
| #22／23 | 有界宣告式 DSL、兩個可信固定模板、純文字與封閉 imports、限定資料／工作區代理、原生 syscall 與檔案／網路邊界 | D-17 兩類選型裁定；自由 QML／JS／native 仍不開放 |
| #24／25 | 五關、獨立預覽、phase、ChangeSet、load／health／readback／資料提交失敗補償；實體逐關／可見預覽／雙預覽鍵盤操作通過 | owner 審查；首幀指標依原量測追蹤 |
| #26／27 | 三輪／同錯／無進展停止、防跨連線繞過、明確新回合重開、版本差異及冪等；實體連續兩次修改回第一版通過 | owner 審查；不以模型說詞代替持久預算 |
| #28 | 實體真訂閱兩類生成與各自再修改 **19 項通過**，服務、按鈕、未要求欄位與清理均回讀 | owner 審查 |
| #29 | 三類能力來源、信任、授權、修改、host contract、測試及四欄沿用矩陣 | owner 文件審查；G4 shipping 授權另做 |
| #30／31／32 | 實體故障／可見失敗／下一步、工作池、十項 OS 超限存活、三態九格信任矩陣通過；全部失敗保留 | owner 審查 |
| #33 | 本次階段收尾、可重跑命令、證據摘要、已知限制與 G4 交接 | owner 最終出口評審 |

## 3. 驗證與可追溯性

命令與前置條件見 [tests/g3/README](../../../tests/g3/README.md)。原始 artifacts 保存在本 checkout 的 `artifacts/g3/`、`artifacts/g3-vm/`（gitignored）；提交中的 [證據摘要](G3-evidence-2026-10-14.json) 保存實際結果、原始檔 SHA256、來源指紋及 PID／cgroup，其他 checkout 可依命令重跑，不能把本機摘要當成另一台機器的量測。

### 3.1 開發機回歸

- `cargo test --locked --workspace`：**247 項通過，0 失敗**；全 workspace format 與 clippy `--all-targets -- -D warnings` 通過。
- `pnpm typecheck`、`pnpm test`：型別檢查及 **184 項 Node 測試通過**。
- Rust schema export `--check`、TS `check:generated`、可信模板同步 `--check`、共享契約向量通過。
- QML lint 與 QtTest **5 項通過**（3 個行為測試及 init／cleanup）；native runner 用固定 Qt 6.10.2 建置。
- Shell i18n：553 個字串、181 個 Core keys、2 個語言通過。skills lint：0 error、1 個既有 AGENTS.md 長度警訊。
- 上游 9 檔 hash 與 vendor guard 通過，vendored source 修改 0；diff check 通過。
- GitHub Actions 於 PR 建立後另查；本機成功不推定遠端 runner 已通過。

### 3.2 開發 VM 與真桌面測試

首輪整合的兩次 run 都來自乾淨實作 commit `5ed55b8`，來源樹 SHA256 `5070d72a2a84943f6b7410c4ad39a643176485df7acea658a44dea5b4d127f23`。後續合併 `main@603018a`，保留 G2 後端 1G 寬鬆限制與量測更新；G3 執行程式沒有變更，合併後整合回歸另附於證據摘要。

| run | 實際結果 |
| --- | --- |
| `artifacts/g3-vm/2026-10-13T17-46-09Z-5ed55b8` | 12 個 runner 步驟全部通過；Core 整合 25、桌面 25、重啟 8、腳本模型 15、OS 探針 10 項通過；QtTest 5 項通過 |
| `artifacts/g3-vm/2026-10-13T17-48-07Z-5ed55b8` | 建置／模板／拒絕／正式 Core partial 15 項通過；候選執行刻意 `not_run`，runner 退出 2；未發生測試失敗 |
| `artifacts/g3-vm/2026-10-13T17-54-14Z-ba0ae87` | 合併 main 後的乾淨 commit；12 個步驟全部通過，Core 25／桌面 25／重啟 8／腳本模型 15／OS 10／QtTest 5 項通過 |

合併後實作 commit `ba0ae871655e68aca7f13f48759a755d070f274e`，來源樹 SHA256 `c9b25955adbadc1b06ecf35d418131061558ccc8a439235861796e08093b82f1`；最後證據提交只改文件。原始檔路徑、個別檢查、來源 SHA256 與邊界回讀見 [證據摘要](G3-evidence-2026-10-14.json)。VM 為可拋棄 `ditto-g0-vm`，只還原 shut-off 快照；沒有登出或重啟使用者目前的實體桌面。

- `ditto-g2` 快照：7.0.0-38-generic、Landlock ABI 8。診斷十項 files／network／signals／spawn／spoof／memory／busy／timeout／orphan／cancel 逐項檢查實際邊界與 cgroup 清空；512 MiB、0 swap、100000/100000 CPU quota、64 tasks。這是故障證據，不是 PSS 或效能達標量測。
- 生產 Core 整合：兩類模板原生五關、發布、缺 Shell 安全中止、相同啟用重試與不同目標衝突、不可信入口與未授權 jobs.submit 拒絕。
- headless Wayfire 桌面：真待辦資料、隔離預覽、兩槽／第三項排隊／取消、schema 升版／undo 舊資料實讀、兩面板共存、實際指標點擊切換工作區、啟用 journal、原生應用存活。
- Core crash：兩個真預覽期間只終止 fixture Core，重啟後工作標 interrupted 不重播；舊 worker／native cgroup 清空後才允許新工作，preview opened 歷程與 Profile revision 保留，合成器存活。
- 釘選 Codex app-server + loopback 腳本模型：實際動態工具與共用授權、兩類各自生成／預覽／啟用／修改、來源綁定真正 turn、刪會話遮蔽來源、Agent 退出後面板保留。沒有外部模型、帳號或憑證複製，不計語意分數。
- `ditto-base` 快照：6.8 核心、Landlock ABI 4。診斷及正式 Core 回報 partial，沒有候選執行／發布；完整執行標 `not_run`，整體退出 2 是預期拒絕結果。

先前失敗 run 全部保留，未以重跑刪除：套件未建置／相對輸出路徑、VM 缺依賴與 Codex binary、transient unit 終止原因遭回收，診斷備援計時器搶先 systemd deadline，以及 VM 停止的 scope 仍保留 unit 但沒有 ControlGroup。本批分別修正建置前置、釘選 binary 傳送、ExecStopPost 保存原因、備援 watchdog 順序、停止前保存 cgroup 並確實清理及跨重啟追查未確認項；systemd 的正式 deadline／資源硬上限沒有放寬。

### 3.3 首次交付時未執行與自動核准結果（歷史）

**G3 真實訂閱模型測試未執行。** 自動核准審查拒絕以既有 keyring 登入執行真實模型回合，理由是該動作會向外部模型傳送測試／可能的工作區脈絡，並涉及既有帳戶及設定副作用，而原實作授權未明確涵蓋該外部披露。被拒的命令未執行；沒有改走其他外部模型迴避。

已準備 `tests/g3/agent/real.sh` 與四回合自然語言 oracle，僅做靜態語法檢查；須取得明確授權後，以指定私有開發測試 store 執行。真實訂閱與參考機流程未跑，不影響提交目前可審查實作，但不能宣告 AT-06／G3 出口完成。

實體座位逐關故障、中文鍵盤、雙螢幕、冷登入三次四態 PSS／CPU、呈現時間、100 次啟停與五晚 nightly 均未由本批重新驗收。G2 參考機暖態 Agent p95 88.6～89.2 MiB 的原始證據見 G2-exit §3.6；VM 超過 150 MiB 的差異與 D-44 由 #35 追蹤，後端已採 1G 寬鬆上限。這些 G2 數字不作 G3 資源驗收；D-06a 與 D-38 其他缺口繼續追蹤，沒有移除程序或提高門檻。

## 4. 已知限制與 G4 交接

1. 執行內容限兩個可信固定模板；描述資料不插值成程式碼。既有 QML provider、Node、native 套件不能僅自稱 generated 取得信任。自由生成與通用遷移腳本不在此次能力中。
2. 每個工作有 worker scope 與 native service，資源盤點須兩者都計入；512 MiB 是單一隔離宿主硬上限，不能寫成全部活動工作或完整桌面的實測成本。沒有新增常駐生成服務。
3. bundle 包含固定模板 hash；模板更新後，舊 validation 的相容性與重驗證必須另外處理，不能把舊證據套到新程式。管理中心目前呈現最近十筆產物，完整歷程仍由 Core 查詢。
4. 來源刪除是權威紀錄的邏輯遮蔽；備份、已匯出內容與磁碟抹除不由此保證。資料與描述不可放憑證，沿用秘密引用及同一授權路徑。
5. G4 納入新 Qt6Test 執行期依賴、Qt 版本／來源／授權文本與重新連結義務；專案目前 UNLICENSED，Codex 再散布、名稱／角色素材與所有 shipping 權利仍待完整審查。
6. 實體參考座位 AT-06／07／22／26／29 證據已補齊，下一步為 owner 審查 AT-18、D-17 與五出口。G4 承接安裝／發行、桌面基本面、中文／雙螢幕、nightly、資源／幀時及 D-38／D-46 未完項。64 人週仍是未核定規劃，不把 Agent 執行時間換算人週，也不在缺少參考機數據時承諾新的工期。

## 獨立審查與修正（2026-10-14）

Claude Opus 5.5（原生模型已驗證；High 為請求值，未有原生 applied effort 證據）對 `d49387f94cea3f37207224463895be1b4e95d8ec` 的唯讀審查結論為 **FAIL**：Class A（AT-22／#21）多跳回退未檢查中間不可逆政策及快照實際分支；Class B（GEN-08／#26）預建候選可繞過只在 create 檢查的回合停止。既有實體與開發證據未覆蓋這兩個反例，不能據此宣告阻擋項已通過。

本次以既有快照表保存實際資料鏈，逐跳核對回退政策、artifact 端點與 schema；不可證明時預檢拒絕。回退提交移除退出鏈結，相容保留目前值，快照依原政策回復該跳升版前資料。新增九格政策、過期兄弟快照、兩跳快照及損壞／缺失鏈結回歸。create／validate 共用序列化回合預算，入列／validating 先占額度，初始生成加三輪修復；新增預建候選與停止後拒絕入列、預覽與新回合回歸。Shell 投影另拒絕非完整或未核可 generated 套件，無 `file://` 退路，新增純投影測試。

本 runner 離線 fmt、workspace clippy 通過；生成 Store 9、Core generation 單元 4、純投影 1 項通過。指定 `cargo test --locked --workspace` 17 通過、2 失敗，停在 sandbox 限制的 confine socket／D-Bus 測試；補跑 `--no-fail-fast` 214 通過、52 失敗（4 targets），包含 Core RPC handshake `Operation not permitted`、supervisor socket 與 notifications D-Bus 環境失敗。既有兩次修改回第一版測試未改，與新 Core 多跳拒絕測試同遭 RPC 環境阻擋。命令／log／範圍詳見 [完成盤點](../../../plan/05/07-completion-audit.md#獨立審查與修正2026-10-14)。

**Writer 結束時 BLOCKED：完整 workspace gate 與依 gates 通過條件的本地提交。** 修正尚在工作樹，提交後的新 HEAD 仍須 fresh delta review；本節不裁定 Ready 或 owner 出口。救援與資料政策語意、其他非阻擋追蹤項未改，未重跑 VM／實體座位／Node／Qt，未改 wire／TS／QML／證據 JSON。

後續 coordinator 套用本段 patch 並解除執行環境阻擋：同一修正內容在本機重跑 fmt、workspace clippy（0 warning）及 `cargo test --locked --workspace --no-fail-fast`，**266 通過、0 失敗**；新 Core 拒絕旅程與原兩次修改回第一版皆通過。Node 22.23.2／pnpm 10.11.0 的 workspace build／typecheck 通過，**184 測試通過、2 個既有 skip**。runner 原失敗與 Node 缺 Core 二進位的前置失敗保留，詳見完成盤點；不冒充本機 Qt／VM／實體重驗，修正 head 仍待 fresh delta review。救援語意由 [#41](https://github.com/relvo-labs/Ditto/issues/41) 追蹤。

## 第二輪獨立審查與修正（2026-10-14）

獨立 reviewer 對 `618f62cb100709b6f9cfa5a7bcf4cae6d19ace18` 結論仍為 **FAIL**。Neil 明確授權「採用 A 方案，並一起修 B」，來源 `/data/hermes/ditto-runs/g3-pr40/repair2/authority.md`（#34 comment 6167219232）。原 FAIL 與第一輪實際證據保留；C 已關閉，#41 救援語意不在本輪範圍。

A：Store v4→v5 將全部歷史快照保留並標為 unproven，不能根據端點／schema／rowid 補證明。只有與資料所有者及 Profile 同筆原子提交的新邊為 proved，回退每跳都須證明；最新未知邊不能跳過取更舊快照。真 v4 備份／payload bytes 保留、新同 schema 切換、九格政策、兩快照旅程、混合新舊鏈、缺失／無效 proof 與 commit 失敗無副作用均有測試。舊 build 不開啟 v5；跨未知 v4 歷史的回退拒絕，現役資料及 Profile 不被遷移改寫。

B：每筆非冪等 validate job 持久占額度，取消／中斷／inspect_only 重驗不抹除舊工作。只有該筆 succeeded 且 full／hash 相符報告釋放自身，先前失敗保留；preview／same-key replay 免扣，多個成功插件及明確新 turn 可通行。同錯讀個別工作歷史，原 stopped／no-progress 保留。私人 turn 識別留在 Core，worker 傳給 native host 的封閉 input 維持 artifact／work_root。

兩個最新反例 `v4_abandoned_snapshot_is_unproven_after_migration`、`revalidation_cancel_and_restart_cannot_enqueue_a_fifth_build` 在 618f62c production 上均可編譯，實際 RED（各 0 通過、1 失敗、exit 101），修正後 GREEN。A 真 v4 journey 及 B 正式 enqueue／finish／cancel／restart reconcile 不是純記憶體推算；RED logs／diff 保留。全狀態／決策表、具名 row→regression witnesses、呼叫路徑與命令見 [完成盤點](../../../plan/05/07-completion-audit.md#第二輪獨立審查與修正2026-10-14)。

本輪指定離線 Rust 環境：fmt／workspace clippy exit 0（0 warning）；Store 51、Core generation 8、worker 1、純投影 1 項通過，全部 0 失敗／exit 0。Unix socket preflight exit 1／Operation not permitted，故完整 workspace 與 Core RPC **BLOCKED**，依指示未重跑失敗 suites，交由 coordinator。原 Core 兩次修改回第一版測試原碼未改，其本輪 RPC 執行仍待補驗。Logs 位於 `/data/hermes/ditto-runs/g3-pr40/repair2/gates/`，中間測試 fixture 結算失敗也保留。

本輪授權允許 focused gates 通過即建立 `[skip ci]` 本地 checkpoint，無 push／PR／merge 操作。Node／Qt／VM／實體流程未執行，RPC／TS／QML／native input 型別與證據 JSON 未改，不以單元數字代替原生隔離或 owner 驗收。新 HEAD 仍需 fresh delta review；保持未裁定 Ready／G3 出口。

Coordinator 已推送實作 `45a4eba`（checkpoint 略過 CI），套用本段 patch 並完成本機十二關：Rust workspace **277 通過、0 失敗**（含原兩次修改回第一版的 RPC）、workspace build／fmt／clippy、Rust schema／TS generated／模板同步、Node workspace build／typecheck 與 **184 通過、2 個既有 skip**、skills／i18n lint 全部 exit 0；skills 保留一個既有主文件長度警訊。來源 hash 在各 gate 前後一致，原 writer socket 阻擋記錄保留；新 head 的 Qt／VM／實體驗收未由此推定，獨立差異審查仍待完成。
