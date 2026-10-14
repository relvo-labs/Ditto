# G3 實作與完成缺口盤點

2026-10-14 對照 GitHub #34、PR #40、全部 #15～#33、PRD 與 plan/05 的實作盤點。這是完成工作的追蹤文件，**不是 G3 出口通過宣告**；出口裁定仍由 owner 依 [G3-exit](../../.agents/notes/gate-reviews/G3-exit.md) 進行。

## 實作範圍

Core 持有生成紀錄、修復預算、配置 revision 與插件資料；Agent 經正式能力提出候選，Shell 只解讀兩個固定模板的受限描述。生成驗證／預覽按工作啟動，不新增常駐生成服務。開發機與 VM 證據不能替代實體座位及真實模型驗收。

| issue | 可定位的實作／驗證 | 剩餘工作 |
| --- | --- | --- |
| #15 | plan/05 六份原計畫、D-45／46、十九項 G2 交接快照；本次更正 PR #13 與 RPC 的過時現況 | owner 核定估算及待決策項；不回填歷史量測 |
| #16 | `crates/ditto-test-host`、`tools/generation-host`、`tests/g3/host`：獨立 service、Landlock／seccomp、配額回讀與 deadline | 實體參考機同組故障與桌面存活證據 |
| #17 | `ditto-protocol/src/generation.rs`、Core 發布閘門；新增四種 enforcement 的 Rust／TS 共用向量 | 參考機分級驗收；未知值不是可降級的等級 |
| #18 | cgroup 整組終止、超限診斷、`tests/g3/restart` 不重播與回收 | 實體桌面／hostd／原生應用存活矩陣 |
| #19 | Rust-first seam、逐插件授權；coordinator 接受點重查撤權／鎖定；真 app-server 一次性啟用 approval 不產生永久 data grant | 實體參考座位 GUI／Agent 競爭；本機 G2 19 項正式 Shell 授權回歸已通過 |
| #20 | Store v4、完整內容地址 bundle、不可變父版本、來源刪除遮蔽與啟用失敗歷程，Core 可查 | 功能已有開發證據；歷史備份／已匯出內容不承諾抹除，沿用隱私限制，不作完成承諾 |
| #21 | schema／資料 CAS；實際桌面快照、相容保留新值、不可逆拒絕；Core 資料提交失敗／損壞快照補償 | 相同資料／舊版讀取流程的實體參考座位確認 |
| #22 | 兩個受限模板、SDK、QtTest、固定 Shell 解譯器 | D-17 選型裁定；不能以模板測試代替 AT-06 |
| #23 | 封閉描述、固定 imports、檔案白名單、禁網路與子程序、Core 能力代理 | 實體平台的完整負例與政策確認 |
| #24 | 五關實測時間、真 Wayland 預覽；真 native 逐關失敗及非法 import；管理中心工作恢復、逐關文字與雙預覽各自鍵盤取消 | 實體可見預覽、焦點與鍵盤操作確認；開發自動化矩陣已補齊 |
| #25 | 修正 entry id 相同卻接受舊版的漏洞；實際 artifact id 必須吻合；Core load／health／readback 及資料 commit 失敗均回舊面板、revision 與資料 | 實體參考座位同組失敗矩陣；Core 交易測試不冒充實體畫面證據 |
| #26 | 持久三輪／同錯停止；本次新增無關卡進展停止、跨連線與同回合分支／換插件 ID 防繞過 | 真模型修復行為；重新表述不得冒充明確新需求 |
| #27 | 不可變新版本、changed_fields；Core 與真 Wayfire 桌面均驗證連續兩次修改後回第一版的外觀及資料；真模型未要求欄位保留 | 實體參考座位確認；不再把自動化兩次修改列為未實作 |
| #28 | 新 Core 上真實訂閱四回合 **19 項通過**，包含要求符合、未要求欄位保留、面板、服務、實際按鈕及清理回讀；產物保留 | 已有 headless 真模型開發證據；**實體參考座位完整流程仍待驗** |
| #29 | `docs/upstream/g3-adoption.md` 九欄／四欄矩陣、hash／vendor guard、模型／工具／會話執行 | owner 文件審查；G4 shipping 授權另做 |
| #30 | 真 native 五關逐關失敗／非法 import、OS deadline、load／health／readback 補償、管理中心失敗文字與後續未執行標示 | 實體參考座位失敗可見、下一步及 Shell／hostd 同 PID 證據 |
| #31 | OS 超限探針、兩槽／第三工作排隊、取消、revision 保留 | 參考機同組 AT-26 |
| #32 | 真 archive 的任意 QML／Node／ELF 在實際 full、舊 ABI partial、缺 bus unavailable **九格負例已通過**；Core 拒絕／revision／執行見證留存 | 同組矩陣的實體參考座位確認，不再缺開發自動化 |
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

## 完成順序與驗證入口

1. 本機快檢：`bash tests/g3/run.sh`、`cargo test --locked --workspace`、workspace clippy／fmt、`pnpm typecheck`／`pnpm test`、schema／TS 新鮮度及 skills lint。
2. 可拋棄 VM：`bash tools/dev-vm/run-g3.sh`；再用 README 的舊 ABI 命令確認 `partial`、不執行候選及退出 2。來源樹含未提交改動時記 dirty 與 hash，不能把 HEAD 當成完整實作指紋。
3. 真模型：本次已取得既有訂閱／外部傳送的明確授權，執行 `tests/g3/agent/real.sh`，保留四回合 artifact、模型選擇、工具 trace、實際互動與清理回讀。後續執行仍需相應授權；腳本模型不計語意品質，headless 真模型也不冒充實體座位。
4. 參考機：按 `04-verification-and-measurement.md` 重跑 AT-06／07／22／26／29，記錄顯示、PID／cgroup、revision、失敗卡片與回讀。資源另依冷登入三次四態方法採樣，不在目前使用中的桌面偷偷登出或做超限測試。
5. owner 審查 AT-18、D-17 與五項出口，將裁定回寫 G3-exit。G4 承接發行授權、中文／雙螢幕、nightly 與 D-38／46 既有項，不提高原門檻。

首次驗證結果與來源指紋見 [後續證據](../../.agents/notes/gate-reviews/G3-followup-2026-10-14.md)。後續實作提交 `9e6e37d` 與證據更新到 PR #40；GitHub 舊 HEAD 的 check 失敗與當前版本分開記錄，本機通過不能寫成遠端 CI 已通過。

使用者追問「每個 issue 都做完了嗎」後的功能補齊與最新證據見 [功能補齊紀錄](../../.agents/notes/gate-reviews/G3-functional-completion-2026-10-14.md)。GitHub #15～#34 仍全部開啟；實作完成、開發驗證、實體驗收與 owner 關閉分別記錄，不以文件勾選代替功能或出口。

PR 更新後另修正 [CI 長 checkout 路徑與早期報告](../../.agents/notes/gate-reviews/G3-ci-followup-2026-10-14.md)，管理中心快照亂序保護增至 7 項 QtTest。CI 實際結果分開記錄，不以先前本機成功推定遠端已通過。
