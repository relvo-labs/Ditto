# 00｜研究結論：PRD、原型與 Cordis 底座

本文記錄計畫成立前的三方調查結果，是後續所有設計取捨的依據。每項結論都標註來源，可被重新查核。

## 1. 調查範圍

| 對象 | 實際閱讀內容 |
| --- | --- |
| Ditto PRD v0.4.0 | 全文 26 節、116 項需求、32 組驗收情境、G0～G5 門檻、19.1 分層記憶體預算 |
| 研究與互動決策 | `docs/research/RESEARCH-AND-INTERACTION.md` 全文：四項研究結論、參考形象對應、真實／模擬邊界、Qt Quick 移植接點 |
| 前端原型 | `apps/desktop-prototype/`：`engine.mjs`（能力目錄、配置 schema、規則解析、diff、validate、preset）、`app.js`（preview／apply／undo／history／profile）、`index.html`、8 項測試 |
| deepseek-harness | `docs/architecture.zh.md`、`docs/cordis-primer.zh.md`、`docs/cordis-tutorial/`（7 章全文）、`vendor/README.md`（21 項本地修改集）、`vendor/cordis/src/`、`packages/bundle/*/cordis.patch.yml`、`packages/boot/{app-boot,plugin-manager}`、`packages/sdk/`、`docs/subsystems/{approval,jobs,sandbox,credentials,settings}.zh.md`、`apps/desktop/`、`native/system/docs/architecture.md` |

## 2. PRD 的硬性約束

以下 12 條是計畫排序的實際限制條件，違反任一條都會讓後續交付需要重做。

| # | 約束 | 來源 | 對計畫的影響 |
| --- | --- | --- | --- |
| C1 | Rust Core 是配置 revision、權限授予、能力綁定與 ChangeSet／Operation 的唯一權威寫入者 | 15.5 | Cordis 與 Agent 都不得持久化正式配置；Profile 儲存必須先於插件宿主完成 |
| C2 | Cordis 是**主要**插件組合模型與實際桌面服務宿主，不是 Agent 內部實作 | 1.1、15.1 | G1 必須交付至少兩個非 AI Cordis 服務插件（RUN-10），不能以文件參考或空殼宿主驗收 |
| C3 | Agent 按需啟動、閒置 5 分鐘退出；其退出不得連帶關閉有活動服務的 Cordis 宿主 | RUN-03 | 生命週期監督責任在 Core，不在 Agent；兩者需分別計費、分別量測 |
| C4 | 無 Node 救援模式只保證「原生應用基本操作、讀取歷史、切回最近可用配置」 | RUN-01、AT-23 | 救援路徑不得依賴 Node；`dittoctl` 與監督須為原生實作 |
| C5 | 模型產生結構化 ChangeSet，經確定性驗證後才執行；自然語言不直接當權威配置 | CON-05 | 能力 schema 與驗證器必須先於 Agent 接入（G1 先於 G2） |
| C6 | 完成判斷依系統回讀，結果分為成功／失敗／部分完成／結果未知 | CON-07、CHG-04 | 每個能力操作都要有回讀路徑；沒有回讀能力的操作不得宣稱成功 |
| C7 | 執行優先序：宣告式配置 → 組合現有能力 → 生成受限插件 → 新增受控外部工具 | 第 8 節 | 生成路徑是最後手段，且必須明示「這是新增插件」 |
| C8 | 隔離未建立前只允許受限宣告式模板輸出；不得直接載入任意原生動態庫 | GEN-04、SEC-12 | 沙箱基礎設施必須先於生成能力（G3 內部順序固定） |
| C9 | 一般需求不得要求重新編譯 Rust 核心、重啟整個桌面或常駐新 Node 程序 | 第 8 節 | 位置／主題／面板實例必須走配置層；程序預算是設計約束不是優化項 |
| C10 | 拖曳、動畫、眨眼與一般畫面更新留在 QML／合成器，禁止逐幀經 Node、LLM 或 Rust RPC | 15.3 | 角色動畫與視窗互動不進 IPC 熱路徑；狀態訂閱只傳語意狀態與有界增量 |
| C11 | 跨程序採資料化契約，不傳遞任意函式或共享 Context 物件 | 15.2、15.6 | Cordis 的 Context 不跨程序；跨宿主註冊需另設租約與撤銷 |
| C12 | 資源預算以 PSS 分層量測，報告須分列救援模式／完整桌面／Agent 暖態 | 19.1、NFR-06 | 量測工具與報告格式是 G0 交付物，不是 G4 的收尾工作 |

