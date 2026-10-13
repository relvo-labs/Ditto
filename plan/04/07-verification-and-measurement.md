# 07｜驗證、語意任務與量測

工作包：QA-01～09、DOC-01。必讀：`ditto-verification-evidence`、`ditto-process-budget`、`ditto-decision-record`、`ditto-prose-standard`。規則源為PRD§19／21與milestones/01/04；本文件不能自行改數字。

## 1. 證據分層

| 層級 | 驗證內容 | 可以支持的主張 |
| --- | --- | --- |
| Rust／TS單元與共享契約向量 | schema、seq、CAS、取消狀態、閉集、duration和grant checks | 確定性契約與邏輯正確 |
| mock provider整合 | 分段stream、invalid tool、超時、abort、缺usage、writer失效 | 錯誤路徑可重現；不能計入NFR-12 |
| 真實provider＋Core整合 | 真正LLM、動態catalog、原生readback、非同句修正 | 對話垂直流程成立 |
| 登入參考機GUI | 真實focus、中文鍵盤、首幀／呈現、avatar、lock與應用存活 | 實際桌面互動與效能 |
| 反覆與故障注入 | crash／disk／race／job超限／回收 | 中斷後資料與桌面有明確結果 |

不得將mock成功、Agent自述、Core耗時、headless畫面或測試clock當另一層證據。出口對每項填通過／未通過／條件通過／未執行，条件通過的條件不能藏在總結。

## 2. 50題固定集與保留集

新增提案：`tests/g2/semantic/tasks.json`、`holdout.json`、fixture setup、state oracle、driver、judge、README。測試可以用CLI建fixture，但受測語句只能經正式對話入口→真實模型；禁止以測試工具旁路做完再讓Agent報成功。

| 類型 | 固定題數 | 必須包含的實際結果 |
| --- | --- | --- |
| 外觀／面板／Dock設定 | 8 | tokens／entry config／供應者readback與QML顯示 |
| 布局／工作區 | 8 | 真實Firefox／foot／Kate幾何、workspace、已保存rule |
| 插件組合與通知行為 | 8 | 至少含跨布局＋插件＋通知三類計畫，不僅3個read-only工具 |
| 保存／複製／比較／切換／撤銷 | 8 | revision鏈、activeProfile、應用／未存內容存活 |
| 多輪與模糊目標 | 10 | 最近目標、顏色保留、真實候選、合理預設免重問 |
| 未支援／授權／離線／恢復 | 8 | 誠實缺口、拒絕無授權副作用、持久result與readback |
| **合計** | **50** | 固定集繁中25、英文25 |

每題包含task ID／version、語句與turns、前置Profile與windowsfixture、allowedpaths、expected state predicates、untouched field hash、expected permissions／clarification、cleanup、oracle版本、不可逆副作用計數。任務失敗不重抽較容易句子；模型慢與budget超限按預註冊規則記fail／infrastructure_error，後者需有獨立証據並完整重跑，不能挑成功輪次。

保留集提案同樣50題繁中25／英文25，涵蓋同類意圖的不同措辭／順序／代稱，非字串替換；不能寫進prompt／parser特例。D-20固定模型、adapter、sampling、tools／catalog與task version；D-43提案保留集也≥90%且較固定集下降≤5個百分點，對應「不得明顯下跌」，未核定前呈現原始比較而不自稱合格。50題一題2pp，不能隱藏離散差距。

語意分數只計真實状態满足predicate且無未授權改動；正確拒絕、询問或unsupported在預期如此的題目算成功。每題的模型輸出、脫敏tool trace、change／operation IDs、before／after／readback與窗口存活證據可查。固定集最低45／50；結果同時按語言與類型細分，避免總分掩蓋中文／多輪失效。至少一次完整出口run；另以重複代表題觀察波動，不拿最好run取代正式結果。

## 3. 功能與故障矩陣

