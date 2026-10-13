# 03｜Agent 執行迴圈與 Harness 移植

工作包：AGENT-01～08／10／12～14。必讀：`ditto-agent-changeset`、`ditto-upstream-port`、`ditto-cordis-plugin`、`ditto-authority-boundaries`、`ditto-generation-safety`。

## 1. 組合與實作落點

新增 `packages/agent-runtime/`，提供 `ditto-agentd` 可執行入口；一個 Node 程序、一個 Cordis root，按受控啟動取得 Core 身分。建議模組：`runtime.ts`、`core-link.ts`、`turn-loop.ts`、`catalog-tools.ts`、`planner.ts`、`session-persistence.ts`、`settings.ts`、`model-provider.ts`、`activity.ts`。介面型別從 `@ditto/protocol` 匯入，不複製 hostd 的宿主授權身分。

Cordis 內服務以 inject 宣告依賴、所有 timer／RPC／stream／listener 有 disposer；卸載等待非同步清理，觀察 waterfall 呼叫 next。Agent 使用 Cordis 組合不會取得 desktop hostd 的註冊租約或 Profile 寫入權；不載入每個桌面插件。RPC transport 的通用 framing 可抽到 protocol package，host-specific lease／on_behalf_of 邏輯留 host-runtime。

Agent 只載可信內建規劃程式。不能載入模型生成 JS、工具輸出中的 imports、外部說明指定的程式或任意 filesystem loader；不提供 bash、run_code、terminal execute、包管理器或 repo 改寫工具。G3 隔離未就緒時，新增插件需求只能回可檢視的建議／已核可模板能力，不能宣稱生成並啟用。

依 D-09a，第一條流程採 Codex app-server。Node 是 Ditto controller，app-server 是受控執行後端；一般 API 路徑用 Harness turn-loop，Codex 路徑用 app-server turn 執行，**兩者不疊加自主迴圈**。共同沿用工具 registry／guard、Core persistence 與配置協調。共用後端介面、stdio framing、登入／模型／配額、動態工具與事件映射由 AGENT-14 實作；內建工具禁止與 OS 強制界線由 PLAT-04、QA-09 取證，詳見 [10](10-codex-app-server.md)。

## 2. 上游取用與依賴 spike（D-05）

盤點 commit 固定為 `477b4f420553e8a52c2fbccc464d7561b239c443`。下列 source 相對 `../deepseek-harness`，不是依賴開發機同級目錄才能發行。採原始碼移植或確切版套件鎖定，落入本倉庫可重建的依賴與 lockfile；不得拉浮動 main。

| 類別／上游 source | 移植方式提案 | Ditto 修改與必留驗證 |
| --- | --- | --- |
| 模型 Definition：`packages/llm/llm` | 保留 provider-neutral vocabulary／stream／abort seam，必要支援模組一起鎖定 | Rust wire 映射、完整／分段工具呼叫、usage、失敗與取消 |
| 一般 API Provider 候選：`packages/llm/llm-deepseek` | 可選 pinned adapter／transport；第一個必要後端已改為 Codex app-server，不要求為測試另付 API 費用 | API 路徑仍需 Core credential resolver、端點／模型設定、移除 Harness local file／account／自動上傳路徑；Codex 是不同執行 seam，映射與移植取用證據依 D-05 評審 |
| 工具：`packages/core/tools` | 保留 registry、pre→execute→post 和單調 guard；採受限 native dispatch port | 關閉 PTC／run_code、sandbox optional branch及通用程式執行；Core授權不可被middleware放寬 |
| Session：`packages/core/session` | 保留 event-sourced Session、訊息／工具結果投影、interrupted turn vocabulary | Core-backed persistence、flush barrier；歷史是資料，不能作dispatch queue |
| Persistence Definition：`packages/session/session-persistence` | async create/open/stat/list、SessionHandle read/append/flush/close 語意沿用 | RPC provider、writer generation、跨程序可見性；Ditto額外export/delete |
| Approval：`packages/interaction/user-approval` | thin adapter保留ask/never與四結果 | 決策由Core與受信Shell作出，Agent沒有authority；late answer拒絕 |
| Settings：`packages/settings/settings` | 移植schema表單／revision conflict概念，改寫provider | 刪除YAML、fs writer、loader.write，桌面patch走ChangeSet；AI偏好Core CAS |
| Credentials：`packages/credentials/credentials` | 僅服務定義及按請求解析概念，必要時自寫compatible adapter | 不沿用 local plaintext backend，Core keyring引用 |
| Agent loop、scope、system-prompt、brand、timeout、util 等 | AGENT-12依import與peer dependency逐項建立閉包，分必需／型別／可移除 | 有界turn迴圈、單一活動turn、型別和事件scope；每個取用檔都有來源 |

