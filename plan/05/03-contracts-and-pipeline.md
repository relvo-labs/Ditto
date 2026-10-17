# G3 契約與生成流程

本檔保留 Core 接線時的設計提案；#19／20／21／24～28。正式 development 能力現已在 PR #40 實作，實際介面與限制見 [生產邊界](../../docs/platform/generated-template-boundary.md)，逐項證據與未完成驗收見 [完成缺口盤點](07-completion-audit.md)。下文的「提案」描述設計基準，不代表目前尚無 RPC。適用 skills：`ditto-capability-contract`、`ditto-authority-boundaries`、`ditto-agent-changeset`、`ditto-changeset-transaction`、`ditto-generation-safety`。

## 1. 狀態所有權與產物

Core 保存正式 `GeneratedArtifact` 與不可變的內容地址產物；Agent 只提出受限描述。Cordis 不保存第二份正式生成目錄，Shell 僅保存焦點／草稿等 UI 暫態。開發 SDK 的輸出是候選，不是正式 Profile 或授權。

產物需包含原始碼（固定模板來源＋受限描述）、manifest、鎖定的模板／能力／執行期依賴、設定與資料 schema、驗證紀錄、生成來源。缺任一項不得啟用；雜湊驗證與路徑正規化要拒絕 traversal、symlink 逃逸與內容變動後沿用舊驗證。

治理紀錄含 artifact／插件／版本／父版本 ID、原始需求的最小化摘要、來源 turn／operation 引用、模板與程式版本、內容雜湊、個別關卡／實際隔離報告、啟用 ChangeSet 與 revision／回讀／回復歷程。不複製完整對話、context 或秘密；來源引用遇會話刪除後仍可表達「來源已刪除」，不能藉產物永久保留被刪文字。

## 2. 正式能力的 seam

`plugins.development` 是能力族的需求名稱，實際方法與欄位由 #19 審查後在 Rust 定義，不能在 Agent 拼出未存在的命令。至少涵蓋候選建立／讀取、建置／驗證、獨立預覽、發行候選與版本比較。發行候選不等於安裝或啟用。

| 角色 | 提案落點 | 必要證據 |
| --- | --- | --- |
| Definition | `ditto-protocol`，schemars → schema → TS | Rust／TS 同向量拒絕未知 enum／欄位；D-39 相容性審查 |
| Provider | Core 路由／Store、受控 worker／能力代理 | 身分綁定、共用 authz、每一步 scope、不可由 manifest 自述身分 |
| Consumer | Agent 動態工具＋Shell 候選卡片 | 實際發現、呼叫、取消及回讀；三角不齊不得宣告能力完成 |

長工作回傳 Core job／operation，沿用兩個並行與排隊；deadline 有上限、可取消、冪等鍵綁來源／版本；重新連線查既有結果，不重播未知副作用。每步均經授權，只有實際擴權或資料副作用需要另問 approval，有界可逆操作沿用既有授權。

## 3. 管線與修復

順序固定：語法 → 契約 → 載入 → 焦點 → 基本互動。第一失敗即停止，後續關卡標未執行；不得把「未執行」補成通過。每步報實際開始／完成時間、失敗碼與診斷；語法成功不能當 OS 安全證據。

全部通過後才提供獨立真實預覽，標示測試資料。預覽有關閉／取消／deadline；不寫目前 Shell 或救援目錄。確認預覽不自動授予額外權限。

修復最多三輪（初始生成另計），每輪新版本／新驗證；同一失敗指紋第二次出現即停止，且無關卡進展時停止。預算、嘗試與診斷由 Core 持久化，重啟／多輪／取消不能重置；第三輪後沒有第四次建置。令牌或帳號配額不足保留結果，不回退到未授權模型。

## 4. 啟用、版本與資料

啟用走既有 ChangeSet：preflight → prepare → apply → readback → commit／rollback。preflight 核對 base revision、當前 grants、內容雜湊、完整隔離與驗證證據；prepare 保留前版及資料快照；load／health／readback 任一步失敗自動停用候選並回復，源碼／診斷保留。回復不能證明時誠實報 partial／unknown，不重試不明副作用。

對話修改生成新的不可變版本，顯示產品語言的差異與可回復版本，不覆蓋前版。資料 schema 在 Core 管理資料區：

| 政策 | 升級 | 回退 |
| --- | --- | --- |
| 向後相容 | 宣告可讀範圍並測試 | 舊版只在 schema 可讀範圍內讀取 |
| 可逆遷移 | 記錄遷移、正反轉換與快照 | 執行反向遷移、回讀資料與 schema |
| 不可逆但有快照 | 啟用前原子快照 | 明示會恢復快照及升級後資料處理，再授權 |
| 不可逆且無可用快照 | 不承諾回退 | 拒絕舊版讀新資料，保留新版資料與明確診斷 |

資料刪除是獨立明確操作；插件移除不刪資料。磁碟滿、快照損毀、遷移中斷／重啟須有確定性結果。AT-22 以舊版實際讀取驗證，不能只檢查 revision 或回復函式被呼叫。
