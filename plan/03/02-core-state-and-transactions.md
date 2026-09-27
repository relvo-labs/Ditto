# 02｜Core：權威狀態、變更交易、能力與權限

> 對應工作包：G1-CORE-01～17。本文給的是設計判準與初版形狀；定案後的契約以 `docs/contracts/` 與 `schema/` 為準。
>
> 開工前讀 `ditto-authority-boundaries` 與 `ditto-changeset-transaction`；能力擴充另讀 `ditto-capability-contract`，權限另讀 `ditto-permission-and-secrets`，恢復與監督另讀 `ditto-failure-and-rescue`。

## 1. Crate 結構

G0 的五個 crate 保留；G1 新增三個，並在 `ditto-core` 內分出模組。**不為每個概念開一個 crate**：crate 邊界是編譯與依賴邊界，不是分類標籤。

```
crates/
├─ ditto-protocol/     （既有）協定 0.2 型別、能力目錄、ProfileDocument、ChangeSet 型別
├─ ditto-store/        （新增）SQLite、遷移、revision 譜系、快照、套件庫索引
├─ ditto-core/         （既有）服務迴圈 ＋ 下列模組
│   ├─ router.rs         能力路由與 provider 解析
│   ├─ authz.rs          單一授權入口
│   ├─ coordinator/      ChangeSet 狀態機、預檢、熱換執行器、限時回復
│   ├─ participants.rs   交易參與者（Shell、hostd、compositor）的統一介面
│   ├─ hosts.rs          hostd 的啟動、健康檢查、租約表、回收
│   ├─ recovery.rs       開機時的未完成操作處理
│   └─ packages.rs       本機套件安裝、雜湊校驗
├─ ditto-compositor/   （既有）加入布局策略與快捷鍵綁定路徑（G1-PLAT-05）
├─ ditto-system/       （新增）桌面項目索引、通知伺服端、logind
├─ ditto-supervisor/   （新增）Shell 無回應偵測、救援介面啟動（見 05）
├─ dittoctl/           （既有）新增 rescue、diag、profiles、changes 子命令
└─ ditto-measure/      （既有）新增 hostd 的 Node 欄位
```

