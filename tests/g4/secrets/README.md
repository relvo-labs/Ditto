# QA-04：秘密與崩潰內容檢查

對應 SEC-07、REC-06、§16、AT-15；鎖定入口見下方 AT-17。所有哨兵都是測試值，不得把真實憑證傳入這些工具。沒有新增產品依賴或 workflow 修改；測試需已安裝的 `dbus-daemon`、`/usr/bin/python3`、dbus-python 與 PyGObject／GLib（僅開發工具，不打包進產品）。coordinator 可將以下指令接入 CI。結果是 development 證據，不裁定階段出口。

## 產品流程入口

使用 lane 的 `common-b7.md` 本機工具鏈，於 repository 根目錄執行。下列輸出目錄必須不存在，`TMPDIR` 必須指向 lane scratch：

```sh
export TMPDIR=/data/hermes/cache/scratch/fix74-79-tmp
export QA04_EVIDENCE=/data/hermes/ditto-runs/g4-impl/fix74-79/evidence
cargo build --locked --workspace --bins
corepack pnpm -r --filter @ditto/host-runtime --filter @ditto/agent-runtime build
# common.md 的工具鏈若只有 corepack，給既有 build script 一個本地函式入口：
pnpm() { corepack pnpm "$@"; }
export -f pnpm
bash scripts/build-builtin-packages.sh target/ditto-packages
timeout 120 python3 tests/g4/secrets/run.py --scratch "$TMPDIR" --output "$QA04_EVIDENCE/product-positive-rerun"
timeout 120 python3 tests/g4/secrets/run.py --scratch "$TMPDIR" --inject-leak --output "$QA04_EVIDENCE/product-negative-rerun"
timeout 120 python3 tests/g4/secrets/run.py --scratch "$TMPDIR" --inject-leak --leak-form hex --output "$QA04_EVIDENCE/product-hex-rerun"
timeout 120 python3 tests/g4/secrets/run.py --scratch "$TMPDIR" --inject-leak --leak-form base64-offset-1 --output "$QA04_EVIDENCE/product-base64-rerun"
```

正向 `run.py` 預期 exit 0、`ok=true`、`hit_count=0`；負向控制只有在 `flow.ok=true`、必要分類／SQLite 齊全、沒有掃描／隱私錯誤，且所有命中都來自 `intentional-leak.log` 時 exit 0、`negative_control_passed=true`（`ok=false` 仍表示檢出秘密）。流程失敗、其他來源命中或缺少命中均 exit 1。若 `flow.ok=false`，代表流程根本沒完成，不能當成負向控制成功或外洩掃描通過。輸出目錄必須不存在，避免舊產物污染證據。

`manifest.json` 明列注入值與掃描根目錄；此測試輸入及 `driver.json` 位於 product 之外，不冒充產品輸出。產品產物與原始 log 都保留在 `product/`，`result.json` 列出每個範圍、檔案數、命中數及原始路徑，缺少必要分類或 SQLite 不通過。命中報告不複製秘密值或上下文。

注入流程：三種秘密樣式經正式 `agent.credentials.create` 成功存入**私有 session bus 的記憶體假 Secret Service**。每種秘密各執行一次正式 direct-model Agent 回合：Agent 向 Core 解析憑證，腳本式 loopback Responses 端點核對實際收到的 Authorization，經 Agent 工具讀取 Profile、套用通知策略，再回讀 hostd 插件配置。Core／hostd／Agent stderr、store、匯出、診斷、會話、生成產物、HOME 與 runtime 均保留後掃描。秘密值只應存在測試輸入、假 keyring／Agent／本機 provider 記憶體；不把原值傳給 hostd 或寫進 Profile。

`driver.json` 只保存檢查結果，不保存 provider 請求或 Authorization。`product/runtime/keyring.json` 只含方法計數與 item 數量；`run.py` 要求至少三次 CreateItem 與 GetSecret，driver 另核對三個值皆被真正使用。generation 仍只呼叫正式 create/get 產生固定模板 bundle。私人對話／proposal 哨兵只允許在明列的會話 readback／store 中；另掃日誌、匯出與診斷，避免把合法保留的私人對話當秘密誤報。