### 2.1 被 PRD 明確否定的做法

寫入計畫前已排除：以 Rust 重寫 Cordis、把插件逐一移植為 Rust（15.6）；以 Go plugin 或 C++／Rust 動態 ABI 作通用第三方契約（12.1）；把 `node:vm`、Worker 或 Cordis 依賴注入當作安全沙箱（15.3）；以網頁原型數字取代原生量測（19、G4）；以持續常駐掩蓋 Agent 冷啟動未達標（24.2）。

## 3. 前端原型的可沿用資產

原型已完成完整的瀏覽器互動驗證，價值在於**互動契約**而非實作。

| 原型資產 | 處置 | 理由 |
| --- | --- | --- |
| 變更卡：kind／title／逐項 before→after 差異／footnote | **沿用為 UI 契約**，改由 Core 的 ChangeSet 填值 | 對應 CHG-01 的逐項差異要求；已驗證可理解性 |
| 試看 → 保留／取消三態（`beginPreview`／`applyPlan`／`cancelPreview`） | **沿用為互動語意**，接到 Core 的候選組合與提交／回復 | 對應 14.1 的「依政策預覽或直接套用」 |
| 基底版本檢查（`p.baseRevision !== state.revision` → `superseded`） | **沿用為語意**，移入 Core 的權威檢查 | 對應 CFG-06、CHG-05、AT-10；前端檢查不具權威性 |
| 變更歷史逐步撤銷 + 「請先撤銷較新的變更」 | **沿用為政策**，由 Core 依回復計畫判定 | 對應 CHG-01、REC-01 |
| `engine.mjs` 的 `validate()`：白名單值、必要模組、依賴閉包、數值範圍、元件上限 | **沿用為驗證器形狀**，以 Rust + schema 重寫 | 確定性驗證必須在 Core（C5） |
| `catalog`：id／name／version／deps／category | **沿用為 manifest 欄位起點**，擴充至第 12 節的完整必要語意 | 原型缺 runtime／權限／熱換等級／資源預算等欄位 |
| 四組 preset（soft／dev／focus／present） | **沿用為預設 Profile 內容**，dev 與 present 是 MVP 必交付項（20.1） | — |
| `interpret()` 規則解析器 | **不沿用**，僅保留為 G2 任務集的語料來源 | 研究文件已明示「不能把規則解析器包裝為模型」 |
| localStorage 持久化、瀏覽器內假視窗、示範檔案／終端 | **不沿用** | 原生要求管理真正的 Linux 應用（1.1） |
| 角色素材與分層動畫（呼吸／眨眼／注視／回彈／thinking） | **沿用素材與狀態語意**，以 QML State／Transition 重寫 | AVA-01～04；動畫必須本機運作，不等待模型 |

原型的 8 項測試涵蓋：跨模組組合保留配色、複合意圖、模板具名、未支援需求、無變更、依賴與非法匯入、Profile 快照獨立性、否定式指令。這 8 項是 G2 語意任務集的種子，但必須改寫為不同措辭並擴充至 50 項（NFR-12），且不得硬編碼同句通過。

## 4. Harness 與 Cordis 底座機制

### 4.1 Cordis 的五個機制

來源：`docs/cordis-primer.zh.md`、`docs/cordis-tutorial/01–07`、`vendor/cordis/src/`。

