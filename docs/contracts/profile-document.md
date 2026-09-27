# ProfileDocument：組合內容與 revision

狀態：G1 實作中。欄位的單一事實來源是 [`ditto-protocol::profile`](../../crates/ditto-protocol/src/profile.rs)；產生的結構見 [`schema/profile-document.json`](../../schema/profile-document.json)。本文說明欄位的語意與所有權；若與型別或 schema 不一致，須以 Rust 型別為準修正本文。

## 所有權與內容

只有 Rust Core 能寫 Profile、revision 與作用中的 head。Shell 與 hostd 取得 Core 推送的投影；它們不能保存另一份正式 Profile。`ProfileDocument` 記錄使用者的組合意圖，不記錄合成器的視窗 ID、焦點或輸出即時狀態。這些狀態在重新連線時重新查詢。

| 欄位 | 語意 |
| --- | --- |
| `schema_version` | 文件格式版本；G1 目前為 `1`。匯出封裝另有自己的 `format_version` 與 `protocol_version`。 |
| `entries` | 插件條目。`entry_id` 由 Core 產生，跨 revision 保持穩定；`package`、`version`、`host`（`qml`、`cordis`、`core_builtin`）、`config`、`disabled` 指明供應者及設定。 |
| `slots` | slot 名稱到 `entry_id` 的映射。G1 的 slot 均為單一供應者；新增或替換須經 ChangeSet 預檢。slot 清單以 Rust `SLOTS` 常數為準。 |
| `layout` | `workspace_grid` 與按 `app_id` 比對的工作區規則；布局策略由 `layout.strategy` slot 指定。規則存意圖，不存特定視窗的身分。 |
| `appearance` | 主題、token、語系、減少動畫、降低透明度及低效能樣式。 |
| `shortcuts` | 快捷鍵 chord 與命令的宣告；正式註冊須經交易，不能因候選裝載而先占用快捷鍵。 |
| `avatar` | 啟用、隱藏、縮放與動畫設定。G1 尚無角色位置欄位；雙螢幕位置需求尚未完成。 |

`config` 可持有權限授予的識別碼（例如 `path_grant`），不能持有實際檔案路徑或秘密值。授予與實際路徑由 Core 的權限資料管理；插件資料不在 Profile 中。

## revision 與完整性

Core 將完整文件寫入不可變的 `revisions.document_json`，以文件的 JCS 正規化表示計算 `document_sha256`（`sha256:<hex>`）。鍵順序不同而內容相同時雜湊相同。`Profile` 的 head 與新 revision 在同一 SQLite 交易中更新；失敗時 head 保持原值。每個 Profile 另保有受保護的 `last_known_good`，提交後經觀察期才可更新。保存期限規則見 [store-schema.md](store-schema.md#4-保存期限cfg-07)。

建立與複製 Profile 會產生第一個 revision；重新命名不改文件。已套用的設定變更由 ChangeSet 產生 revision，切換 Profile 亦走 ChangeSet。比較回傳結構化差異；撤銷產生新 revision，不修改舊 revision。

## 匯出與匯入

可攜封裝包含文件、`document_sha256`、套件鎖定、必要的授予引用與遮蔽欄位位置；不包含插件資料、授予背後的路徑或秘密。匯出會掃描敏感值並遮蔽；若遮蔽使必要的型別欄位無效，匯出拒絕，不能退回未遮蔽的原始文件。匯入先檢查封裝格式、協定版本、內容雜湊、套件與授予需求，不能把匯入資料當成可執行指令。實作見 [`exports.rs`](../../crates/ditto-core/src/exports.rs)。

此文件描述目前契約，並非 G1 出口證據。GUI 跨插件切換、匯入操作與實體參考機的驗收結果仍以 `plan/03` 的 EX1 門檻及出口評審紀錄判定。
