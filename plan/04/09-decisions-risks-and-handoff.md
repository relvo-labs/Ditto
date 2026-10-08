# 09｜決策、風險與 G3 交接

必讀：`ditto-decision-record`、`ditto-verification-evidence`、`ditto-upstream-port`、`ditto-prose-standard`。本文件記錄提案，沒有將選型或新門檻冒充owner已裁定。

## 1. 既有決策與新增提案

| ID | G2所需結論／預設提案 | 最晚點／責任角色 | 未決影響 |
| --- | --- | --- | --- |
| D-05 | pin Harness三類取用與支援閉包；受限tools port、Core persistence、移除local writers | M0／AGENT＋CORE | 移植不能freeze與發行，spike可做 |
| D-09 | **部分已決 D-09a**：必要且優先支援 Codex 個人訂閱＋app-server；普通 API 後端可替換。尚待 model／effort、可用配額、keyring 與 usage probe，詳見 [10](10-codex-app-server.md) | M1 真請求前／AGENT＋CORE＋owner | 訂閱方向不用再確認；連線／工具限制尚未實證，mock 不替代 |
| D-20 | 固定model/task/adapter/prompt/catalog fingerprint與保留集；alias無immutable版本的限制明記 | M2語意基線前／QA＋AGENT | 成功率無可比性，不能出口 |
| D-06a | Core／Shell PSS提案待owner核定，沿用PRD80／250MiB直到裁定 | M4量測評審／owner＋QA | 不阻擋前期接線，不得自改預算 |
| D-06b | 已核定三類cgroup初始配額與最多2重工，G2沿用短工具／建置分類 | 已決；CORE＋PLAT執行 | 配額不足需要實測新決策，不能共用大額 |
| D-12 | 具名owner、reference runner使用窗、provider配額與工程投入 | M0排程／owner | 沒有可承諾曆時，工作包仍可順序執行 |
| D-39 | **新增待決**：G2 wire 0.3、closed reasons／topics、單Agent世代、activity、approval payload綁定、限額與timeout；相容矩陣先行 | M0契約freeze／CORE＋AGENT＋SHELL | 跨程序正式實現阻擋；單元spike可做 |
| D-40 | **新增待決**：Wayfire可保存布局表示；floating normalized regions或實測有readback的tile ratio，selector／容差／窗口新建policy | M1後、跨三類前／PLAT＋CORE | AT-02／03不可用一次window腳本代替 |
| D-41 | **新增待決**：conversation event格式、Core檔案＋SQLite索引、durability、retention／刪除、AI prefs revision與privacy | CORE-07／08遷移前／CORE＋AGENT＋owner | 會話不能持久；不准Agent自行寫檔 |
| D-42 | **新增待決**：44工作包／125人週增補（原缺口33＋Codex8）、實際容量／AI協作速度／週序與加嚴出口 | M0初估、M1校正／owner＋各flow owner | 84人週仍是上位建議，不承諾12週 |
| D-43 | **新增待決**：保留集50題、同≥90%且較固定集下降≤5pp；G2驗收重複run提案 | M2語意評分前／QA＋AGENT＋owner | 先報raw比較；未核定不能宣稱「不明顯下跌」 |
| D-44 | **Codex 新增待決**：≤1 controller＋≤1 app-server 的實際程序架構、OS 工具／keyring 最小邊界與整組 cgroup hard limit；暖態 PSS 仍合計≤150MiB | M0 probe、M1 可寫之前／CORE＋PLAT＋AGENT＋owner | app-server 接入方向已決；未默認改 RUN-02 或放寬 PSS，限制不成立則拒絕桌面写入 |

D-39～44 是本計畫新增待決編號，回寫 milestones/01/05 為提案；定案才在`.agents/notes/decisions/`建立帶日期紀錄與連結。D-09a 已有 [使用者方向決策](../../.agents/notes/decisions/2026-10-07-d09a-codex-subscription-app-server.md)，不包含模型／數字或實測結果核定。routine code choice 可由工作包 owner 自行落地；只有改權威契約、門檻／預算或長期選型才用此流程。這份計畫完成不需把所有提案先裁定，正式實作依各最晚點處理。

### 1.1 待確認項目的實際意義與建議

以下是建議，尚未由 owner 接受成為全部決策。工程選型先做可重現探測，再提供具體結果評審；使用者不必逐項挑函式庫或先批准所有細節。

