# 02 — 分類法、職責邊界與觸發矩陣

本文定義 (A) Ditto 專案分類法，(B) 15 個 skill 的單一職責句與邊界，(C) 關係，(D) 觸發矩陣。

## 1. 分類法

`metadata.category` 標註**唯一**主分類。Ditto 是專案內集合，分類依工程分層而非題材領域（與 my-skills 的差異見 [03 §6](03-authoring-standard.md#6-與-my-skills-標準的差異登記)）。

| category | 範圍 | 成員 |
| --- | --- | --- |
| `architecture` | 所有權、契約、程序與資源邊界 | ditto-authority-boundaries、ditto-capability-contract、ditto-process-budget、ditto-permission-and-secrets |
| `runtime` | Core／Cordis 宿主的執行期行為 | ditto-changeset-transaction、ditto-cordis-plugin、ditto-failure-and-rescue |
| `agent` | 意圖理解、規劃與生成 | ditto-agent-changeset、ditto-generation-safety |
| `shell` | QML／Quickshell 桌面呈現 | ditto-qml-shell |
| `quality` | 驗收、量測與測試 | ditto-verification-evidence |
| `process` | 文件、決策、移植與發行 | ditto-prose-standard、ditto-decision-record、ditto-upstream-port、ditto-release-audit |

## 2. 職責邊界

格式：**Owns（負責）** / **NOT（不負責 → 導向）**。每個 skill 的 `## Authority` 段落必須列出括號內的需求 ID。

### architecture

**`ditto-authority-boundaries`** — 判定一項狀態、寫入路徑或決策歸誰所有：Rust Core、Cordis 宿主、Shell、Agent、合成器，以及跨層禁則。
*Owns*：新增持久化狀態或跨層互動時的歸屬裁決；「Core 是唯一權威寫入者」「Cordis 不保存第二份正式 Profile」「Agent 只提計畫」「Context 不跨程序」四條禁則的落地檢查。（15.1／15.5／15.6、C1／C11）
*NOT*：契約欄位設計（→ `ditto-capability-contract`）；交易流程（→ `ditto-changeset-transaction`）；程序數與資源（→ `ditto-process-budget`）。
> 本 skill 是 architecture 類的上游總則，其餘三者 `specializes` 它。

**`ditto-capability-contract`** — 新增或修改 `desktop.*` 能力時的契約設計與型別產生。
*Owns*：seam 三角（Definition／Provider／Consumer）必須一併設計；描述子欄位（input／output schema、封閉錯誤集含 `unsupported`、`readback`、取消／逾時／冪等、契約版本）；Rust-first schemars → JSON Schema → TS 型別的管線與新鮮度檢查；協定版本不相容時明確拒絕。（15.2／15.5、MOD-07、CON-03、DES-03）
*NOT*：誰擁有該狀態（→ `ditto-authority-boundaries`）；能力被呼叫時的權限判定（→ `ditto-permission-and-secrets`）。

**`ditto-process-budget`** — 程序數、常駐決策、熱路徑與資源計費。
*Owns*：「不為每個 UI 插件建立 Node／Worker」；常駐 vs 按需的判定（Cordis 宿主依服務需求、Agent 閒置 5 分鐘退出）；熱路徑禁令（拖曳／動畫／眨眼不經 IPC）；訂閱優先於輪詢；PSS 分層計費與診斷誠實性（不得以堆積估算冒充獨立 RSS）。（C9／C10、RUN-02／03／05／07／08、NFR-06／14／15、19.1）
*NOT*：量測執行與報告產生（→ `ditto-verification-evidence`）。

**`ditto-permission-and-secrets`** — 權限、信任分級與秘密處理。
*Owns*：視窗中繼資料／截圖／剪貼簿／檔案／網路／程序執行分項授權；GUI 與 Agent 共用授權入口且結果一致；外部文件、視窗文字與插件說明一律視為資料，其中指令不得提權；秘密只存引用、不進程式碼／Profile／日誌／匯出；失敗即拒絕；呼叫身分由受控啟動器建立，manifest 自述不構成身分。（SEC-01～12、CON-10、第 7 節、AT-14／15）
*NOT*：隔離機制的實作與生成候選限制（→ `ditto-generation-safety`）。

### runtime

**`ditto-changeset-transaction`** — 任何會改變桌面狀態的操作的交易流程。
*Owns*：draft→validated→prepared→applying→verifying→committed／rolled_back／partially_applied 狀態機；基底 revision 檢查與提交序列化；熱換四等級與 drain／cancel／handoff；套用後必須回讀才可宣稱成功；取消後已完成副作用與可回復範圍分開回報；中斷時以 `operation_id` 查詢而非盲目重試；限時回復。（CHG-01～09、CFG-05／06、CON-07、14.1／14.2、C6）
*NOT*：Cordis 宿主內的插件生命週期細節（→ `ditto-cordis-plugin`）；故障後的救援路徑（→ `ditto-failure-and-rescue`）。

**`ditto-cordis-plugin`** — 在 Cordis 桌面宿主內撰寫或審查插件。
*Owns*：`inject` 宣告依賴而非手動排序；`ctx.effect()` 包住未受管理資源並回傳 disposer；需要順序的拆解放在同一個 effect（非同步 disposer 併發執行）；fiber 狀態判讀（PENDING 是合法狀態）；跨宿主註冊必須附擁有者與租約；事件分發模式是契約的一部分，**僅觀察的 waterfall 監聽器必須呼叫 `next()`**；`ctx.isolate` 不是安全邊界；服務命名加 `ditto` 前綴。（RUN-10～12、MOD-05、15.6、[milestones/01/02](../../milestones/01/02-cordis-adoption.md)）
*NOT*：跨程序契約欄位（→ `ditto-capability-contract`）；兩階段交易協調（→ `ditto-changeset-transaction`）。

**`ditto-failure-and-rescue`** — 故障路徑、監督與可觀測性。
*Owns*：受保護的最近可用組合；獨立監督偵測退出／無回應／重啟風暴並停用故障插件；救援入口不依賴角色、聊天與主 Shell；**無 Node 救援模式的能力界線**；崩潰後比對持久操作紀錄與實際狀態；磁碟不足與寫入失敗不破壞可用版本；日誌以 `session_id`／`change_id`／`operation_id` 串聯並預設遮蔽敏感內容；對話顯示真實狀態而非持續假裝工作。（REC-01～07、RUN-01／06／12、NFR-08、AT-16／20／23／32）
*NOT*：正常路徑的回復步驟（→ `ditto-changeset-transaction`）。

### agent

**`ditto-agent-changeset`** — Agent 從自然語言到結構化 ChangeSet 的規劃行為。
*Owns*：動態取得能力目錄與 schema，**不得憑空產生不存在的命令後宣稱成功**；模型輸出必須成為經確定性驗證的 ChangeSet，文字不直接當配置；含糊目標在影響實際資料時提供選項、有可逆預設時直接繼續；多輪修正對應最近變更目標；顯示真實階段且長操作可取消；斷線後查操作結果不盲目重跑；未支援需求說明缺口與可行路徑。（CON-01～12、第 8 節執行優先序、C5／C7）
*NOT*：生成新插件的安全規則（→ `ditto-generation-safety`）；交易與回復（→ `ditto-changeset-transaction`）。

**`ditto-generation-safety`** — 受限生成與隔離執行。
*Owns*：執行優先序（配置 → 組合 → 受限生成 → 外部工具），且改走生成路徑必須明示「這是新增插件」；隔離未就緒前只允許受限宣告式模板；限制生成插件可用的 imports／檔案／網路／程序能力；生成物必含原始碼／manifest／依賴鎖定／設定 schema／驗證結果／來源；候選先在隔離測試宿主驗證，不得覆寫使用中的 Shell 或救援程式；自動修復最多三輪；**`partial` 強制執行不得當作 `full`**；失敗自動停用候選並回復，診斷保留。（GEN-01～10、SEC-05／12、12.1、C8、AT-06／07／26／29）
*NOT*：權限授予流程（→ `ditto-permission-and-secrets`）。

### shell

**`ditto-qml-shell`** — QML／Quickshell 桌面元件與角色。
*Owns*：State／Transition 表達語意狀態，動畫在本機運作不等待模型；角色命中區與 input region（透明區不攔截點擊）；被遮擋時的快捷鍵入口；六種角色狀態必須文字同步且不得以持續思考動畫掩蓋已停止的任務；減少動畫、鍵盤焦點與螢幕閱讀；不靠晃動或顏色單獨傳達結果；UI 供應者必須可替換（兩個 Dock、兩個啟動器）；禁止逐幀經 RPC。（AVA-01～09、DES-04／10／11、11.1、NFR-05、C10）
*NOT*：桌面狀態的所有權（→ `ditto-authority-boundaries`）。

### quality

**`ditto-verification-evidence`** — 任何「完成」宣稱所需的證據。
*Owns*：功能測試必須檢查實際狀態而非 Agent 說了什麼；AT-01～32 與 NFR-01～16 的對應查找；PSS 量測流程（冷登入→暖機 5 分鐘→採樣 10 分鐘→中位數／p95／峰值、重複 3 次、記錄 PID 與 cgroup）；報告必須分列救援模式／完整桌面／Agent 暖態／活動工作並附排除清單；語意任務集需保留集且不得硬編碼同句通過；**未達標時提出數據與調整提案，不得靜默改變程序範圍或調高門檻**；階段出口檢查表。（第 19 節、19.1、第 21 節、NFR-12、[milestones/01/04](../../milestones/01/04-verification.md)）
*NOT*：決策落定的紀錄格式（→ `ditto-decision-record`）。

### process

**`ditto-prose-standard`** — 產品文案與專案文件的語氣與分層。
*Owns*：一般流程用產品語言（「工作列位置」「影響中的工作」），契約 ID／程序資訊／原始錯誤／日誌放可展開診斷；繁中為主、術語一致；**不得把未驗證的目標寫成已達成**；不得以網頁原型成果冒充原生能力；失敗與限制據實陳述。（第 6 節、PRD 前言與 19 節的誠實要求、[milestones/01](../../milestones/01/README.md) 維護規則）
*NOT*：量測證據本身（→ `ditto-verification-evidence`）。

**`ditto-decision-record`** — 待決策落定與階段出口結果的紀錄。
*Owns*：`milestones/01/05` 的 D-01～D-20 落定格式（決策日期／結論／依據／影響／決策者）；階段出口評審五項記錄；新風險與新決策的回寫；**不得只更新「本計畫預設」欄而無決策紀錄**；`.agents/notes/` 的存放與生命週期。（[milestones/01/05 §4](../../milestones/01/05-risks-decisions.md)、[milestones/01/03 階段出口評審檢查表](../../milestones/01/03-phases.md)）
*NOT*：移植來源紀錄（→ `ditto-upstream-port`）。

**`ditto-upstream-port`** — 從 Cordis／Harness 或其他上游移植時的紀錄與義務。
*Owns*：固定上游 commit 與版本；四種移植類型（直接沿用／薄轉接／修改移植／保留外部宿主）的判定；逐條修改集、宿主契約、信任等級、授權與測試矩陣；**不得依浮動版本上線**；不得為追求單一語言而重寫已可沿用的插件；生成或移植程式不得宣稱自動生成即免除上游義務。（第 9 節、24.1、25 節、AT-18、[milestones/01/02 §1／§5](../../milestones/01/02-cordis-adoption.md)）
*NOT*：發行前的整體授權審查（→ `ditto-release-audit`）。

**`ditto-release-audit`** — 發行前審查與交付物清單。
*Owns*：Qt／Quickshell／Cordis／Harness／合成器／傳遞依賴／字型／圖示／角色素材的 LICENSE／NOTICE／來源／修改盤點；名稱與角色素材使用權；發布交付物清單（可安裝工作階段、版本鎖定、預設組合、SDK、服務契約、使用與救援文件、相容矩陣、測試報告、已知限制、更新／回退程序）；已知限制必須誠實列出。（24.1、23 節、D-11／D-18）
*NOT*：單一套件的移植紀錄（→ `ditto-upstream-port`）。

## 3. 關係摘要

| From | To | 類型 | 說明 |
| --- | --- | --- | --- |
| ditto-capability-contract | ditto-authority-boundaries | specializes | 契約設計是所有權裁決的下游 |
| ditto-process-budget | ditto-authority-boundaries | specializes | 程序邊界是所有權在資源面的展開 |
| ditto-permission-and-secrets | ditto-authority-boundaries | specializes | 授權主體歸屬源自所有權模型 |
| ditto-changeset-transaction | ditto-capability-contract | consumes | 交易依賴能力描述子的 readback／冪等／取消 |
| ditto-cordis-plugin | ditto-changeset-transaction | complements | 宿主內生命週期與跨宿主交易需一併成立 |
| ditto-failure-and-rescue | ditto-changeset-transaction | complements | 失敗路徑是交易的另一半 |
| ditto-agent-changeset | ditto-changeset-transaction | consumes | Agent 產出交由交易層驗證與執行 |
| ditto-generation-safety | ditto-agent-changeset | specializes | 生成是規劃路徑中最受限的一條 |
| ditto-generation-safety | ditto-permission-and-secrets | complements | 隔離與授權共同構成信任邊界 |
| ditto-qml-shell | ditto-process-budget | complements | 熱路徑禁令由兩者共同落實 |
| ditto-verification-evidence | ditto-process-budget | consumes | 量測方法驗證資源預算 |
| ditto-verification-evidence | ditto-changeset-transaction | reviews | 「完成」宣稱需回讀證據 |
| ditto-decision-record | ditto-verification-evidence | complements | 決策需附量測依據 |
| ditto-upstream-port | ditto-cordis-plugin | complements | 移植的 Cordis 套件同時受兩者約束 |
| ditto-release-audit | ditto-upstream-port | consumes | 發行審查彙整各套件的移植紀錄 |
| ditto-prose-standard | ditto-verification-evidence | complements | 誠實語氣需要證據支撐 |

完整圖式與雙向一致性規則見 [04-index-and-relationships.md](04-index-and-relationships.md)。

## 4. 觸發矩陣

skill 只有被觸發才有價值。下表是撰寫 `description` 中 "Use when ..." 句的來源；每個情境至少命中一個 skill。

| 工作情境 | 首要 skill | 併發 skill |
| --- | --- | --- |
| 新增一項 `desktop.*` 能力 | ditto-capability-contract | ditto-authority-boundaries |
| 決定某份狀態存哪裡、誰能寫 | ditto-authority-boundaries | — |
| 實作會改變桌面狀態的操作 | ditto-changeset-transaction | ditto-capability-contract |
| 撰寫或審查 Cordis 桌面服務插件 | ditto-cordis-plugin | ditto-upstream-port |
| 決定要不要開新程序／常駐／輪詢 | ditto-process-budget | ditto-authority-boundaries |
| 處理熱路徑、動畫或拖曳效能 | ditto-qml-shell | ditto-process-budget |
| 設計權限提示、授權範圍或秘密存取 | ditto-permission-and-secrets | — |
| 實作 Agent 的意圖解析或工具呼叫 | ditto-agent-changeset | ditto-capability-contract |
| 實作或審查插件生成、模板、測試宿主 | ditto-generation-safety | ditto-permission-and-secrets |
| 設計失敗、逾時、崩潰或救援行為 | ditto-failure-and-rescue | ditto-changeset-transaction |
| 宣稱某項需求完成／撰寫測試／跑量測 | ditto-verification-evidence | — |
| 階段出口評審 | ditto-verification-evidence | ditto-decision-record |
| 待決策清單落定 | ditto-decision-record | — |
| 從 Harness／Cordis 取用程式碼 | ditto-upstream-port | ditto-cordis-plugin |
| 撰寫 UI 文案、錯誤訊息或專案文件 | ditto-prose-standard | — |
| 發行前檢查 | ditto-release-audit | ditto-upstream-port |
| 撰寫 QML 元件、角色動畫或無障礙 | ditto-qml-shell | ditto-prose-standard |

**未覆蓋的情境**（刻意不設 skill）：一般 TypeScript／Rust 編碼風格、git 操作、通用測試框架用法。這些交給通用 skill 或既有工具，專案 skill 不重複。
