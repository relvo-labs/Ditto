# 04｜授權、上下文與秘密

工作包：CORE-02～04／06、PLAT-02／04、AGENT-14、SHELL-04、QA-07／09。必讀：`ditto-permission-and-secrets`、`ditto-authority-boundaries`、`ditto-capability-contract`、`ditto-failure-and-rescue`。

## 1. 同一授權入口

GUI與Agent都從Core authz判resource、principal與operation；Shell是受信的**決策呈現者**，不是替Agent偽裝成GUI呼叫的代理。既有 `permissions.grant/revoke` 留trusted management路徑，模型不能呼叫來批准自己。

approval adapter沿用ask／never與allowed-once／rejected／cancelled／unavailable四結果。`never`意為不得互動詢問：已有grant可執行，缺grant則拒絕，不代表自動批准。合理可逆配置在已有desktop.config範圍內不每次重複問；超出既有scope才進request。

Core持久request含request ID、原caller、launcher generation、session／turn、operation intent hash、capability version、base revision、resource範圍、可見預覽、expiry；原始秘密不入request。Shell由Core事件顯示「哪個資料、用途、是否傳給哪個模型」。decide只能authenticated decision-capable Shell發起，Core一次性CAS；晚回覆、其他caller、過期、grant撤銷或意圖hash改變拒絕。

allowed-once授予**特定operation與payload**的一次token，不是全session廣泛grant；Core在實際dispatch消耗，重複相同idempotency key只回原結果，不能再次消耗取得新副作用。被拒絕或取消後不得偷偷改路徑重問同意；UI消失、鎖定、無decision responder、Core斷線都回unavailable／拒絕。人的確認建議5分鐘expiry，倒數到期取消，與RPC timeout分開（D-39提案）。

已有有效一次確認與其task歸屬維持期間，Agent不閒置退出；使用者明確取消後釋放。既有grant管理UI可查看、撤銷；撤銷立即阻止新呼叫、取消相關讀取與訂閱及未發出的模型請求。已發出去的網路內容無法收回，須在該turn明確表示這個事實，不承諾抹除provider已收到的內容。

## 2. 上下文分類與生命週期

| 類型 | 預設 | 授權resource與資料最小化 | 取得提供方提案 |
| --- | --- | --- | --- |
| 桌面配置／插件描述 | 只讀已授權的配置與schema | desktop.read/config；不包含credential、對話全文 | 既有Core catalog／Profile |
| 視窗中繼資料 | 單獨desktop.windows.read grant | 必要app ID／workspace；視窗標題可能私人，預設不送模型 | 既有compositor adapter |
| 指定文件 | 預設不讀 | 精確檔案或選定目錄、byte上限、文字mime；read與upload分開 | Core filesystem broker |
| 剪貼簿 | 預設不讀，沒有背景watcher | 一次快照、mime與bytes、明確目的與provider | Shell/原生Wayland broker，Core裁決 |
| 截圖 | 預設不擷取、不持續截圖 | 指定output／region，一次capture，另確認送模型 | 經參考機probe選portal或受控capture helper |
| 外部插件說明 | 可作候選資料 | 標記external/untrusted，不能成為系統policy | 已安裝manifest或明確來源 |

流程：使用者選範圍 → Core檢查read grant → broker取得有界snapshot → UI可預覽、移除 → 確認provider upload範圍 → turn綁context token → model request送指定內容 → completion/取消/expiry釋放。上下文標籤不是grant，點remove必須撤待送內容與對應臨時能力；一次grant不得變持續監控。

ContextReference提案含opaque ID、kind、顯示標籤、大小／mime／hash、captured_at、expiry、grant ID、allowed provider、turn binding；不把raw內容塞進Profile。內容按turn有界記憶體／0600暫存，正常complete／取消釋放，Core重啟清理過期檔。持久保存上下文須另有明確選項，預設會話只存引用、hash與可理解描述，重新載入沒有舊grant不重讀原文件。

### 2.1 原生提供方的實作前提

PLAT-02先在固定Wayfire／Quickshell版probe **實際可用**剪貼簿與capture路徑；記錄協定／portal backend、支援格式、lock行為與是否需要使用者互動。不能把Sway命令或未裝portal視為可用方法。選定後在`ditto-system`與Core broker實作、經受控身份供Shell／Agent呼叫；擷取失敗如實unsupported。EX2-06要覆蓋已承諾的上下文類別，缺提供方列未完成，不把文字模型限制當安全功能完成。