1. **插件是函式或 `Service` 子類**，由 Cordis 以一個 `ctx` 呼叫。無框架啟動碼，插件只描述自己的貢獻。
2. **Context 是服務容器**。服務占據穩定的 `ctx.<key>`；消費方依 key 查找，不 import 實作——這正是 PRD「替換供應者不改消費者」（DES-10、MOD-03）的機制基礎。
3. **`inject` 宣告服務依賴**。插件保持 `PENDING` 直到依賴就緒；載入順序由依賴決定，不由設定檔順序決定。**依賴在載入後仍被追蹤**：供應者消失時消費者一併卸載，供應者恢復後重新載入。
4. **型別化事件有五種分發模式**：`emit`（同步廣播）、`parallel`（並發等待）、`serial`（依序、首個非空值勝出）、`bail`（serial 的同步版）、`waterfall`（環繞中介軟體，可轉換或短路）。分發模式是事件契約的一部分。
5. **註冊是可逆副作用**。`ctx.on()`、`ctx.plugin()`、服務註冊本身就是 effect；未受管理的資源包進 `ctx.effect()` 並回傳 disposer。disposer 依註冊逆序啟動，多個非同步 disposer 併發執行——**需要順序的拆解必須放在同一個 effect 內**。

**Fiber 狀態機**：`PENDING → LOADING → ACTIVE → UNLOADING → DISPOSED`，另有 `FAILED`。`ctx.registry` 可列舉所有 fiber 與狀態——這是 Ditto 插件中心診斷（MOD-01、REC-07）可直接沿用的資料來源。`fiber.dispose()` 會等待所有清理（含非同步 disposer）完成，並遞迴卸載子插件。

### 4.2 Loader／Include 的組合與 patch 分層

Harness 的運行形態是一棵插件樹，由有序疊加的層組成（`docs/architecture.zh.md`、`packages/boot/app-boot/README.zh.md`）：

```
空條目列表
  → 依 profile 宣告順序套用每個 bundle 的 cordis.patch.yml
  → profile 自身的 cordis.patch.yml
  → home 級的 cordis.patch.yml
  → --patch overlay
```

一條 patch 依 `id` 定位條目並**替換其整個 config**（不是合併），或 `insert` 新條目。條目元資料為 `id`／`name`／`config`／`disabled`／`inject`。`!!js` 表達式**只在 `config` 與 `disabled` 內有效**，其餘元資料保持字面值。

這套分層與 Ditto 的 Profile／Bundle／revision 概念高度同構，是最有價值的直接參考。三點必須注意：

- **`id` 是差異的依據**。沒有 `id` 的條目每次讀取都取得新生成 id，任何編輯都會被視為刪除再新增並重新掛載。Ditto 的 ChangeSet 必須為每個條目維持穩定 id。
- **上游 loader 的樹變更是 eager、非交易式的**（`vendor/README.md` 第 8 項：「do not restore previous plugins or options」）。插件啟用失敗可能留下部分套用的樹。**這是 Ditto 必須自建交易層的直接原因**（CHG-02／CHG-04）。
- **Include 的寫回是去抖且可能失敗的**（第 14 項）。Ditto 不採用檔案回寫路徑，配置持久化一律走 Core。

### 4.3 Harness 的 seam 模式

「seam」＝可替換能力，含三個角色：宣告介面的 **Service Definition**、實作的 **Service Provider**、使用的 **Consumer**。新增一項能力意味著三者一併設計。Harness 明言：替換一個提供方就能改變整個產品——例如把檔案系統與子程序提供方指向遠端沙箱，Bash、PTY 與 LSP 一併搬過去。

這正是 PRD 第 4 節 Capability／Provider 的落地形式，Ditto 的 `desktop.*` 能力目錄應按同一三角設計，而非只定義介面。

### 4.4 可直接對應 Ditto 需求的既有子系統