假服務的方法集合來自 `rg` 核對 `crates/ditto-system/src/secrets.rs`：Service.OpenSession(`sv`→`vo`)、SearchItems(`a{ss}`→`aoao`)、Collection.CreateItem(`a{sv}(oayays)b`→`oo`)、Item.GetSecret(`o`→`(oayays)`)、Delete(``→`o`)，以及 Properties.Get／GetAll 的 Collection.Locked。僅提供 unlocked/plain/no-prompt 路徑；未模擬鎖定、加密 session 或 Prompt.Dismiss。這不是完整 Secret Service 實作。

隔離使用專用 `dbus-daemon --nofork --config-file=<scratch>/bus.conf`，設定只監聽 `unix:path=<scratch>/bus`，不載入使用者設定或 service activation 目錄。runner、假服務及 driver 都核對 `DBUS_SESSION_BUS_ADDRESS`；拒絕使用者 bus、分號備援地址或非預期路徑。`DBUS_STARTER_ADDRESS` 同步覆寫。socket 路徑置於 `--scratch` 下的短目錄，程序皆在 finally 終止，runtime 一般檔案保留，socket 本身無持久 bytes。禁止改成指向真實 keyring 的環境。

`flow.not_run` 固定揭露尚未涵蓋真網路模型／Codex app-server、隔離 native validation／preview、Wayfire／Quickshell 真 crash 與密碼解鎖錄影。流程未完成時另加 `complete private-keyring / Agent / hostd / store / export flow (not completed)`；不能因 fixture 已寫好就宣稱整合成功。runner 與假服務關閉自己的 coredump，不改產品 crash 政策。

`scan.py` 可接受 manifest 重掃 retained 產物。讀取一般檔案 bytes（含 SQLite WAL／舊頁）、SQLite 邏輯內容（含 UTF-16）及 `.dittopkg` 解壓成員。完整哨兵保留 literal、JSON escaping、URL encoding，新增 hex 大小寫與 Base64 offset 0／1／2；共用 `nonce` 也獨立搜尋這些形式。Base64 只比對完全位於哨兵／nonce 內的 sextet，避開前後位元干擾，涵蓋 standard／URL-safe 與有／無 padding。manifest 的 nonce 至少 16 bytes，產品 runner 每次產生 32 字元 UUID nonce。去前綴或截斷仍保留 nonce 的外洩可命中；**只留下 nonce 的短片段、任意轉換、雜湊、加密或未支援壓縮格式仍不在保證範圍**。這是已知哨兵偵測，不是任意秘密辨識或磁碟鑑識。符號連結、讀取失敗、壞 SQLite、不存在的範圍均失敗。

## 不依賴 IPC 的掃描器控制

本機 Python 無 pytest，README 的正式替代 gate 為標準函式庫 unittest；不安裝依賴：

```sh
python3 -m unittest discover -s tests/g4/secrets -p 'test_*.py' -v
node tests/g4/secrets/driver.test.mjs
python3 tests/g4/secrets/control.py --output "$QA04_EVIDENCE/control-positive-rerun"
python3 tests/g4/secrets/control.py --inject-leak --output "$QA04_EVIDENCE/control-negative-rerun"
python3 tests/g4/secrets/control.py --inject-leak --leak-form hex --output "$QA04_EVIDENCE/control-hex-rerun"
python3 tests/g4/secrets/control.py --inject-leak --leak-form base64-offset-1 --output "$QA04_EVIDENCE/control-base64-rerun"
```

控制預期依序 exit 0、0、0、1、1、1；三個負例的 `hit_count` 都必須大於 0（scanner `ok=false`）。`run.py --inject-leak` 成功負例控制仍 exit 0，但要求真實 flow 完成、唯一命中來源為 `intentional-leak.log`；流程失敗不算負例成功。`test_scan.py` 也對 runner 三種負例的退出政策執行 fixture 回歸；不冒充產品證據。

`test_keyring.py` 驗證記憶體 create／replace／search／get／delete、拒絕真實 bus／備援地址，並以已安裝的 distro Python 執行 `keyring_wire_test.py`，直接核對實際 dbus-python decorator 簽章與資料形狀。這不建立 socket，也不聲稱完成跨程序 D-Bus 協定驗證。本機實跑 `run.py` 正／負例在私有 bus bind 被 sandbox 以 `Operation not permitted` 拒絕，**BLOCKED（sandbox socket）**；完整流程須由 coordinator 在 sandbox 外使用上面的精確指令重跑。

