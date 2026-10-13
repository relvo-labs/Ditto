# G3 階段收尾與出口評審資料

| 欄位 | 內容 |
| --- | --- |
| 日期／狀態 | 2026-10-14；**整合實作提交審查，G3 出口尚未裁定通過** |
| 計畫／追蹤 | [plan/05](../../../plan/05/README.md)；[#34](https://github.com/relvo-labs/Ditto/issues/34)，相關 #15～#33 與 G2 follow-up #35～#39 已逐項閱讀 |
| PR | [#40：受限生成、隔離驗證與版本回退](https://github.com/relvo-labs/Ditto/pull/40) |
| 分支 | `codex/g3-restricted-generation`；整合實作 `5ed55b8c44d94bae6e3dd70841c7961b85b25eb2`；G2 PR #13 已合併，本次 PR 以 `main` 為基底 |
| G2 交接 | owner 依 [D-46](../decisions/2026-10-13-d46-g2-functional-acceptance-and-g3-integration.md) 接受功能完成；PR #13 已提供 G2 參考機量測，D-44 後端寬鬆上限已為 1G；剩餘 #35～#39 保留 |
| 歷史 | 獨立基礎設施 `d77b4e7`、證據 `27abec9`；先前未接線的狀態保留於 [歷史快照](G3-foundation-2026-10-13.md) |
| 評審者 | owner；本紀錄提供事實與缺口，不代替 owner 裁定 |

## 1. 五項出口

| 原出口門檻 | 本次結果 | 證據與剩餘驗收 |
| --- | --- | --- |
| AT-06：生成待辦摘要與快捷動作面板，有新產物、驗證與預覽，可啟用並繼續修改 | **有端到端開發證據，待驗收** | 真 Core／Wayfire／Shell、釘選 app-server 與腳本模型完成兩類產物各自建立、五關、真實隔離預覽、啟用與新版本修改；待 #28 真實模型與參考機流程，腳本輸出不計模型品質 |
| AT-07：無效 QML／逾時／非法 imports 不進主 Shell；顯示失敗且桌面可用 | **有負例與故障開發證據，待驗收** | 封閉描述拒絕 QML／JS／native，五關失敗／缺關不得發布；原生宿主 timeout／OOM／取消清理；缺 Shell 啟用中止且 revision 不前進。管理中心呈現失敗與診斷；待參考機逐關故障、失敗卡片與桌面同 PID 完整矩陣 |
| AT-18：三類固定上游能力運行，功能、來源、相容性與修改均可追溯 | **文件與執行回歸齊備，待文件審查裁定** | [九欄／四欄沿用矩陣](../../../docs/upstream/g3-adoption.md)、9 檔 hash、vendor guard、模型／工具／會話測試及 app-server 多輪實際運行；未新增 vendor source patch，真訂閱另列未執行 |
| AT-22：新插件資料 schema 升級後回退，依快照／相容政策回復 | **有交易與桌面回讀開發證據，待驗收** | Store v4 前向遷移；升版與 Profile 同交易保存資料快照，桌面 undo 回讀舊 schema／資料／面板；相容政策保留可讀的新值，不可回退時拒絕。待參考機相同流程與 owner 評審 |
| 生成插件在隔離宿主中受檔案／網路／程序與時間邊界限制；無法執行時降為可檢視候選 | **有實際 OS／生產宿主證據，待參考機驗收** | `generated-templates-v1` 回讀實際 cgroup、Landlock／seccomp 與清理；ABI <6 或缺宿主時只能 inspect／拒絕發布。診斷 `diagnostic-v1` 永遠無啟用資格；不是任意 QML 或程式碼沙箱 |

AT-26：兩個生成工作執行、第三個排隊、取消與 artifact 狀態持久化、Core 崩潰後回收舊 worker／native cgroup、禁止重播並恢復接單，已有 headless 開發證據。AT-29：raw QML／JS／native 三種入口拒絕、缺 helper／bus 與舊 ABI 的 fail-closed 已有證據；完整參考機分級矩陣仍待執行。以上不變更門檻或把未跑案例標成通過。

## 2. 交付與相關 issue

| issue | 本次可審查交付 | 尚待完成 |
| --- | --- | --- |
| #15 | plan/05、G2 交接快照、D-45／D-46、依賴與估算提案 | 估算與待決策項由 owner 核定；歷史表格不回填為量測通過 |
| #16／17／18 | 獨立 native 宿主、512 MiB／0 swap／1 CPU／64 tasks、實際 enforcement／原因、deadline、OOM／取消／清理、Core 重啟對帳 | 參考機故障及資源驗收 |
| #19 | Rust-first 9 個 development 能力，Definition／Core Provider／Agent 與 CLI Consumer，動態 schema、共享向量、逐插件資源授權 | 參考機 GUI／Agent 授權競爭與撤權全矩陣 |
| #20 | 內容地址完整 bundle、來源最小化、父版本、驗證／預覽／啟用歷程、Store v4 與舊保留表遷移、對話刪除遮蔽來源 | 備份／匯出等跨功能隱私驗收；遮蔽不等於磁碟鑑識抹除 |
| #21 | 資料 CAS、schema／版本檢查、快照／相容／不可回退政策、與 Profile 原子提交及桌面 undo | 參考機回退案例 |
| #22／23 | 有界宣告式 DSL、兩個可信固定模板、純文字與封閉 imports、限定資料／工作區代理、原生 syscall 與檔案／網路邊界 | D-17 兩類選型裁定；自由 QML／JS／native 仍不開放 |
| #24／25 | 原生 syntax→contract→load→focus→interaction 五關、獨立 Wayland 預覽、真實 phase、發布後正常 ChangeSet 啟用、readback 與失敗補償 | 參考機逐關故障、首幀與完整 GUI 操作 |
| #26／27 | 持久最多三輪修復、同錯兩次停止、真正新使用者回合才可開新預算；不可變遞增版本、差異、重驗證、撤銷與啟用冪等 | 真模型修復／重新表述與參考機回歸 |
| #28 | 兩類生成與各自再修改的完整腳本模型測試；真模型 opt-in runner 已準備 | **真實訂閱模型未執行**，不可據此關閉 issue |
| #29 | 三類能力來源、信任、授權、修改、host contract、測試及四欄沿用矩陣 | owner 文件審查；G4 shipping 授權另做 |
| #30／31／32 | 單元／契約／Core／真桌面／重啟／VM OS 與舊 ABI 負例；所有失敗紀錄保留 | 參考機完整故障與 enforcement × 三種入口矩陣 |
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

### 3.3 未執行與自動核准結果

**G3 真實訂閱模型測試未執行。** 自動核准審查拒絕以既有 keyring 登入執行真實模型回合，理由是該動作會向外部模型傳送測試／可能的工作區脈絡，並涉及既有帳戶及設定副作用，而原實作授權未明確涵蓋該外部披露。被拒的命令未執行；沒有改走其他外部模型迴避。

已準備 `tests/g3/agent/real.sh` 與四回合自然語言 oracle，僅做靜態語法檢查；須取得明確授權後，以指定私有開發測試 store 執行。真實訂閱與參考機流程未跑，不影響提交目前可審查實作，但不能宣告 AT-06／G3 出口完成。

實體座位逐關故障、中文鍵盤、雙螢幕、冷登入三次四態 PSS／CPU、呈現時間、100 次啟停與五晚 nightly 均未由本批重新驗收。G2 參考機暖態 Agent p95 88.6～89.2 MiB 的原始證據見 G2-exit §3.6；VM 超過 150 MiB 的差異與 D-44 由 #35 追蹤，後端已採 1G 寬鬆上限。這些 G2 數字不作 G3 資源驗收；D-06a 與 D-38 其他缺口繼續追蹤，沒有移除程序或提高門檻。

## 4. 已知限制與 G4 交接

1. 執行內容限兩個可信固定模板；描述資料不插值成程式碼。既有 QML provider、Node、native 套件不能僅自稱 generated 取得信任。自由生成與通用遷移腳本不在此次能力中。
2. 每個工作有 worker scope 與 native service，資源盤點須兩者都計入；512 MiB 是單一隔離宿主硬上限，不能寫成全部活動工作或完整桌面的實測成本。沒有新增常駐生成服務。
3. bundle 包含固定模板 hash；模板更新後，舊 validation 的相容性與重驗證必須另外處理，不能把舊證據套到新程式。管理中心目前呈現最近十筆產物，完整歷程仍由 Core 查詢。
4. 來源刪除是權威紀錄的邏輯遮蔽；備份、已匯出內容與磁碟抹除不由此保證。資料與描述不可放憑證，沿用秘密引用及同一授權路徑。
5. G4 納入新 Qt6Test 執行期依賴、Qt 版本／來源／授權文本與重新連結義務；專案目前 UNLICENSED，Codex 再散布、名稱／角色素材與所有 shipping 權利仍待完整審查。
6. 下一步先補 #28 真模型與參考機 AT-06／07／22／26／29，再由 owner 審查 AT-18 與五出口。G4 承接安裝／發行、桌面基本面、中文／雙螢幕、nightly、資源／幀時及 D-38／D-46 未完項。64 人週仍是未核定規劃，不把 Agent 執行時間換算人週，也不在缺少參考機數據時承諾新的工期。
