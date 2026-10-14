# G3 實作與完成缺口盤點

2026-10-14 對照 GitHub #34、PR #40、全部 #15～#33、PRD 與 plan/05 的實作盤點。這是完成工作的追蹤文件，**不是 G3 出口通過宣告**；出口裁定仍由 owner 依 [G3-exit](../../.agents/notes/gate-reviews/G3-exit.md) 進行。

## 實作範圍

Core 持有生成紀錄、修復預算、配置 revision 與插件資料；Agent 經正式能力提出候選，Shell 只解讀兩個固定模板的受限描述。生成驗證／預覽按工作啟動，不新增常駐生成服務。開發機與 VM 證據不能替代實體座位及真實模型驗收。

最新：使用者已明確授權並完成[實體座位驗收](../../.agents/notes/gate-reviews/G3-reference-seat-2026-10-14.md)。實作 `bcc7264` 亦修正實測揭露的逾時關卡遺失及失敗文案；下表以目前證據更新。#15～#33 的功能／文件交付已有可定位實作與相應驗證，正式出口、D-17 選型及估算由 owner 裁定，不以 issue 尚未關閉推定功能未實作，也不代替 owner 自動關閉。

| issue | 可定位的實作／驗證 | 剩餘工作 |
| --- | --- | --- |
| #15 | plan/05 六份原計畫、D-45／46、十九項 G2 交接快照；本次更正 PR #13 與 RPC 的過時現況 | owner 核定估算及待決策項；不回填歷史量測 |
| #16 | `crates/ditto-test-host`、`tools/generation-host`、`tests/g3/host`：獨立 service、Landlock／seccomp、配額回讀與 deadline；實體十項 OS 探針及逐項桌面／應用存活通過 | owner 審查；不以故障配額推定資源 p95 |
| #17 | `ditto-protocol/src/generation.rs`、Core 發布閘門、四種 enforcement 共用向量；實體 full／真缺 Qt 允許目錄 partial／真缺 helper unavailable 通過 | owner 審查；未知值仍拒絕 |
| #18 | cgroup 整組終止、超限診斷、重啟不重播與回收；實體 OOM／busy／fork／timeout／取消均保留桌面 PID／starttime／revision | owner 審查 |
| #19 | Rust-first seam／共用向量拒絕未知與額外欄位、授權拒絕；coordinator 接受點重查撤權／鎖定；真 app-server 一次性 approval 無永久 data grant；實體真模型正式能力運作 | owner 審查；G2 19 項正式 Shell 授權回歸保持原證據分類 |
| #20 | Store v4、完整內容地址 bundle、不可變父版本、來源刪除遮蔽與啟用失敗歷程，Core 可查 | 功能已有開發證據；歷史備份／已匯出內容不承諾抹除，沿用隱私限制，不作完成承諾 |
| #21 | schema／資料 CAS；實體 45 項確認快照、相容保留新值、不可逆拒絕及舊版不可讀不相容資料；Core 提交失敗／損壞快照補償 | owner 審查 |
| #22 | 兩個受限模板、SDK、QtTest、固定 Shell 解譯器 | D-17 選型裁定；不能以模板測試代替 AT-06 |
| #23 | 封閉描述、固定 imports、檔案白名單、禁網路／子程序與 Core 代理；實體五關／OS 十探針及三態九格負例通過 | owner 審查 |
| #24 | 五關實測時間與中斷保存、實體可見 Wayland 預覽／測試資料標示、各關負例、管理中心雙預覽實際 Tab／Enter 取消且 Core 回讀 | owner 審查；合成輸入不算人工中文證據 |
| #25 | 實際 artifact id 必須吻合；Core 真交易注入 load／health／readback 及資料 commit 失敗，均回舊面板／revision／資料且候選失敗／診斷保留；實體版本及資料回復通過 | owner 審查；故障交易的 fake Shell／測試報告不冒充 OS 或實體負例 |
| #26 | 持久三輪／同錯／無進展停止、跨連線及同回合分支／換插件 ID 防繞過；無第四個工作／診斷保留，腳本模型管線使用同一 Core 閘門 | owner 審查；不以模型自述判定預算 |
| #27 | 不可變新版本／changed_fields；實體連續兩次修改回第一版的外觀與資料，真模型未要求欄位保留通過 | owner 審查 |
| #28 | **實體真實訂閱四回合 19 項通過**：新插件、要求符合／範圍保留、實際面板／服務／按鈕、清理回讀；原始產物保留 | owner 審查；先前 provider_unavailable 失敗保留，不隱藏重試 |
| #29 | `docs/upstream/g3-adoption.md` 九欄／四欄矩陣、hash／vendor guard、模型／工具／會話執行 | owner 文件審查；G4 shipping 授權另做 |
| #30 | 實體無效 QML／非法 import／timeout、真管理中心失敗／下一步／後續未執行、Shell／hostd／Core／合成器／應用同 PID；修正逾時誤報 | owner 審查 |
| #31 | 實體 OS 十探針、兩槽／第三工作排隊、取消、revision 保留；VM 重啟回收另列 | owner 審查 |
| #32 | **實體三態九格負例通過**：每輪全新 QML／Node／ELF archive；Core 拒絕／revision／執行見證；舊 ABI／缺 bus VM 矩陣保留 | owner 審查；不偽造 full |
| #33 | G3-exit、原始證據摘要、重跑命令與 G4 交接 | owner 逐項裁定五出口；不自動關閉追蹤 issues |