## 崩潰／診斷路徑盤點與缺口

| 路徑 | 本地可確認範圍 | 結論與待補證據 |
| --- | --- | --- |
| Quickshell 0.3.1／cpptrace | `packaging/systemd/user/ditto-core.service` 的 `--shell`／`--rescue-ui`／`--lock` 啟動規格；`docs/platform/dependency-inventory.md` 釘選 cpptrace | 本地沒有 Quickshell 執行檔、上游 handler source 或 crash 樣本。**未執行**；不能猜測 dump 實際位置或宣稱未包含記憶體內容。VM 須記錄該釘選版本實際產生的報告位置、內容及同意介面。 |
| Core panic | `crates/ditto-core/src/main.rs`、`lib.rs` 未安裝自訂 panic hook；一般日誌遮蔽在 `log.rs`，不涵蓋標準 Rust panic hook | 程序 stderr 由工作階段收集；panic payload 的內容安全尚無保證。OS dump 是另一層（本機 core_pattern 為 apport），不能當成 Core 的遮蔽輸出。實際 panic／OS dump **未執行**。 |
| hostd | `src/main.ts` 的啟動／停止／斷線／unhandledRejection；`src/log.ts` 的 Cordis exporter → HostLog → stderrSink／journald | `163e782` 已重現 Error.message／stack 外洩。repair1 經擴大寫入授權修正預設日誌；保留類別、閉合錯誤碼、已知交易分類、插件識別及 SHA-256 指紋，丟棄原文。這不是實際 crash／OS dump 已驗證的宣稱。 |
| Core 診斷回應 | `diagnostics.rs::plugins`／`rescue_status`，沒有獨立「診斷壓縮包」或 opt-in 上傳實作 | 回應含插件、依賴、註冊、狀態；`supervisor_note` 讀 audit `redacted_detail`，欄位名不是通用遮蔽器。現有生產 disable reason 為固定代碼（hosts.rs）；未實證此路徑缺口，因此沒有修改 diagnostics.rs。 |
| 範圍可見的選擇加入 | 原始日誌／崩潰內容沒有正式範圍選擇與上傳介面 | **未提供／BLOCKED**；手動複製檔案不是選擇加入機制。不得據此宣稱 §16 全項通過。 |

重現 hostd 真正的 exporter（不啟動宿主、不造成真 crash）：

```sh
node --experimental-transform-types tests/g4/secrets/crash-audit.mjs "$QA04_EVIDENCE/crash-audit.json"
```

目前預期 exit 0，四類私人測試內容命中 0 項，且三筆 Error／格式字串／物件載荷的診斷指紋仍存在。repair1 的原始 RED 在 `163e782` 上命中 4 項、exit 1；原始及擴充後的 GREEN 均保留於 lane evidence/repair1。沒有新增 opt-in、上傳、保留政策、設定開關或持久狀態。

## repair1：driver 契約核對

coordinator 在 `163e782` 的兩次產品流程都因 export 缺少 `profile_id` 而停止，`flow.ok=false`，不得計入正向／負向證據。driver 現在兩次匯出均使用 `desktop.profiles.get` 回讀的 `profile.profile_id`。本機仍不能開 socket，**本 #74 私有 keyring 端到端流程未完成，交 coordinator 重跑**。

`node tests/g4/secrets/driver.test.mjs` 實際執行同一個 `runFlow`（三次成功憑證／回合），逐次以 `schema/catalog.json` 的 input_schema 驗證所有 17 個能力，並以 `{}` 重現舊 export 參數被拒。測試僅實作這些 schema 用到的 vocabulary，遇到新關鍵字就失敗；不是通用 schema 驗證器，也不模擬產品成功證據。

