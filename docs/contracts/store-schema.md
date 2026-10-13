# ditto-store：資料表、不變量與故障語意

狀態：實作中（schema 版本 1）。權威是 `crates/ditto-store/src/schema.rs`；本文件描述語意與不變量，欄位不一致時以程式碼為準修正本文件。

## 1. 位置與寫入者

| 路徑 | 內容 |
| --- | --- |
| `$XDG_DATA_HOME/ditto/core.db` | 唯一的 SQLite 資料庫（WAL、`synchronous=FULL`、`foreign_keys=ON`、busy timeout 2 秒） |
| `$XDG_DATA_HOME/ditto/core.lock` | 寫入者鎖（`flock(LOCK_EX \| LOCK_NB)`） |
| `$XDG_DATA_HOME/ditto/packages/sha256/<sha256>/` | 內容定址的套件庫，解壓後唯讀 |
| `$XDG_STATE_HOME/ditto/backups/` | 遷移前的整庫備份 `core-<version>-<stamp>.db` |
| `$XDG_STATE_HOME/ditto/snapshots/`、`…/staging/` | 快照與解壓中的暫存；`.partial` 與 staging 內的殘留在開啟時清除 |
| `$XDG_CACHE_HOME/ditto/app-index.db` | 應用索引快取，可隨時重建，不屬於權威狀態 |

`DITTO_DATA_DIR=<root>` 把三者換成 `<root>/{data,state,cache}`，只給夾具與測試用。目錄權限 0700，資料庫 0600。

**同一時間只有一個寫入者**（原則 1）。Core 在整個生命期持有 `core.lock`；`dittoctl --offline rescue …` 取得同一把鎖才寫，取不到就立刻回報「Core 仍在執行」，不排隊。鎖是非阻塞的，所以救援工具不會卡在一個活著的 Core 後面。

開啟順序（`Store::open_writer`）：取得鎖 → `PRAGMA quick_check`（失敗即進救援模式，**不自動修復**，因為修復可能吃掉受保護的 revision）→ 版本低於目前版本時先備份 → 在單一交易中遷移 → 清除中斷寫入的殘留。遷移只往前；資料庫版本比程式新時拒絕開啟。

## 2. 資料表

| 表 | 用途 | 不變量（由 trigger 或約束強制） |
| --- | --- | --- |
| `profiles` | Profile 與其 `head_revision`、`last_known_good` | head 與 last-known-good 必須指向存在的 revision（延遲外鍵）；刪除是軟刪除 `deleted_at`，現役 Profile 不能刪 |
| `revisions` | 不可變的 Profile 文件與內容雜湊 `document_sha256`、來源 | **不能更新**；只有保存期限清理（持有 `retention_gc` 標記的交易）能刪除；`parent` 無外鍵，清掉舊祖先後血統從最舊保留者開始 |
| `revision_flags` | revision 的可變事實（待確認、不穩定、觀察期截止） | 跟著 revision 級聯刪除 |
| `plugin_instances` | 每個 revision 的條目（反正規化，用來計算套件引用數） | 不能更新 |
| `plugin_packages` | 已安裝套件：封存 sha256、樹摘要 `tree_sha256`、manifest | 主鍵 `(package_id, version)` |
| `capability_bindings` | 能力到條目的租約綁定與 hostd 世代 | 同一能力最多一個 `active` 綁定（部分唯一索引） |
| `changesets` | 每一筆 ChangeSet 的完整紀錄 | 只能以 `draft` 插入；狀態轉換必須在 `change_transitions` 中；**不能刪除**（它是歷史）；`idempotency_key` 唯一 |
| `change_transitions` | 狀態機的資料形式，由 `ChangeState::allowed_next()` 產生 | Rust 與 SQL 不會各有一份狀態機 |
| `operations` | 對參與者的每一步（prepare／commit／rollback…）：請求、回讀、牆鐘與單調時間 | `(change_id, seq)` 唯一；狀態 `started／succeeded／failed／unknown` |
| `snapshots`、`migration_records` | 插件資料快照與資料遷移紀錄 | — |
| `permission_grants` | 授予 | 不能刪；只能撤銷一次，其他欄位不能改 |
| `audit_log` | 稽核紀錄（已遮蔽的細節） | 只增不改不刪 |
| `jobs` | 長工作（安裝等） | 狀態受 CHECK 限制；`idempotency_key` 唯一 |
| `sessions`、`messages`、`tasks` | 為 G2／G3 預留，G1 不寫入 | 舊預留表不作 G2／G3 權威；正式表由前向 migration 建立 |

