# 06｜生命週期、工作池與故障恢復

工作包：AGENT-01／09～11／13／14、CORE-01／05／10、PLAT-03／04、QA-02～05／09。必讀：`ditto-process-budget`、`ditto-failure-and-rescue`、`ditto-changeset-transaction`、`ditto-permission-and-secrets`。

## 1. 按需啟動與受控身分

Core管理Agent單例，擴充既有launcher：fd交付一次token，綁PID／exe／generation，握手後撤token。禁止CLI自稱agent取得相同grant；正式Agent不用`AgentStandin` origin。runtime.ensure在並發十個喚起请求時只spawn一次，其他等待同generation ready；ready表示transport、session adapter、catalog/tool dispatcher可接受task，不必等待provider首字。

狀態提案：stopped → starting → ready → draining → stopped；starting／ready可轉failed，Core記restart reason。Agent由Core按需啟動，不加`Restart=always`令idle退出被systemd復活。Core／Shell／hostd依舊獨立監督，Agent失敗不停止它們。

打包落點：既有啟動腳本與user session設定增可信Agent入口／artifact校驗；systemd scope或等效cgroup掛在產品診斷中。PLAT-03驗證從乾淨checkout可build／install／launch，不依賴`../deepseek-harness`在使用者電腦存在。持久恢復由Core與Store，不靠Agent的cwd或私有daemon pid檔。

Codex 路徑另 spawn 一個 pinned Rust app-server，以 private stdio 連 controller；同一個 Core 管理的 process group／cgroup tree，不能另建全域常駐 daemon、繼承個人 MCP／hooks，或多起子 Agent。ready 需 controller 身分驗證及 app-server 協定初始化／工具限制完成，模型首字不計啟動，首次使用者登入另計。實際雙程序與 OS 隔離／keyring 訪問須 D-44 評審、PLAT-04 probe，不以 logical Agent 數量掩蓋 PID；暖態 150MiB 判整組，見 [10](10-codex-app-server.md)。

## 2. 活動與回收

Core為model turn、tool dispatch、approval等待、build／long job歸屬保存activity lease，Agent heartbeat只回報存在，不自行決定「桌面没工作」。純UI顯示／對話面板打開／token動畫不構成活動，角色也不保活。

| 情境 | 可以回收嗎 | 判準 |
| --- | --- | --- |
| 無active turn、無approval、無未移交job | 是 | 最近活動結束5分鐘後開始drain |
| 正在等provider／串流／工具結果 | 否 | turn尚未terminal，除非超時／取消已有結果 |
| 仍有效的待確認／澄清 | 否 | request未expiry或cancel；不能把長等待視為閒置 |
| Codex 登入等待 | 否，直到完成／取消／expiry | 有限 login lease；不能永久續租 |
| 長job仍由Agent持有執行責任 | 否 | 先完成或持久移交Core |
| Core已承擔job與UI事件，Agent無後續工作 | 是 | handoff有durable ack，Core可繼續及顯示完成 |
| Agent心跳停止 | 先宣告失效 | Core撤世代、cancel model transport與writer；受理change/job依Corepolicy處理 |

idle drain順序：Core禁止舊世代取新turn → Agent停止新增provider／tool → flush所有Session queue → close handles與Cordis effects／RPC／timer → exit → Core確認PID與子程序／cgroup已空。**5分鐘是預設真實等待，釋放在到期後10秒內完成**。測試可用縮時clock做race單元測試，出口另跑真實時間。

draining期间新訊息不丟：Core先持久queue，再撤drain或等待舊世代退出啟動新世代；proposal優先採「drain開始後不重新接任務，由新世代讀queue」簡化race。新世代不能與舊世代同時active。flush失敗Core保留pending／dirty狀態，不回「已保存」；超過10s由Core終止程序並產生未達標數據，不悄悄延長RUN-03。

崩潰自動重啟只對仍有使用者請求且有可恢復read-only／查詢工作；不自動再dispatch不明副作用。建議restart budget 3次／60s，超出顯示「對話啟動失敗，可重新連接」並待新顯式動作；數值為D-39實作提案，與既有Core/hostd restartstorm各自計數。

## 3. Core 工作池（AGENT-11／CORE-05）

現有jobs是安裝紀錄，Storecreate即running、啟動中斷標failed；不能當成排隊與可取消worker已完成。新增kind、owner、phase、deadline、budget、cgroup、cancel_requested、handoff、artifact refs與持久queue，不把所有舊安裝job自動重跑。

G2只允許可信kind，例如有界索引／資料處理與既有套件驗證；至少實作一個真實CPU工作、可查結果並經Agent觸發，另用loop／memory fixtures測超限。模型不能提供任意code／executable。一般HTTP模型等待在Agent可取消非同步執行，不算占兩個CPU worker slot；重型任務移出Node event loop。

全產品重型工作池預設**最多2**並行，Agent／hostd共享Core admission而非各自2個；排隊上限提案32jobs，超過quota明確拒絕，按提交時間與owner公平排程。每個worker臨時spawn、完成退出，不為每plugin常駐worker。停用Agent不取消Core已ack handoff的job；provider請求沒有完成handoff不可僅把task記成job假裝可退出。