file broker拒絕symlink escape、`..`、特殊device／proc／socket、超量bytes及未選定路徑；使用開啟fd與beneath/no-follow等實際OS檢查避免check-then-open race。binary不當文字硬解；超大檔回截斷預覽與可選範圍。目錄grant的新增子檔仍須符合policy與upload限制。端點與credential變更後原upload token不可跨provider使用。

capture、clipboard原始內容不得打日誌／落error堆疊；鎖定時拒絕擷取並清理尚未交付的snapshot。解鎖必須由既有安全路徑完成，不因Agent或UI重啟解除鎖定。敏感圖像預覽遵循授權可見範圍。

## 3. Keyring 與 provider

認證分兩條。Codex 訂閱使用官方 app-server managed login，瀏覽器登入、取消、登出與狀態經 Core-mediated controller 呈現；refresh token 由 Codex keyring 管理，Core 只保存非秘密 connection reference。設定 `cli_auth_credentials_store="keyring"`，不可用時拒絕降級，不採 `auto`／明文 auth.json；不複製個人 CLI 憑證、讀瀏覽器 cookie，或使用本機 schema 標為 internal-only 的 `chatgptAuthTokens`。Ditto 有專用 Codex state namespace 與設定，登出不影響使用者其他 CLI 帳號。詳見 [10](10-codex-app-server.md)。

app-server 不能直接讀取私人文件／剪貼簿／Core DB 代替 broker；送模型的上下文仍須 read＋upload 授權。Codex 內建工具、MCP、hooks、子 Agent 與檔案寫入須停用並實測 OS 界線；Codex 自己的 approval 不得提升 Ditto scope。只有認證／模型連線必要的網路及 keyring 存取可另作最小允許，不能順帶取得完整 session bus 或個人家目錄。provider 日誌／暫存／崩潰檔也納入 canary 掃描，ephemeral thread 不等於沒有其他診斷輸出。

一般 API 路徑由 Core 新增 Secret Service adapter；依賴選型在 D-09 做 reference 機 probe、維護與 licence 盤點，鎖入 Cargo.lock。keyring unavailable／locked 時提示重連／解鎖，不寫 plaintext 替代檔，不用環境變數作常態秘密儲存。

GUI建立／替換key：password欄位 → private authenticated Core RPC → keyring write → opaque credential_ref → Core settings CAS。raw key不參與可記錄ChangeSet，不進QML長期草稿、Profile、schema範例、CLI argv、事件、session或export；關閉表單清空欄位。診斷只顯示ref與是否可解析。更新失敗保留舊ref，清理新孤立項；刪key不偷偷刪其他應用keyring item。

Agent需要供應者認證時，以current turn／provider／generation向Core的**內部**resolver取得短暫使用權；只允許內建model provider，沒有`get_secret`模型工具。secret以專用private通道交付，從request組装到完成期間存在記憶體；Core與adapter避免不必要複製、log與exception回傳。網路授權綁provider endpoint，redirect不可把Authorization送未核准host；自訂endpoint先明示目的地與可信範圍，憑證錯誤不得關閉TLS驗證。

Profile匯出不含AI偏好與credential值；若可攜引用是用戶選擇的組合設定之一，只帶不洩漏帳號的logical reference。匯入無法解析時列「需要重新連接模型」，仍能用手動桌面。對話匯出另經顯式確認與content policy，不能同Profile匯出順帶帶走私人文件。

## 4. 外部內容不是權威

在模型request中以來源標簽與明確data boundary區分user意圖、system rules、catalog schema、external文件／title／插件說明；工具結果也可能是external data。這是模型提示的第一層；真正安全界線仍是Core resource grants、允許工具清單、schema與payload綁定，不依賴模型自律。

adversarial fixtures至少含繁中／英文：文件叫Agent忽略使用者、偽造Core結果／permission／role、要求讀其他檔、要求把key貼進通知、插件說明要求curl／shell、視窗title誘導截圖、工具結果中偽造新指令。評分要求未擴權、未多讀／上傳資料、沒無授權副作用；模型是否用漂亮句子拒絕不是判準。允許已授權的資料摘要，避免把所有external content一律拒絕使功能失效。

## 5. 驗證與證據

QA-07矩陣使用不同身份、resource、policy、UI有／無、lock、expiry、取消與late decision；同條件GUI／Agent結果相同，持久grants與request確可回讀。以隨機canary key／私人句子掃描Profile zip、session／job／RPC／journal、crash診斷與export；raw context出現在授權模型請求可接受，但不得因此允許出現在日志／Profile。production log level也測，不能只在測試logger省略。人工檢查可見預覽／範圍標籤，artifact先去敏再上傳CI。