三類移植不是只有三個獨立套件：現有tools依systemPrompt並列agent／session／approval／sandbox／PTC peers，LLM provider也有fs／home paths／attachments peers。**M0 spike先證明受限組合能跑**，不把完整 Harness app 一次搬入。原樣package若有禁用功能仍在entry export觸發載入，需裁剪入口與修改紀錄；不能只聲稱「不呼叫」就算沒有可達路徑。

每類都有 Definition／Provider／Consumer：一般 API 為 LLM→provider adapter→turn-loop；Codex 為 model vocabulary／共用 backend→app-server bridge→controller。Tools→desktop dispatcher→planner／backend tool request；SessionPersistence→Core RPC adapter→Session／恢復流程。Codex bridge 不能宣稱是上游 ctx.llm 原樣實作；D-05 必須確認所需模型契約確實被取用，若調整移植範圍則另附實際取用與執行證據裁定，不能以未引用程式或 mock 補足移植出口。三類各有實際執行測試，並寫 `docs/upstream/harness-g2-port.md`（待新增）。紀錄含repo URL、commit、套件與版本、檔案範圍、取用種類、licence及notice、修改理由／路徑／測試、宿主契約／信任等級、依賴閉包與更新程序。沿用既有vendor逐commit檢查思路，避免重現PR11的記錄漏網。

## 3. 第一條真實垂直流程

M1先用一個已存在且可逆的appearance token或entry配置修改：Shell輸入 → Core持久submit → Agent讀真實目錄與Profile → 真實LLM輸出typed plan → Corepropose → 既有ChangeSet進度 → desktop回讀與QML呈現 → 完成卡。M1就取真機artifact和模型fingerprint；mock只供單元測試。

必要連線為 Codex 個人訂閱登入，M0 探測本機 codex-cli 0.160.0 的 schema 與工具限制，M1 用正式 keyring 登入後做真請求。model/list、帳號能力與实际請求一起驗證可用模型，不預設 model ID 或額度。D-09 尚需核定預設模型／effort、配額與 keyring probe，已決方向不等於連線已成立。一般 API 是替換路徑，不能因訂閱耗盡自動改用。不要為了模型首字慢而讓 Agent 或 app-server 永久常駐。

## 4. Turn 執行與動態工具

1. Core持久受理訊息與turn，Agent取得writer、settings snapshot、grant snapshot與活動租約，flush使用者訊息。
2. 每個計畫起點取得動態capability catalog、schema、availability及當前Profile revision；必要視窗資料走獨立grant。缓存以catalog_revision／連線世代索引，provider失效立即invalidate。
3. 將可用且允許的能力轉工具schema，名字用穩定可逆編碼映射原capability_id；不以硬編碼同一句自然語言選特定命令。未知tool name／參數在dispatch前拒絕並重新讀catalog。
4. 模型輸出只能是typed intent／tool invocation。配置任務優先合併為**一筆**ChangeSet，固定base_revision和差異；read-only discovery不被當作桌面變更。
5. pre-execute做schema、scope、grant／approval、budget、取消和capability availability檢查；最後由Core再檢查。observer不能短路；Agent的policy只能更嚴，不能自授權。
6. durable記錄tool intent與key，取得Coreoperation／change關聯後執行；post-execute保存typed結果、readback證據與usage。LLM自由文字不能覆寫core result_kind。
7. 達成／失敗／取消／預算耗盡後停止新增dispatch，flush結果，Core落turn terminal，釋放writer／activity；UI拿持久狀態。