`changesets.request_operation_id` 保存呼叫者自己的 `_meta.operation_id`，斷線後可用 `desktop.changes.get {operation_id}` 找回自己送出的變更（CHG-07）。

## 3. 寫入順序與故障語意

- **先寫紀錄再做副作用。** Coordinator 每次改狀態都先提交該轉換，再呼叫參與者；每一步參與者呼叫在 `operations` 先記 `started` 再送出。Core 在任何時點被殺，重啟後都能從資料庫知道做到哪裡。
- **恢復。** 開機時對停在 `prepared` 的變更一律 `aborted`；停在 `applying`／`verifying`／`rolling_back` 的，以參與者回讀對照目標與基底判定為 `committed`、`rolled_back`、`partially_applied` 或 `unknown`，並寫 `recovered_at`。head 在那之後已被別的變更移動時一律 `unknown`，不重做任何事（EX1-09 ①）。
- **空間不足與 I/O 錯誤。** 預檢在可用空間低於 64 MiB 時以 `precondition_failed`（`why: storage_low`）拒絕；提交 revision 時遇到 `SQLITE_FULL` 或 `SQLITE_IOERR`，交易整體回滾，變更轉為回復並記 `change.storage_full`／`change.storage_error`，head 與 last-known-good 不變（EX1-09 ②③）。寫不進 draft 時呼叫直接得到 `unavailable`，`reason` 為 `storage_full` 或 `storage_error`。
- **套件解壓。** 先驗封存 sha256，解到 `staging/<stage>`，驗樹摘要與 manifest 後才搬進 `packages/sha256/<sha256>/` 並設為唯讀；任何一步失敗都清掉暫存，套件庫不含半成品（EX1-09 ④）。安裝後被改動的檔案在預檢時以 `integrity_mismatch` 拒絕。

## 4. 保存期限（CFG-07）

永不刪除：每個 Profile 的 head 與 last-known-good、它們父鏈上最近 20 個 revision、未完成或待確認變更所引用的 revision。套件以剩餘 revision 的引用數保護。只有持有 `retention_gc` 標記的交易能刪 revision。

## 5. 離線救援

`dittoctl --offline rescue restore-last-good` 與 `… disable <package>` 取得寫入者鎖後，走與 Core 相同的程式碼寫入**新的 revision**（來源 `rescue_offline`），不改寫任何既有 revision。稽核記錄 subject `cli:rescue`。

## 6. 故障注入點（只在 `fault-injection` build）

`store.commit_revision:full|ioerr`、`store.unpack:ioerr`，以及 Core 側的 `coordinator.after_state=<state>:abort_process`、`coordinator.readback=mismatch`。環境變數 `DITTO_FAULT=<point>:<action>[:n]`。release 二進位不得含這些字串（`scripts/check-release-fault-points.sh`，`rust.yml` 另以 fault-injection build 做正向對照）。

## 7. G3 schema 4

原空殼 generated_artifacts 完整改名為 generated_artifacts_legacy，保留舊列；新 generated_artifacts 以 plugin_id/version 唯一、parent 外鍵與 create idempotency key 保存正式產物。generated_plugin_data 是每個插件的唯一資料權威，generated_data_snapshots 保存回退快照。遷移失敗不改 schema version 或舊表；資料升版、快照與 Profile revision 同筆交易。詳見 [生產模板邊界](../platform/generated-template-boundary.md)。