| Harness 子系統 | 機制要點 | 對應 Ditto 需求 | 沿用評估 |
| --- | --- | --- | --- |
| `ctx.tools` + `defineTool` | 作用域化註冊表、參數 schema 推導、`tools/pre-execute`→`execute`→`post-execute` waterfall 流水線 | Agent 工具層、CON-03 能力目錄 | **高**：Ditto 的 `desktop.*` 工具即此註冊表的消費者 |
| `ctx.llm` 適配器 seam | 訊息與串流詞彙、適配器可替換 | 第 9 節模型適配器移植、25 節「一供應者可替換」 | **高**：三類移植之一 |
| `ctx.sessions` + `SessionPersistence`（`create`/`open`/`stat`/`list`/`export`） | 僅追加事件日誌、`deriveMessages()` 投影、JSONL generation 遷移、「模型可見即已記錄」不變量 | 會話儲存服務與 Agent 程序分離（第 13 節）、CON-09、RUN-04 | **高**：實作 Core-backed `SessionPersistence` 提供方即可滿足「Agent 退出後仍可查閱」 |
| `ctx.approval`（`approval/request` waterfall、`allowed-once`/`rejected`/`cancelled`/`unavailable`、`ask`/`never` 政策、失敗即拒絕） | 分發前套用會話政策、審計事件對 | SEC-02 共用授權入口、CON-10 風險分級確認 | **高**：語意與 Ditto 權限模型吻合；應答者改由 QML UI 提供 |
| `ctx.jobs`（`JobId = <kind>-N`、running/stopping/completed/killed/failed、預檢後才提交註冊） | 長任務身分、存取控制、生命週期歸運行時，執行資源歸生產方 | `desktop.jobs`、CON-06 取消、RUN-05 重型工作上限 | **高**：job kind 擴充為 `plugin-build`／`plugin-install`／`generation` |
| `ctx.credentials`（引用為環境變數名，值歸提供方，每次操作重新解析） | 秘密不進配置；輪換即時生效 | SEC-07、CFG-03 匯出不含秘密、5.1 金鑰存入秘密儲存 | **高**：新增 Secret Service／keyring 提供方 |
| `ctx.settings`（namespace 分節，schema 預設 → 註冊方 base → 使用者分節） | 使用者可編輯子集與組合配置分離 | 個人化設定介面、CFG-05 手動修改 | **中**：需改為 Core-backed 提供方，寫入即產生 revision |
| `ctx.sandbox` + `sandbox-local`（Linux bwrap／Landlock；`read-only`／`workspace-write`／`danger-full-access`；`full`／`partial` 強制執行回報） | 包裝 argv 而不耦合平台 | SEC-12、GEN-04、AT-26 | **高**：Ditto 測試宿主與生成候選的隔離基礎 |
| `native/system`（`landlock-run` 靜態 musl 執行檔、stable Node-API flock 綁定） | 自我施加限制後才 exec；無法強制執行即拒絕 exec | SEC-12「超限終止候選而非整個桌面」 | **高**：可直接取用的既有原生機制 |
| `ctx.commands` | 不需模型輪次即可分派的使用者命令 | `desktop.commands`／`shortcuts`、GUI 與 Agent 共用契約（目標 5） | **中** |
| `plugin-manager` | 安裝與啟用分離（`dsh.profile.bundles` 名單 vs 條目 `disabled`）、失敗還原 `package.json`／`pnpm-lock.yaml`、與 HMR 串行化、`inspect()` 先答覆 spec 指向什麼、`pendingBuilds` 需單獨批准 | MOD-02～04、5.3 安裝與啟用分開記錄、AT-05 | **中高**：流程與失敗語意可直接沿用，權威改由 Core 持有 |
| `dsh-hmr` | 監視配置與模組、重載與包操作串行化 | 插件 SDK 開發體驗（MOD-08） | **中**：僅開發期使用，不進產品預設 |
| `apps/desktop`（Electron） | 單實例鎖獨占 `$DSH_HOME/profiles/desktop`；CLI 不得管理該 profile；共享產品資料但不共享可執行包與 lockfile | Ditto Core 獨占 Profile 目錄的所有權模型 | **中**：所有權設計可沿用，Electron 本身不沿用 |
| `packages/sdk`（換行分幀 JSON-RPC over stdio、protocol／client／server 三包） | 另一程序驅動完整運行時 | 15.5 版本化 JSON-RPC 契約 | **中高**：協定形狀可沿用，傳輸改為 Unix socket |

### 4.5 Harness 沒有、Ditto 必須自建的部分