OS配額沿用已核定 [D-06b](../../.agents/notes/decisions/2026-09-22-d06b-tool-quotas.md)：一般短工具256M／CPUQuota=50%／TasksMax=32；受控建置2G／200%／256；生成測試宿主512M／100%／64屬G3。不得把一般工作借用建置配額。額外暫存64MiB、120s deadline 為 D-09／39 提案。原單程序 Agent scope memory.max 256MiB 與 pids cap 提案，在 Codex 路徑改由 D-44 核定整組 cgroup tree／hard limit，不可兩個程序各給 256MiB 後聲稱同一預算。kind 可收緊，放寬須另附數據裁定。**限制值不是 PSS 目標**，controller＋app-server＋必要子程序暖態仍須≤150MiB。測試需確認 OS enforcement，不能以 Node heapLimit 或 Worker 隔離冒充 cgroup。若環境無委派權，保持工作池不可用並列阻擋，不回 enforcement=full。

worker獨立cgroup、環境最小化、fd／檔案與網路按kind限制；OOM只殺worker，沒有秘密環境變數。未信任生成物的OS sandbox仍留G3，G2工作池的可信kind限額不能宣稱已完成第三方沙箱。

jobs狀態：queued → running → succeeded／failed／cancelled；running收到cancel進cancelling，先協作abort、再TERM、最後boundedKILL，確認cgroup清空才terminal。queued取消不spawn；late completion與cancel競爭由CoreCAS決定並保留結果／已發生副作用。progress用真實completed/total或phase，無可度量總量就不用假百分比。

Core重啟時queued可信job可依持久policy排回；running job查cgroup／result，再標interrupted／unknown或明確失败，不盲目重做外部副作用。舊schema install jobs保留原kind恢復語意；新增state與CHECK constraints一起遷移。`desktop.jobs.cancel`要對kind有效且descriptor誠實，原不能取消kind仍回unsupported，不能所有job宣稱cancellable=true。

## 4. 取消邊界與操作恢復

停止對話：不再發新模型／工具，abort正在等的provider與read-only工具；已受理配置走既有cancel／rollback語意。committed不變成cancelled，若使用者要撤銷另propose undo。取消卡列明「已套用／已回復／尚在查詢」；partial／unknown不能縮成單一失敗。

Codex `turn/interrupt` 只中止後端 turn，不會撤銷 Core 已受理的 ChangeSet。app-server crash：controller 停止新 dispatch、保存 interrupted 狀態並查 Core operation；Core 桌面交易獨立繼續。重啟建立新 ephemeral thread 從 Core 歷史投影，不能重播工具，也不能把舊 ephemeral thread_id 當持久 resume 資料。controller crash／idle exit 必须確認 app-server 一起退出；100 次清理及真正 5min＋10s 驗收涵蓋兩個程序。

| 注入位置 | Core責任 | Agent重連行為 |
| --- | --- | --- |
| 只有模型plan，未有Core durable accepted | 沒有桌面副作用；保留訊息／interrupted turn | 重新規劃需新明確turn，不自動執行舊plan |
| tool intent durable，RPC未確認是否受理 | 依client intent key查既有operation | 查詢；找不到且無冪等契約則unknown |
| change prepared | 既有coord持有snapshot／candidate與base | 查change；不能重新propose同副作用 |
| applying／verifying，Agent死 | Core完成驗證提交或回復 | 讀terminal結果與實際状態 |
| committed，Agent未存tool result | revision／operation已持久 | 補correlation result事件，不能再套一次 |
| Core死／磁碟滿 | Store與coordinator既有恢復、保留最近可用版本 | Agent顯示不可用，禁止當權威補寫 |
| hostd死 | 租約撤銷、能力available=false、交易按既有policy處理 | catalog重讀，不能用失效schema假完成 |
| Shell死／鎖定 | 已受理change繼續；approval不可用，capture拒絕 | 保留turn與結果，後續UIsnapshot恢復 |

operation.get按principal驗證，僅回owner可見資料；unknown指結果尚不可確認，不等於failed。非冪等呼叫沒有安全重試契約就**不重送**。Natural／KeyBased只能按當時descriptor和相同payload重試；key不可因重啟随机重生。

## 5. 日誌與診斷

沿用Core／hostd結構日誌，新增session_id、turn_id、tool_call_id、operation_id、change_id、job_id、generation、phase、duration、reason，不寫secret／raw clipboard／file／screenshot／user text。runtime diagnostics 同時列 Core、Shell、compositor、hostd、Agent controller、Codex app-server、workers 的 PID/cgroup、RSS/PSS/CPU，另外報 Agent group 合計；Node 額外 heapUsed／external／arrayBuffers 分別記。

重連先snapshot再事件，取消失效訂閱與舊generationcallback；100次啟停没有listener、lease、timer、child殘留。真機同時使用Firefox／foot／Kate、hostd tasks事件與通知政策觀察，Agent停止及OOM期間窗口與未存內容維持，無Node救援沿用G1回歸。
