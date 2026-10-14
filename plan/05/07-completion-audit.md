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