## 本次修正

1. PR #40 多項 CI 在 checkout 階段失敗：VM 收回的套件目錄保留了 `0500`，下一 job 無法刪除證據副本。共用 `vm_collect_artifacts` 只增加接收副本的 owner 權限，不修改 guest 套件、內容或時間戳；G0～G3 證據收集均使用此入口。新增可重現 `0500／0400` 來源、內容比對與 checkout 刪除的回歸測試。
2. 非 VM Core 整合也保留唯讀測試 store；測試程序停止後恢復該私有 fixture 的 owner 寫入權限，原始證據保留。測試進行中仍採正式唯讀套件政策。
3. 原修復預算只檢查三輪與重複錯誤。現在比較持久父版本報告的連續通過關卡；無進展或退步即停止，缺報告不算進展。同回合任何已停止的預算會擋下改接舊父版本或新插件 ID；明確的新使用者回合可另啟預算。Agent 工具說明同步。
4. 共用契約向量加入 `full／partial／unavailable` 與未知值拒絕；可解碼 `partial` 不代表可發布。VM workflow 加入 `tests/g3/**` 觸發，G3 快檢加入共用 VM 工具觸發。
5. 原生五關在實際開始時回報 phase，結束時保存起訖與單調耗時；使用既有診斷欄位，不改 wire shape，不讓時間變動影響重複錯誤判斷。兩類模板的原生整合測試都逐關檢查時間資料。
6. Shell 新增選用 mount.artifact_id，讀實際掛載物件而不是 requested projection；Core 升版與 plugins.list 皆核對該 id。舊 entry id 相同不再誤報成功，缺版本證據會失敗補償。相容性與共用向量見 `docs/contracts/agent-0.3.md` §5。
7. 生成寫入／啟用在序列化接受點重查授權，保留 Core 已消耗的單次 approval receipt；真 app-server 驗證確實可以一次性啟用，且不新增永久資料授權。
8. 補上五個 Core 交易測試、原生七案例、三態九格信任矩陣、桌面 45 項與腳本模型 17 項；新 Core 真模型 19 項通過。管理中心另有 6 項 QtTest，涵蓋晚到快照、外部新工作、重開及雙預覽鍵盤取消。
9. 實體故障揭露 native 逾時遺失關卡；修正實測 exec／fork attestation 與有序關卡的持續保存，缺最終 completion 不能發布，三種真 Core 負例另接 CI／VM。管理中心依驗證結果顯示失敗／inspect_only，避免已結束的 job 誤稱驗證成功；QtTest 增至 8 項，兩組共 13 項。
10. 授權後實體真模型 19、桌面 45、native 7 案例、OS 十探針、三態九格矩陣及雙預覽鍵盤取消通過；每輪恢復正常登入／原配置／GDM／CI runner 並回讀。先前失敗與測試環境問題全部保留。