| Suite提案 | 最低案例 | 對應出口 |
| --- | --- | --- |
| `conversation-persistence` | writer競爭／舊generation、append／flush、torn tail、中段corruption、disk full、migration rollback、delete中斷 | EX2-17 |
| `contract-vectors` | 新types雙語言roundtrip、unknown fields／enum、錯版、過期token、自述origin、reorder／overflow／unsubscribe | EX2-18 |
| `approval-context` | ask／never、已有grant、四decision、UI無／鎖定、取消／expiry／late answer、同GUI/Agentresource、每類context與撤銷 | EX2-06 |
| `privacy-secrets` | canary key／私人文本、Profile／對話分別export、import missingref、journal／errors／job／crash artifact掃描 | EX2-09／17 |
| `prompt-injection` | 中英文件、title、clipboard、manifest、tool result偽造角色／命令／permission | EX2-06 |
| `concurrency` | model規劃後GUI改、prepare時GUI改、撤grant時dispatch、兩次submit同key不同payload | EX2-04 |
| `disconnect-cancel` | provider首字前／中斷、tool受理前後超時、RPC丟ack、cancel與commit競爭、unknown結果 | EX2-05 |
| `agent-lifecycle` | 單例10並發喚起、真實5minidle＋10s釋放、wait approval、active longjob、handoff、drain中新訊息、100cycle | EX2-07／15 |
| `crash` | Agent受理前／prepared／applying／verifying／committed未記result；Core／hostd／Shell中斷；重連不重播 | EX2-08／18 |
| `worker-budget` | 3job只2running、queue cap、queued／runningcancel、deadline、OOM、fork超限、Core重啟归属 | EX2-15 |
| `shell-conversation` | 同state兩surface、中文preedit／paste、shortcut／無avatar、reduced motion、焦點、斷網恢復、onboarding skip | EX2-10／16 |
| `layout-intent` | 幾何／ratio容差、最近目標變窄、相同app多視窗、未啟動app、output丟失、rollback／closed window | EX2-01／02 |
| `codex-backend` | 真訂閱登入／取消／登出／切帳號、keyring locked、模型／quota／usage、expiry／耗盡、不自動 API；dynamic tool dispatch／未知工具／stale call拒絕；內建 shell／寫檔／MCP／hooks／subagents不可旁路；ephemeral history／crash不重播、interrupt與Core取消分離、整組 idle與崩潰清理、所有provider暫存／日誌秘密掃描 | EX2-19及07／08／09／14／15 |

取消／副作用計數取Core或實際應用狀態，不能只spy Agent函數調用。受理前後kill點以durable watermark／operation記錄標定，固定sleep碰運氣不是race證據。擴充G1 fixtures與fault points，release binary不帶可任意觸發的測試權限。

## 4. 資源基線與方法