桌面配置不得經 `desktop.windows.move/resize` 拼出無revision的「開發桌面」。這些能力可處理明確的一次視窗操作，但**可保存布局**必須走PLAT-01的新LayoutIntent與既有ChangeSet。`permissions.grant`、credentials、內部host註冊、session刪除及診斷特權不因catalog存在就暴露模型；使用明確allowlist按caller與resource過濾。

token stream／tools schema／tool result都做最大bytes與depth；部分JSON／工具串流未完成前不可dispatch。HTTP成功或tool返回字串不代表桌面成功，只有Core verified result和真實readback才可以回「完成」。

## 5. 規劃、多輪與含糊目標

規劃上下文包含active Profile／base revision、最近已verified change、目標entry ID／layout rule ID、允許修改路徑與Core回讀摘要；不使用「上一句模型說成功」定位。「再窄一點」只改最近目標的width／ratio，「保持顏色」在plan約束及QA diff中明確保護appearance tokens。

多輪若GUI已改Profile，重新讀revision與相關值，拒絕舊before／base；若同項意圖有歧義，展示當前具體選項，不能自動重base整份舊document。操作cancel後未verified的目標不升為recent successful target。

合理、可逆的預設可直接試用並給撤銷卡。指定專案資料夾、關閉視窗、文件內容上傳、會影響資料的目標模糊時，列真實候選；找不到資料可建立空白可逆組合並說明，不能捏造檔案。澄清回答由Core綁原turn與選項，不能拿過期回答套新任務。

未支援需求依當前能力說明：能改配置→直接改；已裝插件可組合→組合；已知可安裝套件→顯示安裝與授權；需要新插件→指出G3路徑。無來源的安裝建議不會自動執行。對話中展示實際「準備／試用／套用／驗證」，不可播放假進度百分比。

## 6. 模型與工具預算提案

D-09 啟動時核定預設：每 session 一個活動 turn，其餘 queue；單 turn 至多 24 次 Ditto 工具 dispatch；provider connect 10s、stream idle 60s、整 turn 模型等待 120s（工具／人的確認另計），timeout 後保存已完成內容。一般 API 路徑另限至多 8 輪模型呼叫；Codex 的內部推理／模型呼叫數由 app-server 管理，不能宣稱已強制每輪上限。Codex 依已驗證的協定施行外部 turn deadline、tool cap、usage／配額檢查與 interrupt，token 上限若不能預先硬控須明示。這些是可調設定提案，不是 PRD 資源門檻。

一般 API 可依實際支援的最大輸出預留 token、請求後以 usage 結算；Codex 訂閱以帳號 rate-limit 視窗／reset 與 turn token usage 呈現，不虛構 per-token API 費用或可硬控的最大输出。usage 缺失標「估算／未知」，不得顯示零費用；配額耗盡保留對話並提示等待或重新連接，不自動買額度／切 API。費率與幣別須有來源及時間戳。模型 alias 若不能 immutable pin，固定測試 window、記錄 returned model／可取得 fingerprint／時間及 alias 限制，模型變動重跑。

## 7. 持久屏障與恢復

AGENT-04實作async SessionHandle；AGENT-13把同步Session.append feed排成有序RPC queue。flush等待所有已入queue的事件durable；失敗阻止下一工具。每個side-effect在dispatch前都有Core記錄的intent key與對應operation，不能先執行再補日誌。

重啟重建messages與recent targets，未終了turn標interrupted並查每個operation；已committed只回讀結果，queued未dispatch且沒有受理紀錄的操作不自動執行。沒有冪等契約且找不到operation結果則unknown，讓使用者決定下一步；不得為「對話接續」自動重送付款、通知、啟動應用或close request。詳見 [06](06-lifecycle-jobs-and-recovery.md)。