| 項目 | 為什麼需要決定 | 建議與實際影響 |
| --- | --- | --- |
| D-05：Harness 取用 | app-server 已管理模型 turn，整套 Harness app 搬入會重複執行並帶進檔案／shell 工具 | 取模型共用契約、工具調度、Session／persistence 所需最小閉包；Codex bridge 明列新後端，按實際路徑證明移植，先不搬 CLI、生成沙箱與本機設定 writer |
| D-09 剩餘：模型與額度 | 訂閱登入方向已定，帳號實際可用的 model／effort、quota、keyring 仍未知 | 登入後讀模型清單並做真請求，選一組穩定預設；達限保留對話、顯示 reset 時間，不自動改成 API 或購買額度。token 只作可觀測使用量，沒有硬限制能力就明示 |
| D-39：協定與確認 | 新聊天／授權事件可能令舊 Core、Shell、hostd client 解碼失敗；晚到的同意不能用在新任務 | 0.3 協定與 clients 一起升級，舊 wire 明確拒絕；既有範圍的可逆配置直接套用並可撤銷，讀私人資料／上傳等新增範圍才問一次，綁具體任務和資料，過期拒絕 |
| D-40：布局 | 目前可存工作區規則，尚不能保存並回讀「左專案、右終端」與「再窄一點」 | 先 probe 已有浮動窗口的移動／縮放，若成立，以工作區可用面積的比例區域保存；後開視窗亦可套用，手動移動不持續被拉回。這不等於完整自動平鋪樹；tile ratio 只有實際可寫／可讀／可復原才採用 |
| D-41：聊天保存／刪除 | 聊天不是 Profile；桌面變更成功後，即使 Agent crash 仍要知道已做過，避免重做 | Core 寫事件檔、SQLite 做可重建索引，工具執行前先持久保存；預設保存至使用者刪除、原始私人上下文不另存。刪聊天保留已套用配置；偏好另有 revision。日後要自動30天清除或保存附件，再調保留政策 |
| D-12／42：責任與工期 | 原文件按傳統多人團隊估算，缺目前 owner＋AI 的真實交付速度與每日投入 | 保留44包作完整範圍追蹤；125人週僅是尚未校正的估算，不能換算成現在的交付承諾。先完成登入→改一筆→回讀→撤銷的 M1，用實際 PR 工時／問題重估下一段，按完成點推進 |
| D-20：可比較測試 | 改模型、effort、prompt 或工具後，同一題分數可能改變；模型 alias 也可能在伺服器更新 | 固定 CLI／schema、選定模型／effort、prompt／catalog／任務版本與測試時間；只能記錄而無法鎖死的服務端版本明示限制，更新後重跑，不宣稱「永久固定模型」 |
| D-43：自然語言驗收 | 只過示範句不能證明其他措辭與多輪可用 | 原固定50題至少45題成功保留；另提保留50題也至少45題，較固定集降幅≤5百分點（每題2點，實際最多少2題）。成功按桌面回讀評分；無授權副作用等安全禁止事項逐例全數成立，不以90%平均掩蓋 |
| D-06a：Core／Shell 預算 | 既有40／230MiB比 PRD80／250MiB更嚴，前階段有數據但未核定 | 先沿用80／250及產品總預算，G2 同參考機重測後再裁定是否採更嚴值；不是為加入 Codex 就提高預算 |
| D-44：Codex 程序與限制 | 多了一個 Rust 程序，且需 keyring／登入網路與禁止 Codex 內建桌面旁路同時成立 | 按需啟動1 controller＋至多1 app-server，無活動5分鐘後整組10秒內回收；暖態合計≤150MiB，分列每 PID。先 probe OS／有效工具與 PSS，正式程序架構回寫權威文件，未達標附數據再取捨 |

D-06b 已定的短工具／建置／測試宿主配額不在本輪重新開放。D-38 的 G0／G1 接受完成也不重新詢問。Codex 登入所需本人互動留到實作登入流程時，本計畫不讀現有憑證或代登入。

## 2. 回饋登記與處理邊界

| 編號 | 來源矛盾／缺口 | 暫行處理 | 回寫規则 |
| --- | --- | --- | --- |
| F2-01 | milestones/01/03 G2出口未列AT-15／21，但04矩陣指定G2 | 本計畫EX2-09／10取較嚴者 | 原階段出口保留；產品裁定後才能新增權威checkbox |
| F2-02 | 03「六態」與PRD七個列項不符 | 以PRD七態實作 | 登記plan/01回饋；沒有聲稱刪除某態 |
| F2-03～07 | Core會話、設定、durable barrier、原生提供方、layout、CI與privacy有實作缺口 | 新工作包與33人週提案 | D-42裁定後改上位估算；不回填為已實作 |
| F2-08 | NFR-12出口「量測完成／附調整」可能被誤讀為未達90%也通過 | 達標或有另行明確owner接受決策；保留集差距D-43 | 不自裁放寬，評審記raw與待決 |
| F2-09 | 使用者要求 Codex app-server；新增實際程序與不同認證／turn 執行模型 | D-09a 方向已決；10 詳列 bridge／keyring／ephemeral thread 與工具限制，增3包／8人週提案 | D-44 實測後回寫架構／程序表；D-42 重估，不假冒沿用單程序或上游 ctx.llm 原樣實作 |