以下在上游不存在，是 Ditto 的新增產品要求，也是工期的主要來源：

1. **跨程序的能力租約與撤銷**。Cordis 的 effect 清理只在宿主內有效；跨宿主註冊需租約、心跳、宿主故障後失效與重建（RUN-11／RUN-12）。
2. **交易式變更**。上游 loader 樹變更非交易式；Ditto 需 prepare → 健康檢查 → 路由切換 → 回讀 → 提交／回復的兩階段協調（CHG-01～09）。
3. **熱換等級與交接**。即時替換／受控交接／宿主重啟／工作階段重啟四級語意（14.2）上游無對應概念。
4. **Rust 權威配置與 revision 譜系**。Harness 的配置權威在 YAML 檔案；Ditto 必須是 SQLite + 不可變 revision + 受保護的最近可用版本。
5. **桌面能力層**。`desktop.windows`／`workspaces`／`launcher`／`panels`／`appearance`／`notifications` 全新，需合成器轉接。
6. **無 Node 救援模式**。Harness 的一切都在 Node 內；Ditto 的救援必須在 Node 之外成立。
7. **受限生成與測試宿主**。Harness 有沙箱，但沒有「生成 UI 插件 → 隔離試載入 → 真實預覽 → 啟用」的產品流程。
8. **PSS 分層預算與報告**。需自建量測工具與報告格式。

## 5. 對計畫的關鍵推論

| # | 推論 | 影響的階段安排 |
| --- | --- | --- |
| R1 | Cordis 的價值在「依賴驅動啟停 + 可逆註冊」，不在其配置檔格式 | `ditto-host-loader` 由 Core 推送條目列表取代 file-based Include；不引入第二份 YAML 權威 |
| R2 | 上游 loader 非交易式是已知缺口，不是可以稍後補的細節 | 交易層列為 G1 的**第一個**宿主工作項，先於任何桌面服務插件 |
| R3 | Harness 的 seam 三角是能力目錄的正確粒度 | G1 的每個 `desktop.*` 能力都必須同時交付 Definition／Provider／Consumer，否則不算完成 |
| R4 | `SessionPersistence` 是「會話與 Agent 程序分離」的現成接點 | G2 不必自寫會話格式，只需實作 Core-backed 提供方 |
| R5 | `approval` seam 與 Ditto 權限模型語意一致且「失敗即拒絕」 | G2 直接沿用，省下一套確認流程設計；應答者由 QML 提供 |
| R6 | `landlock-run` 與 `sandbox-local` 是可直接取用的隔離機制 | G3 的隔離風險大幅下降；但 `partial` 強制執行的回報必須向上暴露，不得當作 `full` |
| R7 | Quickshell 的工作區整合清單為 Hyprland／i3／Sway，**不含 Wayfire** | G0 必須把「Wayfire 轉接可行性」當作明確的決策門檻，並備妥合成器備案 |
| R8 | 原型已驗證的互動契約可省下設計迭代，但零行實作程式碼可沿用 | G1 的 QML 工作以契約移植為主，不從零做互動設計 |

## 6. 來源索引

- Ditto PRD v0.4.0：[docs/product/Ditto-PRD-v0.4.0.md](../../docs/product/Ditto-PRD-v0.4.0.md)
- 研究與互動決策：[docs/research/RESEARCH-AND-INTERACTION.md](../../docs/research/RESEARCH-AND-INTERACTION.md)
- 前端原型：[apps/desktop-prototype/](../../apps/desktop-prototype/)
- Harness 架構：`../deepseek-harness/docs/architecture.zh.md`
- Cordis 入門與教程：`../deepseek-harness/docs/cordis-primer.zh.md`、`../deepseek-harness/docs/cordis-tutorial/`
- Cordis vendored 原始碼與修改集：`../deepseek-harness/vendor/README.md`、`../deepseek-harness/vendor/cordis/src/`
- 子系統參考：`../deepseek-harness/docs/subsystems/{approval,jobs,sandbox,credentials,settings,session,tools}.zh.md`
- 原生機制：`../deepseek-harness/native/system/docs/architecture.md`