| 方法 | 必填參數 | driver 實際提供 |
| --- | --- | --- |
| `desktop.profiles.get` | 無 | `{}`，回讀現役 Profile |
| `desktop.plugins.diagnostics` | 無 | `{}` |
| `desktop.changes.propose` | `base_revision,ops` | 回讀的 `profile_id`、`head_revision`，空 ops 與私人哨兵冪等鍵 |
| `desktop.changes.get` | 無（可依 change／operation ID 查詢） | propose 回傳的 `change_id`，確認私人冪等鍵保存 |
| `agent.credentials.create` | `provider,secret,idempotency_key` | `direct-model`、三種哨兵各一次、`qa04-<label>` |
| `agent.sessions.create` | `title,idempotency_key` | `QA04 private conversation`、`qa04` |
| `agent.settings.describe` | 無 | `{}` |
| `agent.settings.patch` | `expected_revision,settings` | 回讀 revision 與完整偏好，覆寫啟用／direct-model／成功建立的憑證引用／loopback HTTP endpoint；移除 `_meta` |
| `agent.turns.submit` | `session_id,client_message_id,text` | 建立的 session、`qa04-message`、私人對話哨兵 |
| `agent.turns.get` | `turn_id` | submit 回傳的 turn ID |
| `agent.sessions.read` | `session_id` | 建立的 session，另傳 `offset:0,limit:50` |
| `desktop.plugins.development.create` | `description,request_summary,idempotency_key` | 正式 tasks-summary 範例、`QA04 fixed template`、`qa04-create` |
| `desktop.plugins.development.get` | `artifact_id` | create 回傳的 artifact ID |
| `desktop.profiles.export` | `profile_id` | 回讀的 Profile ID，初次匯出與隱私複查皆提供 |
| `desktop.rescue.status` | 無 | `{}` |
| `agent.runtime.get` | 無 | `{}` |
| `agent.runtime.stop` | 無 | `{}` |
| `core.handshake`（既有 connect helper） | `protocol_version,client,auth` | `0.3.0`、launcher 的 kind/version、繼承 descriptor 取得的 token；核對 `schema/handshake-input.json`，本輪未執行 IPC |

能力參數由共用 client 加入 `_meta.protocol_version=0.3.0,deadline_ms=15000`；這是 Core 剝除的傳輸 metadata，不屬於 input_schema 的領域參數。實際單元請求表可由 `DITTO_QA04_CONTRACT_REPORT=<path>` 保存。

#73 新增 proposal → ChangeSet 回讀，私人哨兵 `QA04_PRIVATE_PROPOSAL_CONTENT` 只允許保留在明確保存的 readback／store，不得進一般日誌、匯出與診斷。`run.py` 的隱私掃描已加入此哨兵。subject 是 Core 綁定的呼叫身分，不能當 RPC 參數；logger 的任意私人 subject 測試與全部欄位結論見 [Core 日誌盤點](core-log-audit.md)。產品掃描仍交 coordinator 在 sandbox 外重跑，未宣稱通過。

## repair1：hostd 日誌路徑盤點

下表路徑均相對 `packages/host-runtime/src/`；以 `git grep -n -E 'describe\(|stack|message|console\.|stderr|journald' -- packages/host-runtime/src` 及實際 log 呼叫交叉核對。