## 完成順序與驗證入口

1. 本機快檢：`bash tests/g3/run.sh`、`cargo test --locked --workspace`、workspace clippy／fmt、`pnpm typecheck`／`pnpm test`、schema／TS 新鮮度及 skills lint。
2. 可拋棄 VM：`bash tools/dev-vm/run-g3.sh`；再用 README 的舊 ABI 命令確認 `partial`、不執行候選及退出 2。來源樹含未提交改動時記 dirty 與 hash，不能把 HEAD 當成完整實作指紋。
3. 真模型：本次已取得既有訂閱／外部傳送的明確授權，執行 `tests/g3/agent/real.sh`，保留四回合 artifact、模型選擇、工具 trace、實際互動與清理回讀。後續執行仍需相應授權；腳本模型不計語意品質，headless 真模型也不冒充實體座位。
4. 參考機：按 `04-verification-and-measurement.md` 重跑 AT-06／07／22／26／29，記錄顯示、PID／cgroup、revision、失敗卡片與回讀。資源另依冷登入三次四態方法採樣，不在目前使用中的桌面偷偷登出或做超限測試。
5. owner 審查 AT-18、D-17 與五項出口，將裁定回寫 G3-exit。G4 承接發行授權、中文／雙螢幕、nightly 與 D-38／46 既有項，不提高原門檻。

首次驗證結果與來源指紋見 [後續證據](../../.agents/notes/gate-reviews/G3-followup-2026-10-14.md)。後續實作提交 `9e6e37d` 與證據更新到 PR #40；GitHub 舊 HEAD 的 check 失敗與當前版本分開記錄，本機通過不能寫成遠端 CI 已通過。

使用者追問「每個 issue 都做完了嗎」後的功能補齊與最新證據見 [功能補齊紀錄](../../.agents/notes/gate-reviews/G3-functional-completion-2026-10-14.md)。GitHub #15～#34 仍全部開啟；實作完成、開發驗證、實體驗收與 owner 關閉分別記錄，不以文件勾選代替功能或出口。

PR 更新後另修正 [CI 長 checkout 路徑與早期報告](../../.agents/notes/gate-reviews/G3-ci-followup-2026-10-14.md)，管理中心快照亂序保護增至 7 項 QtTest。CI 實際結果分開記錄，不以先前本機成功推定遠端已通過。

以上完成順序保留重跑入口；第 4 步的功能矩陣現已執行，詳見[實體驗收與最後修正](../../.agents/notes/gate-reviews/G3-reference-seat-2026-10-14.md)。未執行的資源／人工／G4 項保持原追蹤；GitHub #15～#34 的關閉與五出口由 owner 依新證據裁定。

## 獨立審查與修正（2026-10-14）

Claude Opus 5.5（原生模型已驗證；High 為請求值，未有原生 applied effort 證據）對 `d49387f94cea3f37207224463895be1b4e95d8ec` 的唯讀審查結論為 **FAIL**。Class A（AT-22／#21）只檢查目前所有者的回退政策，可能跨過不可逆中間版本或重用兄弟版本的舊快照；Class B（GEN-08／#26）只在 create 檢查回合預算，預先建立的候選可在停止後繼續 validate。先前證據未涵蓋這兩個反例，歷史紀錄保持原樣。

本次 Store 用既有快照欄位記錄實際資料遷移鏈，預檢與提交共用逐跳政策／端點／schema 檢查，回退原子移除退出鏈結。新增九格政策、過期兄弟快照、兩跳快照及缺失／無效鏈結回歸；既有 `two_generated_schema_modifications_can_return_to_first_version` 保持原意及原碼。create 與序列化 validate 入列共用回合預算，failed／inspect_only／validating 均占額度（初始生成加三輪修復）；新增預建候選、停止後入列、預覽與明確新回合回歸。Shell 投影另以小幅完整性檢查封鎖非完整 generated 套件，新增核可／損壞／缺失紀錄測試，無 `file://` 退路。