既有G1 `61ae38b`的三次full-no-Agent PSS p95為449.9／449.1／450.9MiB，hostd45.2／45.1／45.4MiB，來自 [G1評審§6](../../.agents/notes/gate-reviews/G1-exit.md#6-ex1-10-分層資源參考機2026-10-05)。這是比較基線，**不是G2可用的剩餘配額保證**；新build需全部重測，不拿異版差值當通過。

參考機 `ditto-ref-ws-rtx4060-01`；真冷登入 → 暖300秒 → 採600秒、至少3次，固定Profile、插件／資料／角色／對話長度、模型SDK與索引。完整記hardware、kernel、Qt／Quickshell／Wayfire／wlroots、Rust／Node／pnpm、git SHA、model fingerprint、PIDs與cgroups。另有active trace不能冒充穩態sample。

四種產品狀態各自報告：無Node救援、完整桌面Agent退出、Agent SDK已載入但無active turn暖態、活動模型／重工作。暖態測量期間為避免5min正常回收，可用明確標註的**measurement-only hold**，不能把假task改成production保活；正常idle驗收另跑。每種狀態需三次cold-login系列，不把同登入重啟3次叫冷登入。

| 範圍 | 有效初始PSS門檻 | 量測說明 |
| --- | --- | --- |
| Core與基本內建服務 | ≤80MiB | PRD；D-06a 40MiB提案未核定 |
| Shell與預設角色 | ≤250MiB | PRD；D-06a 230MiB提案未核定 |
| Cordis hostd | ≤100MiB | 不把新增桌面服務排除 |
| Agent暖態 | ≤150MiB | controller＋app-server＋必要子程序合計；SDK已載、固定中等會話，無activejob，另列每 PID |
| 完整桌面Agent退出 | ≤600MiB | 含合成器、Core、Shell、hostd、產品新增背景服務 |
| 完整桌面Agent暖態 | ≤750MiB | 上列加Agent；worker活動另報 |
| 10簡單插件增量 | ≤50MiB | 若G2改動其底座，重做相同baseline A/B |

PSS讀smaps_rollup，穩態以p95判定，報median／p95／peak；RSS另列，不能PSS＋RSS。CPU完整桌面Agent退出10min平均<單核3%；新增服務必須計入。Node heapUsed／external／arrayBuffers各列不重複相加；GPU顯存另報。使用者瀏覽器／編輯器、既有OS服務、本機LLM權重可依PRD排除但明列，模型SDK、Ditto broker或worker不能排除。

100次Agent啟停／chat subscriptions／writerhandle壓力：無孤兒能力、訂閱、listener、timer／child；暖機後PSS median增加≤10%且不得持續單調成長。參考G1tasks壓力p=.074與呈現警訊，保留原數據，重測依預定判法而不挑有利run。

## 5. 延遲與呈現

| 指標 | 樣本／目標 | 起止點 |
| --- | --- | --- |
| NFR-13 Agent冷啟動 | 30次，p95≤2s | 人的對話觸發→Core確認 authenticated controller 與 Codex backend ready；起點不能移到spawn後，首次登入／模型首字另報 |
| NFR-02 暖chat／launcher | 各200次，p95≤150ms | 輸入事件→首幀可見；使用QML與實際呈現timestamp |
| NFR-03 本機變更回歸 | 200次，p95≤100ms | Core受理→可見結果；原readback耗時另列 |
| NFR-04 插件替換回歸 | 100次，p95≤2s | 已安裝候選prepare→committed；download／LLM／人的確認排除但另記 |
| NFR-05 動畫回歸 | 每指定phase至少95%frame≤16.7ms | 同時報QML與wp_presentation；idle／pointer／drag／chat open／stream／commands分列 |

冷啟動每次先確認Agent PID與children消失、對話已flush；provider網路TTFT、planning、tool、Coreapply、download／build分別報。以同一monotonic clock或有誤差上限的對時方法關聯跨程序timestamp，不直接相減兩個未知epoch。warm UI不等待LLM才顯示surface；QML動畫熱路徑RPC仍為0。

Codex 另固定 CLI 版本／binary hash、實際 schema／experimental capability、model／effort／可取得的 returned fingerprint、有效工具清單與隔離模式。訂閱真帳號測試不把 token 搬入 CI；參考機受控登入、產出去敏 artifact，quota 耗盡列外部依賴，不無界 retry 或偷偷走 API。本次只查官方文件與本機 0.160.0 schema，**尚未登入、推論、測工具隔離或量資源**；因此任何 Codex 功能目前均不能填通過。

目前G1已有QMLframe達標但wp_presentation警訊（p95约16.76／16.82ms）與首幀缺證據；G2報告須同時呈現。測量指標不能用換時計方式「解決」未達標，依D-06a／D-38流程附data與調整提案。

## 6. CI 與執行命令的交付

沿用cargo／pnpm、export freshness、i18n／skills lint、vendor manifest、G1跨語言與hostlifecycle workflows。新增G2 suites與README、機器可判定summary；`tests/g2/`與以下入口尚未建立，QA-08建立後才可當實際命令：

```text
tests/g2/run.sh --suite contract|persistence|security|lifecycle|shell|semantic|measure
tests/g2/semantic/run.sh --tasks fixed|holdout --model-config <Core設定引用>
tests/g2/measure/cold-login.sh --state rescue|no-agent|agent-warm|active
```

這些為待實作CLI形狀，不傳rawkey。每PR跑確定性／mock／schema tests；reference nightly跑授權／故障／桌面回歸；真模型全集在M2、候選出口與model更新時跑，CI provider配額與secrets由受控環境提供。PR fork不取得key；沒配額列skipped而非pass。真模型費用有budget，不能無界自動重試。

建議出口同commit三次獨立reference回歸加一次完整fixed＋holdout；此為G2加嚴提案，與D-38留下的G1五晚追蹤分開，未核定前不以它降低上位要求。保護設定受帳號403限制時附CIrun與review證據，保留owner追蹤，不擅自更改visibility或升級方案。

## 7. Artifact 與評審格式

每run存`manifest.json`、`results.json`、`report.md`和raw measurements／脫敏traces。manifest必填commit／dirty tree、suite與task/oracle version、硬體軟體／model/provider fingerprint、settings/catalog revision、日期時區、PID/cgroup、sample window、exclusion、limitations。results逐case有expected／observed／判定與證據路徑；退出碼按fail／incomplete區分，不能用pending-ok算出口pass。

出口artifact目錄提案`artifacts/g2/<run-id>/`；私人內容與密鑰掃描後再上傳。評審新增`.agents/notes/gate-reviews/G2-exit.md`，列十九項門檻、未達標與提案、決策日期、G3估算／風險。沒有執行過的數據不填示例數字當結果。