| 路徑 | 可否帶私人內容／處理 |
| --- | --- |
| `log.ts::installCordisExporter` | 可以：Error、格式字串、物件、logger 名稱。改固定 `cordis.error/message` 與指紋，不格式化載荷；插件識別由交易層依 fiber 查回，不信任 logger 名稱。 |
| `log.ts::HostLog/child/write`、`stderrSink` | 可以：外部直接呼叫、繼承 fields、巢狀 items。共用遮蔽器在進入自訂 sink 前及 stderr 序列化前執行；未知 msg 只留固定 `host.message` 與指紋。沿用 Rust content keys、`[redacted]` 與 HOME→`~/…`，error/reason 保留安全診斷摘要。 |
| `main.ts::stop` 的 cleanup catch | 可以：runtime.stop Error。傳 Error 本體給共同遮蔽器。 |
| `main.ts` 的 `closed` callback | 可以：連線 Error.message 原先插進 why。why 改固定 `Core connection closed`，Error 獨立遮蔽。 |
| `main.ts::unhandledRejection` | 可以：任意 rejection。僅類別／已知碼／指紋；handshake 完成前記錄後 exit 1，完成後沿用只記錄的行為。 |
| Node 預設 fatal handler → `main.ts::uncaughtException` | 可以：原先 Node 直接印 stack。現在插件啟動前安裝遮蔽 handler，記固定事件與安全摘要後仍 exit 1；rejection handler 也提前安裝。 |
| `main.ts::main().catch` | 可以：啟動 Error 與路徑。僅類別／已知碼／指紋。 |
| `runtime.ts::startBackground` | 可以：背景 request Error。傳 Error 本體遮蔽。 |
| `runtime.ts::handleRequest` 成功／拒絕 | 可以：`items[].reason` 與例外、未知 method。items 遞迴遮蔽 reason，保留固定分類、key/status/change_id；method 僅保留已知參與者方法。 |
| `runtime.ts::permissionRevoked/deliverEvent` | 可以：插件 handler Error。保留 entry/subscription ID，不記 grant/event 載荷。 |
| `ditto-service.ts::events.emit` candidate drop | event 名稱可能是任意文字；name 遮蔽，保留 entry ID。 |
| `ditto-service.ts::events.subscribe`、`activate` | 可以：topics、Core／註冊 Error。topics 遮蔽，Error 保留閉合碼與指紋、entry/capability ID。 |
| `events.ts::pump` | 可以：插件 event 名稱、Core Error；payload 原本未記。name 遮蔽、Error 摘要、entry ID 保留。 |
| `leases.ts::revoke/renew` | 可以：撤銷／重註冊 Error。保留 lease/capability 關聯與安全摘要。其他固定通知僅列 lease IDs。 |
| `loader/transaction.ts::drainAndExport/dispose` | 可以：drain、exportState、fiber.dispose Error。傳 Error 本體遮蔽；其他 log 僅固定事件、entry、bytes、timeout。 |
| `fault-enabled.ts::faultPoint` | 測試環境 action 原先任意直寫 stderr；改走同一 HostLog，只保留已知 action 分類。production bundle 仍剔除 fault 模組。 |
| `errors.ts::describe/toWireError/DittoError.toWire`、transaction 其餘 describe、`bridge/rpc.ts`、projection fail、runtime invoke/schema issue | 可以帶私人文字，但屬 RPC／狀態資料，不是 stderr/log 出口；本輪不改 wire 契約。進入 participant 日誌時由上述邊界遮蔽。 |
| `testing/fake-core.ts` | 僅測試 RPC fault，非 production 日誌；同樣不直寫 stderr。 |

既有 disposer 測試原以私人錯誤原文辨識 c1，現改驗證真實 Core-owned entry/plugin ID、Error 類別與指紋，並斷言原文缺席。數量／狀態／關聯欄位仍保留。指紋使用 HMAC-SHA-256；hostd 啟動時產生 32-byte 隨機密鑰，只留在記憶體，不記錄或保存。同一次程序生命週期內可穩定分組，重啟後指紋改變，無法用公開的訊息雜湊表反查短文字；未知自訂 Error 類別或錯誤碼不直接信任。

```sh
corepack pnpm --filter @ditto/host-runtime test
corepack pnpm --filter @ditto/host-runtime typecheck
corepack pnpm --filter @ditto/host-runtime build
node tests/g4/secrets/driver.test.mjs
node --experimental-transform-types tests/g4/secrets/crash-audit.mjs "$QA04_EVIDENCE/crash-audit.json"
```

## #74：hostd 欄位 allow-list 盤點

`log.ts::safeLogStringFields` 的固定集合由 `log.test.ts` 鎖定並逐鍵驗證。未知字串或容器變成 `[redacted]`，未知容器內即使使用安全鍵也無法繞過；只有 `items` 允許遞迴的交易結果物件，lease 陣列沿用其安全欄位鍵。HOME→`~/…` 保留。Error／reason 使用原有閉合診斷 schema；`name/code/fingerprint` 不經一般欄位放行。

以下列出現有 production log 呼叫的全部鍵（含 child、spread 與巢狀結果），以 `rg 'log\.(error|warn|info|debug|child)|new HostLog' packages/host-runtime/src` 逐一核對：

| 呼叫端（src 相對路徑） | allow-list 原樣字串 | 遮蔽／閉合診斷 | 數值／布林／容器 |
| --- | --- | --- | --- |
| `main.ts` | `component,why,mode,strategy` | `error` | `pid,min_semi_space_mib,max_semi_space_mib,fixed,reclaim,host_generation` |
| `runtime.ts` | `part,change_id,method,entry_id,grant_id,subscription_id`；`items[].key,status` | `error,items[].reason` | `items` |
| `ditto-service.ts` | `entry_id,capability_id` | `name,topics,error` | — |
| `events.ts` | `entry_id` | `name,error` | — |
| `leases.ts` | `lease_id,capability_id,presented[],renewed[],expired[]` | `error` | — |
| `loader/transaction.ts` | `entry_id` | `error` | `bytes,timeout_ms` |
| `fault-enabled.ts`（僅測試 build） | `component,part,point,action` | — | `hit` |
| `log.ts` Cordis exporter | `source,entry_id,plugin_id` | `error`；不保存 logger 名稱或載荷 | — |
| 自動欄位 | `ts,level,msg` 由 logger 產生／固定事件集合 | 未知 msg 改 `host.message`，`message_fingerprint` 僅接受 HMAC 格式 | — |