指定離線環境下的本次命令與結果：

| 命令 | 結果 |
| --- | --- |
| `cargo fmt --all -- --check` | 通過 |
| `cargo clippy --locked --workspace --all-targets -- -D warnings` | 通過，0 warning |
| `cargo test --locked --workspace` | 17 通過、2 失敗；在 confine socket／D-Bus 測試停止 |
| `cargo test --locked --workspace --no-fail-fast` | 214 通過、52 失敗，4 targets 失敗；Core RPC handshake／supervisor socket 遭 `Operation not permitted`，另有 confine／notifications D-Bus 環境失敗 |
| `cargo test --locked -p ditto-store generated::tests` | 9 通過、0 失敗 |
| `cargo test --locked -p ditto-core generation::tests` | 4 通過、0 失敗 |
| `cargo test --locked -p ditto-core generated_projection_omits` | 1 通過、0 失敗 |

完整 log 在 `/data/hermes/cache/scratch/g3-audit/round1-{clippy,workspace,workspace-all}.log`。新 Core 多跳拒絕與既有兩次修改旅程尚無本 runner 的可執行 RPC 證據；Store 的等義資料旅程通過不冒充 Core／實體驗收。

**BLOCKED：完整 workspace gate 與依「gates 通過後提交」條件的本地提交。** 本次修改仍在本地工作樹；修正提交後的新 HEAD 必須重新接受差異審查，不代表 Ready 或 owner 出口裁定。未推送、未修改 wire／TS／QML／證據 JSON；protocol 型別未改，不需 schema export gate。未跑 VM／實體座位／Node／Qt，救援與資料政策語意及其他非阻擋追蹤項未改。

`.agents/notes/gate-reviews/G3-exit.md` 的追加寫入另遭 patch sandbox 拒絕（`writing outside of the project; rejected by user approval settings`）。同名「獨立審查與修正」段落已備成 `/data/hermes/cache/scratch/g3-audit/G3-exit-round1.patch`，供 coordinator 套用；本 runner 未繞過受保護路徑。