完整回饋也列在 [plan/01/05](../01/05-authoring-roadmap.md#回饋紀錄)，不在skill或程式碼裡悄悄解決權威矛盾。D-38留下的G0／G1追蹤沿原清單維護；本計畫只接入 [01§2](01-scope-and-exit-criteria.md#2-開工條件與前階段追蹤)列出的G2依賴。

## 3. 風險與退出路徑

| 風險 | 早期訊號 | 控制／回退 |
| --- | --- | --- |
| Harness依賴閉包過大或run_code可達 | entry import就需要sandbox／fs／home／appboot | M0裁剪port與契約測试，不整包載入app；三類來源仍保留 |
| 同步Session事件被誤當durable | crash後已執行tool但找不到intent／correlation | AGENT-13與Core接受關聯；flush失敗停止新副作用 |
| layout存得下但compositor實際不照做 | ratio無回讀／tiler覆寫floating幾何 | reference spike、顯式策略／region語意、readback與rollback |
| 模型同句通過、真正多輪失效 | fixed高分而holdout／中文／untouchedhash失败 | task oracle、不同措辭、版本pin、禁止規則特例 |
| approval被Agent或外部資料偽造 | 自述caller或late answer也能授權 | Core launcher identity、intent hash、一次CAS／expiry，fail-closed |
| context誤持續監控或傳錯provider | panel關閉仍capture／新endpoint拿舊token | 有界一次snapshot、read/upload分開、provider/turn綁定與revoke |
| secret經SDK錯誤／CIartifact外洩 | canary在journal、requestdump、export出現 | adapter脱敏、private通道、掃描productionlog與上传前artifact |
| 5min回收race丟新訊息／重開兩Agent | drain與submit同時發生，writer有兩世代 | Core先queue、原子世代、flush退出後再開；正常時鐘測试 |
| job quota或cancel只在JS層 | OOM牽連桌面／pids残留／第三job仍running | D-06b cgroup實證、Core全產品admission、exit確認 |
| UI串流和history佔滿Shell | 隱藏仍布局／長會話PSS上升 | boundedbatch／bytecap／分頁、snapshot恢復、100次壓力 |
| Agent暖態或cold delay超標 | SDK閉包過大、init網路阻塞 | 按需import／ready先行、資料限額；不得永久常駐遮掩 |
| 人力或模型配額不足 | W1無owner／M1無真请求artifact | 工作按依賴順序交付，更新D-42，mock結果與正式門檻分列 |
| Codex builtins／個人設定繞過 Core | shell、apply_patch、MCP／hooks 或第二 Agent 可達；read-only 仍讀完整家目錄 | 專用 state／設定、有效工具清單與 OS 正反測試；無法限制則不啟用桌面寫入，不靠 prompt 保證 |
| Codex 第二份會話／認證外洩 | rollout／cache 含私人上下文；登入橋接傳 raw token | ephemeral thread、Core 歷史重建、官方 managed login＋keyring、production cache／log 掃描；不使用 internal-only auth／resume history |
| Codex 額外程序超預算或 API 誤扣費 | controller 好看但 app-server 未計；quota 耗盡自動換後端 | 整組150MiB／每PID分列、退出確認、quota 與缺資料明示、無自動 API／購買 |

## 4. Draft skills 核對

AGENT-05／06／10完成後核對`ditto-agent-changeset`的實際API與readback；CORE-02～04完成後核對`ditto-permission-and-secrets`的approval／身份／credential形狀；CORE-01／10與QA-04完成後核對`ditto-failure-and-rescue`的監督與reconnect。涉及G1 Cordis／QML／transaction的draft標記依實際已有實作審查，不因G2開始直接改stable。仍屬G3的generation-safety隔離條目保持draft。

核對包含Authority與實際source、觸發描述、calibrated examples、測試證據與lint；只有相應契約確定後才改狀態，並由DOC-01記錄。

## 5. 出口與 G3 交接

DOC-01建立G2-exit評審，引用 [01十九項門檻](01-scope-and-exit-criteria.md#3-十九項出口)、[07artifact格式](07-verification-and-measurement.md#7-artifact-與評審格式)，列版本、個別結果、未達數據、決策／接受條件、下一階段估算。M5不能只寫「聊天已可用」。

| G3需要的底座 | G2交接證據 | 缺失處理 |
| --- | --- | --- |
| intent→ChangeSet→驗證／readback／rollback | 真模型跨3類與多輪、操作correlation、lostack恢復 | 不允許生成旁路配置 |
| 共用授權、秘密refs與上下文最小化 | 四approval結果、resource revoke、canary與injection測试 | 生成入口不擴張未驗證scope |
| durable sessions、job／cancel／deadline／OS配額 | 三類移植、Core持久屏障、global pool與OOMartifact | worker limits不能冒充G3安全sandbox |
| Agent與hostd獨立、no-Node rescue | AT-24／28與G1 AT-23／30～32回歸 | 不把桌面服務搬入生成Agent |
| 契約版本與可重建依賴 | schema新鮮度、port manifest／licences、installedartifact指紋 | G3在同格式演進、不可浮動更新 |
| 資源／延遲與未完成追蹤 | 四state冷登入、semantic與UIlatency、D-38剩餘狀態 | G3沿用有效門檻與原始警訊 |

G3另行實作generation artifacts、隔離testhost、import／file／network／process強制邊界、修復預算與啟用rollback；G2的可信worker成功不批准自由QML／Node／native候選進主Shell或Core。G2完成後README／milestones更新為實際結果，並附G3計畫，不用本提案文字預填「所有P0完成」。