另外明列的 `operation_id,session_id,path` 用於既有追溯／HOME 防禦測試，現有 production 呼叫未傳入。既有測試用 `title,summary,body,clipboard,text,content,window_title,message,stack,payload,config,args,logger,name,topics` 仍全部遮蔽。識別字／安全欄位仍依賴呼叫端遵守內容契約；把秘密故意塞進 allow-list 的 ID 仍非通用偵測器。Core 日誌由 #79 lane 處理，本輪不改 `crates/**`；既有 Core 結論見 [盤點](core-log-audit.md)。

## repair2：無 IPC 回歸

```sh
node --experimental-transform-types tests/g4/secrets/lifecycle-consumer.test.mjs
corepack pnpm --filter @ditto/host-runtime exec vitest run --exclude 'tests/process/**'
cargo test --locked --no-run -p ditto-core --features fault-injection --test lifecycle
```

L-06 的 `msg` matcher 使用 `host.fault`，保留 `point`／`hit`；無 socket 測試直接比對真實 fault producer 與 Rust matcher。指紋測試重載兩個獨立 host log 模組，驗證各啟動密鑰內穩定、跨密鑰不同；不聲稱兩個完整 hostd 的 IPC 啟動。scanner 單元測試模擬 flow 產生 fixture，驗證實際 runner 的退出政策，不計為產品流程證據。RED 使用 `46cea3b` 的原始 production 檔案，GREEN 使用本輪修正。

完整 lifecycle 需 socket，**未執行，交 coordinator**：

```sh
bash tests/g1/lifecycle/run.sh
# 或先產出 fault-enabled host，再跑 Rust lifecycle：
DITTO_HOST_FAULT_ENABLE=1 corepack pnpm --filter @ditto/host-runtime build
cargo test --locked -p ditto-core --features fault-injection --test lifecycle
```

## AT-17：VM／參考機補跑

在有 verification relay、foot、grim、jq 的**可拋棄 Ditto Wayfire 登入座位**執行，輸出目錄另行保留；兩次各使用新的登入，避免原鎖定 client 被殺後影響後續：

```sh
DITTO_ARTIFACTS=/tmp/qa04-lock-bypass timeout 240 bash tests/g1/lock/bypass.sh
DITTO_ARTIFACTS=/tmp/qa04-lock-original timeout 240 bash tests/g1/lock/run.sh
```

`bypass.sh` 覆蓋 Shell SIGKILL、替換 Dock UI、`upgrade_entry` 插件升版嘗試、啟動正式 rescue service；每次檢查 Core locked、全部像素沒有可見綠色標記。UI／升版必須含 `session_locked` 拒絕且 revision／hash 不變。升版目標刻意未安裝，測的是鎖定拒絕，不宣稱成功升版生命週期已執行。`run.sh` 原情境另殺 lock client 與 Shell。capture 失敗只能標 environment，不能當作黑屏通過。取樣不能排除兩幀之間的閃露，仍須**全程錄影、人工檢查所有螢幕及密碼解鎖**。operator 項目待補時整體 exit 3，不計通過。

本機只執行 `bash -n`、像素 oracle 單元與 Core 缺少 lock/UI 時的鎖定狀態測試；四個合成器情境及密碼錄影均為 **未執行（需 VM／參考機）**。

```sh
python3 -m unittest discover -s tests/g1/lock -p 'test_*.py' -v
cargo test --locked -p ditto-core tests::lock_without_a_client_stays_locked_during_shell_and_rescue_supervision -- --exact
cargo test --locked -p ditto-core tests::rescue_core_does_not_clear_a_requested_lock_when_the_ui_is_missing -- --exact
```

刪除對話的邏輯遮蔽限制沿用 [既有已知限制文件](../../../docs/platform/codex-backend-boundary.md#5-已知限制未宣稱完成)，不建立第二份限制清單。