後續 coordinator 已套用該 patch，並在相同修正內容、沒有 Codex socket sandbox 的本機環境重跑：`cargo fmt --all -- --check`、workspace clippy（0 warning）、`cargo test --locked --workspace --no-fail-fast` **266 通過、0 失敗**，含新增 Core RPC 拒絕與原有兩次修改回第一版。釘選 Rust 1.98.1、Node 22.23.2／pnpm 10.11.0；Node workspace build／typecheck 通過，測試 **184 通過、2 個既有 skip**。首次 Node 執行因缺 Core 二進位前置失敗，建置後重跑通過，原 log 保留。本機 Qt／VM／實體流程尚未重跑，不將 Rust／Node 數字當作這些驗收。修正候選仍待 fresh delta review；救援語意另由 [#41](https://github.com/relvo-labs/Ditto/issues/41) 追蹤。

## 第二輪獨立審查與修正（2026-10-14）

獨立 reviewer 對 `618f62cb100709b6f9cfa5a7bcf4cae6d19ace18` 結論仍為 **FAIL**：A 未區分歷史 v4 快照與可證明的現役鏈，B 仍以可覆寫 artifact 狀態計算額度。Neil 明確授權「採用 A 方案，並一起修 B」；來源 `/data/hermes/ditto-runs/g3-pr40/repair2/authority.md`（#34 comment 6167219232）。C 投影完整性已關閉；#41 救援語意不在本輪範圍。下表在 production 修改前建立，RED／GREEN 與 gates 另依實際執行追加，不代替 fresh delta review 或 owner 出口。

### A：資料鏈狀態與決策

| 狀態／影響面 | 決策 | regression witness（具名測試） |
| --- | --- | --- |
| fresh DB／比程式新的 schema | 新庫建 v5；較新版本拒絕，不能反向遷移 | `fresh_store_and_newer_schema_refusal` |
| 真 v4→v5／backup／原資料與 Profile | 舊快照全為 unproven，保留 bytes；open_writer 先備份，open_reader 不遷移 | `v4_lineage_migration_preserves_bytes_and_backup`、`v5_lineage_migration_rolls_back_on_conflict` |
| 歷史 a→b→a→edit→s(unavailable)→b→d | 不依端點／schema／rowid 補證明；d→a 必須拒絕且 head／artifact／data 不變 | `v4_abandoned_snapshot_is_unproven_after_migration` |
| 新同 schema 所有者切換／回復 | 每一實際邊的 proof 與 data／Profile 同筆提交 | `new_same_schema_hops_keep_irreversible_lineage` |
| compatible→compatible／unavailable→compatible／九格政策 | 每跳均 proved；相容保留值，不可逆拒絕 | `rollback_checks_every_actual_lineage_hop` |
| 新兩快照→第一版 | 依兩跳快照回復；保留既有 Core 旅程原意與原碼 | `two_snapshot_hops_restore_original_data_and_refuse_missing_or_invalid_links`、`two_generated_schema_modifications_can_return_to_first_version` |
| abandoned siblings／重複造訪／missing／端點／schema／payload／proof | 最新邊未證明就拒絕，不能略過而取更舊 proved 快照 | `stale_sibling_snapshot_never_replaces_later_data`、`missing_or_unproven_edge_never_falls_back_to_older_snapshot`、既有 two-snapshot 損壞矩陣 |
| commit 失敗／普通 preflight 與提交 | proof 與快照／資料／revision 一起回滾；拒絕沒有副作用 | `snapshot_migration_rollback_and_optimistic_data_writes_are_atomic`、`irreversible_middle_and_stale_sibling_snapshot_refuse_without_changing_state` |

讀寫路徑：Store `transition` 由唯讀 `check_document` 與交易內 `apply_document` 共用；Core coordinator preflight／revision commit 呼叫兩者。data_get 仍核對 artifact／schema，data_write 不製造 proof。online rescue_restore 走一般 proposal 與 preflight；offline rescue 只寫 revision、不遷移資料，普通回退不能因此取得 proof。救援呈現／資料政策仍由 #41 決定。

### B：驗證工作狀態與決策

| 狀態／影響面 | 決策 | regression witness（具名測試） |
| --- | --- | --- |
| 預建候選／queue reserve／in-flight／cancelling | 每筆非冪等 validate job 各占一格；初始加三輪合計 4 格 | `precreated_candidates_reserve_the_turn_budget_before_enqueue`、`validation_job_outcomes_keep_individual_attempts` |
| same key replay／preview／read-only get | 回讀既有 job 不新增；preview 不計 validate 次數 | `preview_and_explicit_new_turn_survive_a_stopped_budget`、`validation_success_releases_only_its_own_attempt` |
| inspect_only→重驗→queued cancel；另一候選→running restart | 正式 finish／cancel／reconcile 不抹除舊工作；第 5 筆拒絕且 job 數不變 | `revalidation_cancel_and_restart_cannot_enqueue_a_fifth_build` |
| failed／cancelled／interrupted／unknown／缺失或 malformed 報告 | 個別工作持續計費，不讀目前 artifact 狀態推測成功 | `validation_job_outcomes_keep_individual_attempts` |
| failed→後來 full 成功 | 只釋放那筆有持久合格報告的成功工作，前次失敗保留 | `validation_success_releases_only_its_own_attempt` |
| 2+ 插件各自成功 | 無新增成功插件總數上限，仍保留 stopped／同錯／無進展條件 | `independent_successes_and_new_turn_do_not_share_spent_attempts`、既有停止測試 |
| 明確新使用者 turn／create／enqueue | 兩入口共用 job 歷史核算；新 turn 另起，重連不重置 | `independent_successes_and_new_turn_do_not_share_spent_attempts` |

不新增預算表、queue 或常駐程序。以 Core 既有 jobs.params_json 的持久 turn／bundle 與該筆 result／state 判定；歷史工作缺少可解析來源或成功證據時保守計費，不以目前 artifact 最後一次報告代替。

### RED→GREEN 與本輪 gate

production 修改前，`618f62c` 加入兩個可編譯 witnesses：`cargo test --locked -p ditto-store v4_abandoned_snapshot_is_unproven_after_migration` 與 `cargo test --locked -p ditto-core generation::tests::revalidation_cancel_and_restart_cannot_enqueue_a_fifth_build` 均 **0 通過、1 失敗，exit 101**。前者以真 v4 檔案庫保存完整 a→b→a→edit→s→b→d 旅程，再走正式 Store 開啟與 rollback preflight；後者走正式 enqueue／finish／queued cancel／start／restart reconcile，第五筆確實被錯誤接受。原始 `red-a.log`／`red-b.log` 與當時 `red-witness.diff` 保留，無編譯限制或模擬 RED。

修正後兩者 GREEN。A 另覆蓋新 proved b→d 位於歷史 unproven a→b 上方的混合鏈、v4 整庫備份與 payload bytes、未證明最新邊不可跳過、同 schema 真實 predecessor；既有九格政策與兩快照旅程仍通過，commit 失敗測試加入真 Profile head／proof 原子回滾。B 的 13 種工作狀態／報告負例均拒絕第五筆，成功釋放僅自身（含修復子版本）、六個獨立成功插件與明確新 turn 可通行。既有同錯 fixture 改走完整 jobs.finish／finish_job，保留原停止斷言，先前只改 artifact 而留下 queued job 的測試失敗 log 另存。

私有 `generation_turn_id` 只存 Core jobs.params_json；worker 用既有 artifact／work_root 白名單轉送 native host，具名 `generation_host_input_keeps_private_turn_metadata_in_core` 通過。Rust RPC／TS／QML 型別與 native host 的封閉 input 未改，未新增 native／Node／Qt 依賴；schema export 不需重產。

以下使用指定 Rust 1.98.1／離線環境，log 根目錄 `/data/hermes/ditto-runs/g3-pr40/repair2/gates/`：

| 命令 | 本輪結果／log |
| --- | --- |
| `cargo fmt --all -- --check` | exit 0；`fmt.log` |
| `cargo clippy --locked --workspace --all-targets -- -D warnings` | exit 0、0 warning；`clippy.log` |
| `cargo test --locked -p ditto-store` | 51 通過、0 失敗，exit 0；`store.log` |
| `cargo test --locked -p ditto-core generation::tests` | 8 通過、0 失敗，exit 0；`core-generation.log` |
| `cargo test --locked -p ditto-core --bin ditto-worker` | 1 通過、0 失敗，exit 0；`worker.log` |
| `cargo test --locked -p ditto-core generated_projection_omits` | 1 通過、0 失敗，exit 0；`projection.log`（C 僅回歸，無設計修改） |
| Unix socket preflight | exit 1、`Operation not permitted`；`socket-preflight.log` |
| 完整 workspace／Core RPC | **BLOCKED**；依 preflight 不執行，coordinator 承接；未重跑已知 sandbox 失敗 suite |

Store v4→v5 的遷移相容性與恢復限制見 [schema 契約](../../docs/contracts/store-schema.md#8-g3-schema-5資料鏈證明)：保留未證明歷史，不能 retroactive backfill，也不能由 v4 build 開啟 v5。新普通回退不得跨未知鏈；#41 offline／online rescue 的產品語意未改。既有 Core `two_generated_schema_modifications_can_return_to_first_version` 原碼保留，執行證據本輪由 coordinator 補驗；Store 等義旅程不冒充 RPC／實體驗收。

本輪授權允許非 RPC gates 通過後本地 checkpoint，即使 socket 阻擋；只建立新 commit（`[skip ci]`），無 push／PR／merge 操作。`.agents/notes/gate-reviews/G3-exit.md` 寫入仍遭 patch sandbox 拒絕，同輪摘要及 Opus 模型／High 請求值更正備於 `/data/hermes/ditto-runs/g3-pr40/repair2/G3-exit-round2.patch`，供 coordinator 套用。Node／Qt／VM／實體座位均未執行，證據 JSON 未改；新 HEAD 須 fresh delta review，不宣告 Ready 或 G3 owner 出口。