`ditto-store` 必須是**可被 `dittoctl` 離線使用的函式庫**：救援模式在 Core 起不來時要能直接操作資料庫（受檔案鎖保護），見 [05 §4.3](05-platform-supervision-and-rescue.md#43-離線模式與權威)。這是它獨立成 crate 的真正理由。

## 2. Core 執行緒與儲存架構（G1-CORE-16，D-26）

### 2.1 建議方案

**維持 std 執行緒，不引入 tokio。** 理由：G0 的 IPC、事件與身分都建在 std 執行緒與 mpsc 上且已通過參考機驗證；G1 的並行需求是「少量長時間交易＋大量短查詢」，用一個協調器執行緒加唯讀連線池就能滿足，不需要重寫 G0 已驗證的路徑。

| 執行緒 | 職責 | 可阻塞嗎 |
| --- | --- | --- |
| 連線執行緒（既有，每連線一條） | 框架、握手、身分、把請求交給 router | 否 |
| router（呼叫方執行緒內執行） | 授權、解析 provider、唯讀查詢直接以**唯讀連線**回覆；寫入請求送入協調器佇列 | 唯讀查詢可短暫阻塞 |
| **協調器**（單一） | 擁有**唯一的寫入連線**；執行 ChangeSet 狀態機；對參與者發出 prepare／commit；寫 operation 紀錄 | 只等參與者回應，且每步有逾時 |
| 計時器 | 租約逾期、限時回復倒數、參與者逾時 | 否 |
| hostd 連線（既有連線機制） | Core 發起的請求（prepare、invoke）與 hostd 發起的請求（租約、事件）共用同一條連線 | 否 |
| `ditto-system` 工作執行緒 | inotify、D-Bus（zbus 的 blocking API） | 在自己的執行緒內可阻塞 |

單一協調器同時是 CHG-05「同一配置的提交序列化」的實作：所有寫入天然排隊。不同 ChangeSet 的 `draft → validated` 在呼叫方執行緒以唯讀連線進行，所以「不同任務可並行準備」成立；進入 `prepared` 前在協調器內**重新檢查基底 revision**。

### 2.2 SQLite 選型

| 項目 | 建議 | 理由 |
| --- | --- | --- |
| 函式庫 | `rusqlite`，`bundled` feature，版本鎖定 | 內建 SQLite 原始碼，不依賴發行版的 libsqlite3 版本；SQLite 為 public domain，授權單純 |
| 模式 | WAL；`synchronous=FULL`；`foreign_keys=ON`；`busy_timeout=2000` | 提交的持久性優先於寫入吞吐；寫入頻率低 |
| 連線 | 1 條寫入（協調器）＋ 最多 4 條唯讀 | 唯讀查詢不排在長交易後面 |
| 完整性 | 開機時 `PRAGMA quick_check`；失敗即進救援模式，不嘗試自動修復 | 自動修復可能吃掉受保護版本 |

**被否決的方案**：`sqlx`（需要 async 執行期）；`diesel`（ORM 對 revision 譜系沒有幫助，且遷移工具與鎖定的 toolchain 需另外驗證）。

## 3. 儲存層（G1-CORE-01）

### 3.1 位置

| 路徑 | 內容 | 擁有者 |
| --- | --- | --- |
| `$XDG_DATA_HOME/ditto/core.db` | 權威資料庫 | Core（寫）；`dittoctl --offline`（Core 未執行時，持檔案鎖） |
| `$XDG_DATA_HOME/ditto/core.lock` | 單一寫入者鎖（`flock`） | 同上 |
| `$XDG_DATA_HOME/ditto/packages/sha256/<hash>/` | 內容定址的套件庫，唯讀展開 | Core |
| `$XDG_DATA_HOME/ditto/plugin-data/<plugin_id>/` | 插件資料區 | Core 分配；插件經 `ctx.ditto.data` 存取 |
| `$XDG_DATA_HOME/ditto/snapshots/<snapshot_id>/` | 插件資料快照（CHG-02） | Core |
| `$XDG_STATE_HOME/ditto/backups/` | 遷移前的資料庫備份 | Core |
| `$XDG_CACHE_HOME/ditto/app-index.db` | 桌面項目索引（可重建快取，**不是配置**） | `ditto-system` |

**不寫入 `$XDG_CONFIG_HOME`**。G0 的 `~/.config/ditto-g0/measure-variant` 是量測夾具的開關，不是配置權威；G1 把量測變體改由 `measure-conditions.json` 傳入，並在 G1-PLAT-02 移除該檔的讀取。

### 3.2 資料表

對應 PRD 第 16 節的八組實體。G1 建立前六組的完整欄位；`Session／Message／Task` 與 `GeneratedArtifact` 只建立表結構與遷移位置，**不寫入資料**，避免 G2／G3 新增表時需要破壞性遷移。

| 表 | 關鍵欄位 | 不變量 |
| --- | --- | --- |
| `plugin_packages` | `package_id`、`version`、`sha256`、`source`、`manifest_json`、`installed_at`、`installed_by_change` | `(package_id, version)` 唯一；`sha256` 與套件庫目錄名一致 |
| `plugin_instances` | `entry_id`、`profile_revision`、`package_id`、`version`、`host_kind`、`config_json`、`disabled` | `entry_id` 由 Core 產生（`ent-<ULID>`），跨 revision 穩定 |
| `capability_bindings` | `slot`、`entry_id`、`capability_id`、`lease_id`、`host_generation`、`state` | 單一供應者 slot 在任一時刻最多一列 `state='active'` |
| `profiles` | `profile_id`、`name`、`head_revision`、`last_known_good`、`created_at`、`deleted_at` | `last_known_good` 永遠指向一個 `committed` 且健康確認過的 revision |
| `revisions` | `revision_id`、`profile_id`、`parent`、`document_json`、`document_sha256`、`origin_kind`、`origin_ref`、`change_id`、`created_at` | **不可變**：只允許 INSERT；以 trigger 擋下 UPDATE／DELETE（清理除外，見 §4.4） |
| `changesets` | `change_id`、`profile_id`、`base_revision`、`state`、`hot_swap_level`、`ops_json`、`diff_json`、`result_kind`、`idempotency_key`、`origin_*` | `idempotency_key` 唯一；`state` 只能沿狀態機轉移（trigger 檢查） |
| `operations` | `operation_id`、`change_id`、`seq`、`participant`、`step`、`state`、`request_json`、`readback_json`、`started_at`、`ended_at` | 每個對參與者的副作用請求一列；崩潰恢復以此為依據 |
| `snapshots` | `snapshot_id`、`change_id`、`scope`、`data_version`、`path`、`restorable` | `restorable=false` 時回復計畫不得宣稱可還原 |
| `migration_records` | `plugin_id`、`from_version`、`to_version`、`reversible`、`result` | G1 只記錄 Core 自身遷移；插件資料遷移在 G3 使用 |
| `permission_grants` | `grant_id`、`subject`、`capability_pattern`、`resource`、`granted_at`、`expires_at`、`revoked_at`、`granted_by` | 撤銷只設 `revoked_at`，不刪列 |
| `audit_log` | `ts`、`session_id`、`change_id`、`operation_id`、`subject`、`action`、`decision`、`redacted_detail` | 只追加；敏感內容先遮蔽再寫入 |
| `sessions`、`messages`、`tasks` | 結構預留 | G1 不寫入 |
| `generated_artifacts` | 結構預留 | G1 不寫入 |

時間欄位一律以含時區的 ISO 8601 儲存（第 16 節）。

### 3.3 遷移

- `PRAGMA user_version` 記錄 schema 版本；遷移只能向前，每一步在單一交易內完成。
- 遷移前以 SQLite backup API 複製到 `$XDG_STATE_HOME/ditto/backups/core-<from>-<ts>.db`，保留最近 3 份。
- 遷移失敗 → 交易回滾、Core 以救援模式啟動，**不嘗試**部分遷移後繼續。
- 每個遷移都有測試：從上一版本的固定資料集遷移後，所有 revision 的 `document_sha256` 不變。

### 3.4 空間不足與寫入失敗

REC-05 的判準是「在破壞最近可用版本**之前**失敗」。做法：

1. 新 revision 一律 INSERT 新列，再以單一 UPDATE 移動 `head_revision`。兩者在同一交易中。SQLite 在 `SQLITE_FULL`／`SQLITE_IOERR` 時回滾整個交易，head 不動。
2. 插件資料快照先寫到 `snapshots/<id>.partial/`，完成後 rename。
3. 開機時刪除所有 `.partial` 目錄，並在 `audit_log` 記錄。
4. 每次提交前檢查可用空間是否低於 64 MiB；低於就拒絕變更並回報空間不足。這條檢查不能取代第 1 點，只是讓失敗提早且可說明。

## 4. Profile 與 revision（G1-CORE-02）

### 4.1 ProfileDocument

Profile 的內容是一份結構化文件。Rust 型別在 `ditto-protocol`，匯出 JSON Schema，TS 型別由產生管線取得。初版形狀：

```jsonc
{
  "schema_version": 1,
  "entries": [
    { "entry_id": "ent-01J9...", "package": "ditto.dock.pill", "version": "1.0.0",
      "host": "qml", "config": { "position": "bottom", "icon_size": 40 }, "disabled": false },
    { "entry_id": "ent-01J9...", "package": "ditto.svc.tasks", "version": "1.0.0",
      "host": "cordis", "config": { "source": { "kind": "todo_txt", "path_grant": "grant-..." } },
      "disabled": false }
  ],
  "slots": {                          // 單一供應者約束的宣告位置
    "ui.dock": "ent-01J9...",
    "ui.launcher": "ent-01J9...",
    "layout.strategy": "ent-01J9...",
    "svc.notification_policy": "ent-01J9..."
  },
  "layout": { "workspace_grid": [3, 3], "rules": [ { "match": { "app_id": "foot" }, "workspace": 2 } ] },
  "appearance": { "theme": "soft-jelly", "tokens": { "accent": "#b9a4ff" },
                  "reduced_motion": false, "reduced_transparency": false, "locale": "zh-TW" },
  "shortcuts": [ { "chord": "Super+Space", "command": "launcher.toggle" } ],
  "avatar": { "enabled": true, "scale": 1.0 }
}
```

規則：

- `entry_id` 由 Core 產生並跨 revision 保持穩定。**沒有穩定 id 的條目，每次編輯都會被視為刪除再新增**，這是 harness loader 的已知行為（`milestones/01/00 §4.2`）。
- 文件不含任何秘密值或檔案路徑本身；需要使用者檔案時引用 `path_grant`，路徑存在權限授予中（§8）。
- `layout` 記錄**布局意圖**（規則），不記錄視窗 ID（`ditto-authority-boundaries` 刻度範例）。
- 內容以 RFC 8785（JCS）正規化後計算 `document_sha256`，匯出、比較與完整性檢查都用它。

### 4.2 操作

| 操作 | 能力 | 經 ChangeSet 嗎 | 說明 |
| --- | --- | --- | --- |
| 建立 | `desktop.profiles.create` | 否，產生 revision 1 | 從預設組合或空白建立 |
| 複製 | `desktop.profiles.duplicate` | 否 | 新 Profile 的 revision 1 內容等於來源 head；`origin` 記錄來源 |
| 命名 | `desktop.profiles.rename` | 否 | 名稱不是內容，不產生 revision |
| 比較 | `desktop.profiles.diff` | 否 | 任兩個 revision（可跨 Profile）的結構化差異，與變更卡同格式 |
| 保存 | —— | —— | 每次 ChangeSet 提交就是保存；沒有「未保存的已套用狀態」 |
| 切換 | `desktop.changes.propose`（kind `switch_profile`） | **是** | 切換是對桌面的變更，走完整交易，熱換等級取所有差異中的最高者 |
| 刪除 | `desktop.profiles.delete` | 否 | 軟刪除；作用中 Profile 不可刪；受保護版本在保留期內不清除 |

### 4.3 受保護的最近可用版本

| 事件 | `last_known_good` 的變化 |
| --- | --- |
| ChangeSet `committed` | **不立即**更新。進入 60 秒觀察期 |
| 觀察期內監督回報 Shell 或 hostd 重啟、或任一 entry 進入 `FAILED` | 不更新；變更歷史標示「套用後不穩定」 |
| 觀察期結束且無上述事件 | 更新為該 revision |
| 使用者在救援模式選「恢復最近可用組合」 | head 移到 `last_known_good`，產生新 revision（`origin_kind=rescue`） |

60 秒是提案值，D-15 核定時一併確認。

### 4.4 保留

至少保留最近 20 個 revision 與 `last_known_good`（CFG-07）。清理時：

1. 不清理任何 Profile 的 head、`last_known_good`，以及它們的父鏈中最近 20 個。
2. 不清理被任何保留 revision 引用的套件（`plugin_packages` 的引用計數）。
3. 清理是 Core 的背景工作，在協調器閒置時執行，每次最多刪除 50 列，避免長交易。

## 5. ChangeSet（G1-CORE-03）

### 5.1 型別

```rust
pub struct ChangeSet {
    pub change_id: ChangeId,              // chg-<ULID>
    pub profile_id: ProfileId,
    pub base_revision: RevisionId,        // CHG-01、CFG-06
    pub origin: ChangeOrigin,             // gui { surface } | cli | rescue | import | agent_standin
    pub idempotency_key: Option<String>,  // 同鍵重送回傳既有 change_id
    pub ops: Vec<ChangeOp>,
    pub required_permissions: Vec<PermissionRequest>,  // 由預檢計算，不由呼叫方填寫
    pub preconditions: Vec<Precondition>, // 例：session_unlocked、output_present(name)
    pub rollback_plan: RollbackPlan,      // prepared 時產生
    pub hot_swap_level: HotSwapLevel,     // 由 ops 計算，取最高
}

pub enum ChangeOp {
    SetValue       { path: JsonPointer, before: Value, after: Value },
    AddEntry       { entry: EntrySpec },
    RemoveEntry    { entry_id: EntryId },
    SetEntryConfig { entry_id: EntryId, before: Value, after: Value },
    SetEntryDisabled { entry_id: EntryId, disabled: bool },
    BindSlot       { slot: SlotName, from: Option<EntryId>, to: EntryId },
    SwitchProfile  { to_profile: ProfileId, to_revision: RevisionId },
}
```

`before` 由 Core 在 `validated` 時從基底 revision 填入；呼叫方送來的 `before` 只作為**意圖比對**，不一致就拒絕（呼叫方看到的狀態已過時）。

### 5.2 狀態機與持久化

依 `ditto-changeset-transaction` 第 2 步。每個轉移都在協調器內以單一 SQLite 交易寫入 `changesets.state` 與對應的 `operations` 列，**先寫紀錄、再做副作用**：

```
draft ─► validated ─► prepared ─► applying ─► verifying ─► committed
            │             │            │            │
            ▼             ▼            ▼            ▼
         rejected      aborted   rolling_back ─► rolled_back ｜ partially_applied
                                                       │
                                                       ▼
                                                    unknown   （僅在恢復時、回讀不可判定）
```

`rejected`（預檢拒絕）與 `unknown`（結果未知）是本計畫在 `milestones/01/01 §3` 的狀態圖上補齊的兩個終態：前者讓 AT-05 的「原配置未改變」有可查的紀錄，後者對應結果類別的「結果未知」。兩者都已在上位的語意之內，不是新增語意。

### 5.3 結果類別

終態映射到四個結果類別（`ditto-changeset-transaction` 第 5 步）：`committed`→成功；`rejected`／`aborted`／`rolled_back`→失敗；`partially_applied`→部分完成；`unknown`→結果未知。回應與變更歷史**永遠**同時帶終態與結果類別。

### 5.4 變更卡資料

`diff_json` 沿用原型的變更卡契約（`milestones/01/00 §3`）：`kind`、`title`、逐項 `before → after`、`footnote`。產品語言的標題與逐項說明由 Core 依 op 類型以**翻譯鍵**產生，Shell 依語系顯示；契約 ID 只出現在診斷欄位。

## 6. 確定性預檢（G1-CORE-04）

在 `draft → validated` 依序執行，任一失敗即 `rejected` 並回傳**全部**失敗原因（不在第一個失敗就停，讓使用者一次看到所有問題）。**此階段不呼叫任何模型，也不呼叫任何參與者的副作用方法**。

| # | 檢查 | 失敗原因碼 | 依據 |
| --- | --- | --- | --- |
| 1 | 基底 revision 等於目前 head | `base_revision_stale` | CFG-06、CHG-05 |
| 2 | 每個 op 的 schema；`before` 與基底一致 | `schema_invalid`、`stale_intent` | CHG-01 |
| 3 | 套件已安裝且雜湊與套件庫一致 | `package_missing`、`integrity_mismatch` | MOD-04 |
| 4 | `required_protocol_version` 與 host 版本相容 | `protocol_incompatible` | 12 節 |
| 5 | 依賴閉包：required 全部可滿足；optional 缺失只記錄 | `dependency_missing` | MOD-02 |
| 6 | 依賴圖無循環（Tarjan SCC） | `dependency_cycle` | MOD-02 |
| 7 | 版本範圍（semver）相容 | `version_conflict` | MOD-02 |
| 8 | 衝突宣告（`conflicts`）不同時啟用 | `declared_conflict` | MOD-02 |
| 9 | 單一供應者 slot 只有一個 entry | `single_provider_violation` | MOD-02、CHG-03 |
| 10 | 快捷鍵與命令無重複擁有者（套用後的投影） | `shortcut_conflict`、`command_conflict` | CHG-03、AT-04 |
| 11 | 所需權限已授予或政策允許 | `permission_required` | SEC-02／04 |
| 12 | 前置條件成立（未鎖定、指定輸出存在等） | `precondition_failed` | CHG-01 |
| 13 | 資源預算請求在政策上限內 | `budget_exceeded` | 12 節（宣告只是請求） |

原因碼是**封閉集合**，放在 `preflight_rejected` 錯誤（協定 0.2 新增的錯誤值，-32010）的 `data.reasons[]` 中。

## 7. 能力目錄 0.2（G1-CORE-05、G1-CORE-15）

### 7.1 協定升版

| 項目 | 0.1.0（G0） | 0.2.0（G1） |
| --- | --- | --- |
| 錯誤集 | 11 個 | ＋`preflight_rejected`（-32010）；`permission_denied` 開始實際回傳 |
| `resource_scope` | 全為空集合 | 每項能力分級（§8.2） |
| `provider` | `core`、`compositor-adapter` | ＋`system`、`shell`、`hostd:<entry_id>` |
| `availability` | 靜態或執行期解析 | ＋`host_unavailable`、`rescue_mode`、`not_bound` 等原因 |
| `ResultMeta.revision` | 觀測序號 | **拆成** `observed_seq` 與 `profile_revision` 兩個欄位，消除 G0 註解中「revision 不是 Profile revision」的歧義 |
| 呼叫方 | Shell、`dittoctl` | ＋hostd（kind `hostd`）、Agent 替身（kind `agent`） |

0.1 客戶端一律以 `protocol_version_unsupported` 拒絕，不做相容層。Shell、`dittoctl` 與 TS client 在同一個 PR 升版（EX1-06 ②）。

### 7.2 G1 新增的能力

每一項都必須湊齊 seam 三角並通過 D-23 的目錄一致性 gate。**寫入配置的能力一律是 ChangeSet 的包裝**：`desktop.appearance.set` 在內部建立只含一個 op 的 ChangeSet，所以它同樣有預檢、回讀與歷史，不存在繞過交易的捷徑。

| 群組 | 能力 | 寫？ | readback | 主要 Consumer |
| --- | --- | --- | --- | --- |
| profiles | `list`、`get`、`create`、`duplicate`、`rename`、`delete`、`diff`、`export`、`import_validate`、`import` | 部分 | `profiles.get` | 組合中心、`dittoctl` |
| changes | `propose`、`get`、`list`、`cancel`、`undo`、`confirm` | 是 | `changes.get` | 組合中心、變更歷史、`dittoctl` |
| plugins | `list`、`get`、`inspect`、`install`、`remove`、`diagnostics` | 部分 | `plugins.get` | 插件中心、`dittoctl` |
| permissions | `list`、`check`、`grant`、`revoke` | 部分 | `permissions.list` | 插件中心、個人化設定 |
| appearance | `get`、`set` | 是 | `appearance.get` | 個人化設定 |
| panels | `list`（每個 slot 目前掛載的供應者，由 Shell 回報） | 否 | — | 插件中心；**同時是 UI 替換的 readback** |
| launcher | `search`、`list_apps`、`launch` | `launch` | `windows.list`（見註） | 兩個啟動器 |
| commands | `list`、`invoke` | `invoke` | 依命令 | Shell、`dittoctl` |
| shortcuts | `list`（含衝突） | 否 | — | 個人化設定 |
| notifications | `list`、`dismiss`、`policy_status` | `dismiss` | `notifications.list` | Shell 通知區 |
| layout | `get`（目前策略與可用策略） | 否 | — | 組合中心；布局切換的 readback |
| session | `lock`、`logout`、`suspend`、`poweroff` | 是 | `session.state` | 面板電源選單 |
| jobs（最小） | `get`、`list`、`cancel` | `cancel` | `jobs.get` | 插件中心的安裝進度 |
| tasks（hostd 提供） | `list`、`add`、`complete`、`subscribe` | 部分 | `tasks.list` | tasks 面板 |

註：`launcher.launch` 的 readback 是「在期限內出現 `app_id` 相符的新視窗」。應用可能啟動很慢或根本不開視窗，所以它的 `claimable` 為 **false**，只回報「已啟動程序」，與 G0 的 `close_request` 同一個道理。

合計約 55 項（13 項 G0 ＋約 42 項 G1）。確切清單以 `schema/catalog.json` 為準。

### 7.3 路由

- router 依 `provider` 分派：`core`／`system`／`compositor-adapter` 在程序內呼叫；`shell` 與 `hostd:<entry_id>` 經對應連線轉送。
- `hostd:<entry_id>` 的能力只有在該 entry 的**租約有效**時才可路由；否則回 `unavailable`，原因為 `host_unavailable` 或 `lease_expired`。
- 轉送請求攜帶原始呼叫方的身分與 `operation_id`；hostd 回應的 `readback_verified` 由 Core **自行呼叫 readback 驗證**，不採信 provider 的自述。

## 8. 權限模型（G1-CORE-06）

### 8.1 主體

主體來自身分綁定，不來自訊息內容：

| 主體 | 來源 |
| --- | --- |
| `shell` | 啟動器綁定的 Shell 程序 |
| `cli` | 啟動器綁定的 `dittoctl`；救援子命令另有 `cli:rescue` |
| `host:<entry_id>` | hostd 連線（kind `hostd`）上以 `on_behalf_of` 聲明、且 **Core 確認該 entry 已分派給這個 hostd** 的條目 |
| `agent` | 啟動器綁定的 Agent 替身（G1）／Agent（G2） |

`host:<entry_id>` 是 G1 最重要的身分設計：同程序插件沒有獨立的程序身分，但 Core 知道自己把哪些 entry 推送給了哪個 hostd，所以「hostd 可以代表 entry X 呼叫」是 Core 可驗證的事實，不是 hostd 的自述。hostd 若聲明不屬於它的 entry → `identity_rejected`（EX1-06 ⑤）。信任等級仍如實標示為「同宿主可信插件，無程序隔離」。

### 8.2 資源範圍分級

G0 刻意留空的 `resource_scope` 在 G1 填入以下分類之一或組合：

| scope | 預設政策 | 例 |
| --- | --- | --- |
| `desktop.config` | 允許（有界、可逆） | appearance、layout、panels 替換 |
| `desktop.windows.read` | shell／cli 允許；host／agent 需授予 | windows.list |
| `desktop.windows.control` | shell／cli 允許；host／agent 需授予 | windows.move |
| `files:<grant>` | 需授予，逐項指定 | tasks 服務讀取的 todo 檔 |
| `notifications.read` | shell 允許；host 需授予 | 通知策略服務 |
| `session.power` | shell／cli 允許；其他拒絕 | poweroff |
| `plugins.manage` | shell／cli 允許；其他拒絕 | install、remove |
| `network`、`process.exec`、`clipboard`、`screenshot` | 需授予；G1 沒有任何插件請求 | 保留分類，讓 G2 不必改契約 |

### 8.3 單一授權入口

```rust
fn authorize(subject: &Subject, capability: &CapabilityId, resource: &Resource) -> Decision
```

- **每一個**能力呼叫都經過它，包括 Shell 的呼叫。GUI 與 Agent 共用同一個函式與同一張授予表（SEC-02）。
- `Decision` 是封閉集合：`allowed`、`denied`、`needs_approval`。G1 沒有應答者，`needs_approval` 一律轉為 `permission_denied`，原因 `approval_unavailable`（**失敗即拒絕**）。
- 每個決定寫入 `audit_log`；能力目錄一致性 gate 另加一項：**每項能力都有非空的 `resource_scope`**。

### 8.4 撤銷

`desktop.permissions.revoke` 在協調器內執行：

1. 設 `revoked_at`，後續呼叫立即被拒。
2. 找出該主體依此授予建立的訂閱，送出 `resync_required`（原因 `permission_revoked`）並關閉。
3. 若主體是 `host:<entry_id>`，通知 hostd；entry 的插件須處理 `ctx.ditto.permissions` 的撤銷事件，否則 Core 於 5 秒後停用該 entry。
4. 已發生的外部副作用不因撤銷而回復，變更歷史照實記錄。

## 9. 熱換執行器與交易參與者（G1-CORE-07）

### 9.1 參與者協定

Shell、hostd 與 compositor 轉接在交易中扮演同一種角色，因此 Core 對它們使用**同一組方法**。這讓熱換執行器只寫一次，也讓 Shell 的 UI 替換與 hostd 的服務替換走同一條被測試過的路：

| 方法 | 方向 | 語意 |
| --- | --- | --- |
| `participant.prepare` | Core → 參與者 | 帶 `change_id`、該參與者負責的 ops。參與者建立候選、完成健康檢查，**不取得正式獨占資源**。回報每個 op 的 `ready`、`failed(reason)` 或 `pending(missing)` |
| `participant.commit` | Core → 參與者 | 依熱換等級執行 drain／cancel／handoff，讓候選取得正式資源，並卸下舊實例 |
| `participant.abort` | Core → 參與者 | 丟棄候選（等所有 disposer 完成才回報） |
| `participant.rollback` | Core → 參與者 | commit 後回讀不一致時，恢復舊實例 |
| `participant.state` | Core → 參與者 | 查詢某個 `change_id` 在參與者端的狀態（崩潰恢復用） |

每一步都有逾時：prepare 10 秒、commit 5 秒、abort／rollback 5 秒（提案值，G1-QA-06 量測後調整）。`pending(missing)` 在 prepare 階段等同未就緒，Core 有界等待後判定失敗（`milestones/01/02 §3.2`）。

### 9.2 四個熱換等級

| 等級 | G1 的實例 | 執行器步驟 |
| --- | --- | --- |
| 即時替換 | Dock、啟動器、外觀 token | prepare（候選隱藏載入）→ commit（切換可見供應者、釋放舊的）→ readback（`panels.list`） |
| 受控交接 | 布局策略；通知策略服務；tasks 服務替換 | prepare → 舊供應者停止收新工作 → drain（上限 3 秒）→ 未完成者 cancel 或 handoff → 切換路由 → readback |
| 宿主重啟 | hostd 的 Node 版本或 vendored Cordis 變更 | 顯示受影響的能力清單 → 重啟 hostd → Core 重新推送條目 → readback |
| 工作階段重啟 | 合成器設定中無法經 IPC 變更的項目 | **不執行**；排程為「下次登入套用」，變更歷史記錄待套用，UI 提示保存工作 |

判準沿用 `ditto-changeset-transaction` 第 3 步：這次替換會不會讓進行中的工作失去歸屬？會就至少受控交接；不確定就選更高一級。

## 10. 回讀、提交與限時回復（G1-CORE-08）

- `verifying` 對每個 op 呼叫其 readback 並與目標比對；比對規則由 op 類型決定（例：`BindSlot` 比對 `panels.list` 中該 slot 的 entry 與 `mounted=true`）。
- 全部一致 → 寫 revision、移動 head、`committed`，發布事件。任一不一致 → `rolling_back`。
- **限時回復**（CHG-09）適用於：輸出縮放與排列、主要快捷鍵（啟動器喚出、鎖定、救援）、鍵盤配置、減少透明度關閉。提交後啟動 15 秒倒數，期間 revision 標為 `pending_confirmation`；`desktop.changes.confirm` 才轉為正式。倒數在 Core 的計時器執行，**Shell 死掉不會中斷倒數**，逾時即自動回復。
- `desktop.changes.get` 可以用 `change_id` 或任一 `operation_id` 查詢（CHG-07）。

## 11. 套件來源與完整性（G1-CORE-12）

G1 只支援**本機套件**，網路來源依 D-10 另行決定：

| 項目 | G1 做法 |
| --- | --- |
| 格式 | `.dittopkg`：tar＋zstd，內含 `manifest.json` 與 `dist/`。Cordis 插件須是**單一 ESM bundle**（tsdown 產生），不含 `node_modules`、不含原生 addon |
| 來源 | 內建目錄 `/usr/share/ditto/packages/`（隨產品安裝）與使用者指定的檔案；來源記錄在 `plugin_packages.source` |
| 校驗 | 安裝時計算 sha256，與 Profile 中鎖定的雜湊比對；不一致即拒絕（EX1-02） |
| 流程 | 解壓到 `packages/.staging/<job>/` → 驗證 manifest schema → 計算雜湊 → rename 進 `sha256/<hash>/` → INSERT `plugin_packages`。任一步失敗即刪除暫存（EX1-09 ④） |
| 安裝與啟用分開 | 安裝只寫 `plugin_packages`，不改 Profile；啟用是另一個 ChangeSet（`AddEntry`）。兩者在歷史中分別記錄（5.3 節） |
| 不因另一插件安裝而改寫已用版本 | 同一 `package_id` 可並存多版本；Profile 以 `version` 鎖定，安裝新版本不影響既有 revision（MOD-04） |

沿用 harness `plugin-manager` 的兩個語意：安裝與啟用分離、失敗還原（`milestones/01/00 §4.4`）。**不沿用**執行期 `pnpm install` 與 `pendingBuilds`：G1 的插件已預先打包成單一 bundle，執行期沒有建置步驟，也就沒有需要核准的建置腳本。

## 12. 宿主監督（G1-CORE-10）

Core 監督 hostd，systemd 監督 Core（見 [05 §2](05-platform-supervision-and-rescue.md#2-systemd-user-unitg1-plat-02)）。分工的理由：hostd 的存活由 Profile 決定（RUN-03 註），這個判斷只有 Core 做得出來。

| 事件 | Core 的處理 |
| --- | --- |
| Profile 含已啟用的 `host: cordis` 條目 | 經受控啟動器啟動 hostd（kind `hostd`，放進 `ditto-hostd.scope`，套用 D-06b 的服務配額） |
| hostd 連線中斷 | **立即**把該 hostd 的所有能力標為 `unavailable`（≤500 ms，EX1-08）；進行中的交易轉 `rolling_back` 或補償；所有相關訂閱送 `resync_required` |
| 重啟 | 退避 1 s、2 s、4 s、8 s、上限 30 s；新連線取得新的 `host_generation`，Core 重新推送條目 |
| 重啟風暴 | 10 分鐘內 5 次 → 停止重啟；hostd 能力標為不可用，原因 `host_crash_loop`；插件中心提供「重新啟動宿主」 |
| 某 entry 連續失敗 | 同一 entry 在 10 分鐘內 3 次進入 `FAILED`，或在它啟用後 30 秒內 hostd 崩潰達 2 次 → 以 ChangeSet（`origin=supervisor`）停用該 entry，記錄原因與重新啟用入口（REC-02） |
| 無回應 | hostd 每 2 秒送 `host.heartbeat`；6 秒未收到 → 視同中斷並 `SIGKILL`（先 `SIGTERM` 1 秒） |

## 13. 崩潰恢復（G1-CORE-11）

Core 開機時、接受任何連線之前執行：

1. `quick_check`；失敗 → 救援模式。
2. 刪除 `.partial` 暫存。
3. 找出 `state ∈ {prepared, applying, verifying, rolling_back}` 的 ChangeSet。
4. 等參與者連線（Shell 最多 10 秒、hostd 最多 15 秒），以 `participant.state` 與 readback 判斷**實際**做到哪裡：
   - `prepared` → 一律 abort（尚未有外部副作用）。
   - `applying`／`verifying` → 回讀全部一致則提交；全部未生效則標 `rolled_back`；混合則嘗試回復，回復成功為 `rolled_back`，否則 `partially_applied` 並逐項列出。
   - 參與者未連線或回讀不可判定 → `unknown`，**不重試有副作用的操作**。
5. 結果寫入歷史，Shell 連線後在變更歷史顯示「上次中斷的變更已處理」與結果類別。

## 14. 日誌與診斷（G1-CORE-13）

- 結構化日誌寫 stderr，由 journald 收取；欄位固定包含 `session_id`、`change_id`、`operation_id`、`subject`（REC-06）。
- 遮蔽層在寫出前執行：視窗標題、檔案路徑中家目錄以下的部分、通知內容、剪貼簿一律遮蔽；遮蔽規則有單元測試與「故意洩漏」的負例。
- `desktop.plugins.diagnostics` 與 `dittoctl diag` 回傳 REC-07 的最小集合：依賴鏈、供應者、版本、活躍註冊（來自 hostd 的 `EffectMeta`）、最後健康檢查、最近一次回復結果、fiber 狀態（`PENDING` 必須附「等待中的服務名稱」，不顯示成錯誤）。

## 15. 資源配額施加（G1-CORE-14）

- 沿用 D-06b 核定的三類配額，由 Core 以 `systemd-run --user --scope -p MemoryMax=… -p CPUQuota=… -p TasksMax=…` 施加。
- G1 的使用者：hostd（服務類）、套件解壓 job（建置類）。測試宿主類在 G3 才有使用者，G1 只保留設定並以單元測試驗證參數。
- 施加失敗（例如 user manager 不可用）→ **拒絕啟動該程序**，不以無配額方式啟動（fail closed）。

## 16. `ditto-system`（G1-CORE-17）

| 功能 | 做法 | 為什麼放在 Core 側 |
| --- | --- | --- |
| 桌面項目索引 | 解析 XDG `.desktop`（`$XDG_DATA_DIRS`），inotify 增量更新；存於 `$XDG_CACHE_HOME/ditto/app-index.db` | 啟動器是可替換的 UI 供應者，索引若放在 Shell，換啟動器就要重建，且 GUI 與 Agent 無法共用（5.3 節「替換後保留應用索引」） |
| 應用啟動 | `systemd-run --user --scope --unit=app-ditto-<app>-<rand>` ＋ `xdg_activation` token（C-09） | 應用不是 Shell 或 Core 的子程序，任何 Ditto 程序重啟都不會連帶終止它（DES-09） |
| 通知伺服端 | 以 zbus 在 `ditto-system` 執行緒擁有 `org.freedesktop.Notifications` | 見 D-28：放在 Shell，Shell 重啟時匯流排名稱會掉；放在 hostd，救援模式就沒有通知 |
| logind | 監聽 `Lock`／`Unlock`／`PrepareForSleep`；呼叫 `Terminate`、`Suspend`、`PowerOff` | DES-06 要求使用已驗證的系統機制 |

通知流程：`ditto-system` 收到通知 → 以**有期限的**呼叫詢問 `svc.notification_policy` slot 的供應者（50 ms）→ 依結果顯示、靜默或分流 → 發布事件給 Shell。策略服務不可用或逾時 → **照常顯示**，並在通知區標示「通知規則暫不可用」。這裡的失敗預設是「顯示」而非「抑制」，因為通知策略不是權限：失敗時靜默丟棄通知，比多顯示一則更糟。

## 17. G1 的禁則

1. **不建立第二條配置寫入路徑。** 所有 Profile 內容的變化都是 ChangeSet；`dittoctl --offline` 使用同一個 `ditto-store` 函式庫並持有同一把鎖。
2. **不在協調器執行緒做重工作。** 套件解壓、索引、清理都在工作執行緒或背景工作。
3. **不採信參與者的自述成功。** 每個 op 由 Core 呼叫 readback 驗證。
4. **不以「已排程」代替結果。** 工作階段重啟等級的變更，歷史中是「待下次登入套用」，不是「已成功」。
5. **不讓故障注入點進入 release build。**
6. **不以預設放行處理任何授權失敗。**

## 18. 測試

| 層 | 內容 | 跑在哪 |
| --- | --- | --- |
| 單元（store） | 遷移、revision 不可變 trigger、保留策略、JCS 雜湊 | PR 快檢 |
| 單元（coordinator） | 每個狀態轉移的前置條件；非法轉移被拒；冪等鍵 | PR 快檢 |
| 預檢負例 | §6 的 13 項，每項至少一個負例 | PR 快檢（EX1-02） |
| 授權 | 每個主體 × 每個 scope 的決策表；`approval_unavailable` 失敗即拒絕；偽造 `on_behalf_of` | PR 快檢 |
| 協調器＋假參與者 | 以記憶體中的假 Shell／hostd 跑完整交易、逾時、部分完成 | PR 快檢 |
| 故障注入 | §13 的恢復路徑；ENOSPC；`SQLITE_IOERR` | nightly（EX1-09） |
| 整合 | 真 Shell、真 hostd、真合成器 | 參考機 nightly |
