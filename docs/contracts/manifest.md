# 插件 manifest

| 欄位 | 內容 |
| --- | --- |
| 版本 | `manifest_version: 1` |
| 型別權威 | `ditto_protocol::manifest::Manifest` → `schema/manifest.json` |
| 狀態 | 實作中（G1-HOST-09） |

manifest 是**請求**，不是事實：信任等級、權限、資源預算都由 Core 的政策與授予決定。`description` 與顯示名稱不授予任何東西（MOD-07）。

「強制」＝ Core 在預檢或執行期依它做決定；「記錄」＝ G1 只保存與顯示。

| 欄位 | G1 | 形狀與規則 |
| --- | --- | --- |
| `manifest_version` | 強制 | 必須是 `1` |
| `id` | 強制 | 反向網域式，`[a-z0-9]+(\.[a-z0-9_-]+)+`，例：`ditto.dock.pill` |
| `version` | 強制 | semver |
| `name`、`author`、`license`、`source`、`description` | 記錄 | 插件中心顯示；`name` 可為翻譯鍵物件 `{ "zh-TW": "…", "en": "…" }` |
| `plugin_kind` | 強制 | `service`｜`qml_provider`｜`declarative_bundle` |
| `host_kind` | 強制 | `cordis`｜`qml`｜`core_builtin`；`service ↔ cordis`、`qml_provider ↔ qml`、`declarative_bundle ↔ core_builtin` 以外的組合一律拒絕 |
| `trust_level` | 強制 | `trusted`｜`community`｜`untrusted`；G1 只接受 `source = builtin` 的 `trusted` 套件，其他在預檢以 `precondition_failed` 拒絕 |
| `runtime` | 強制 | `{ "node": "^22.19.0" }` 或 `{ "qt": ">=6.10" }`；不相容 → `protocol_incompatible` |
| `platform` | 強制 | 例 `["linux-x86_64"]`；不相容 → `precondition_failed` |
| `required_protocol_version` | 強制 | semver 範圍，例 `"^0.2"`；不相容 → `protocol_incompatible` |
| `slots` | 強制 | 這個套件可以填的 slot，例 `["ui.dock"]` |
| `provides` | 強制 | `[{ "capability": "desktop.tasks.list" }, { "service": "tasksStore" }]` |
| `requires`／`optional` | 強制 | `[{ "package": "ditto.svc.tasks", "version": "^1" }]`、`{ "capability": "…" }`、`{ "service": "…" }`；required 不可滿足 → `dependency_missing`；optional 缺失只記錄 |
| `conflicts` | 強制 | 套件 id 陣列；同時啟用 → `declared_conflict` |
| `entry` | 強制（cordis） | 相對於套件根的單一 ESM bundle，例 `dist/index.mjs` |
| `qml_entry` | 強制（qml） | 相對於套件根，例 `qml/DockPill.qml` |
| `config_schema` | 強制 | JSON Schema（draft 2020-12 的子集：`type`、`properties`、`required`、`enum`、`items`、`default`、`minimum`、`maximum`、`additionalProperties`，另可有不影響判定的 `title`、`description`、`$schema`）；最上層須為 `"type": "object"`。Core 在預檢依它檢查條目的 `config`，規則見下方「config 的檢查」 |
| `data_schema` | 記錄 | G3 的資料遷移使用 |
| `commands` | 強制 | `[{ "id": "launcher.toggle", "title_key": "…" }]`；同一 `id` 兩個擁有者 → `command_conflict` |
| `shortcuts` | 強制 | `[{ "chord": "Super+Space", "command": "launcher.toggle" }]`；重複 → `shortcut_conflict`；Core 保留的組合（救援、鎖定）不得宣告 |
| `events` | 強制 | `[{ "name": "tasks/changed", "schema": {…}, "coalesce": "latest" }]`；`coalesce` ∈ `none`、`latest` |
| `permissions` | 強制（請求） | scope 陣列，例 `["files:*", "notifications.read"]`；最終由政策與授予決定 |
| `hot_swap` | 強制 | `instant`｜`controlled_handoff`｜`host_restart`｜`session_restart` |
| `health` | 強制 | `{ "timeout_ms": 2000 }` |
| `cleanup` | 強制 | `{ "timeout_ms": 5000 }`；超過即標為故障，第二次掛載被拒 |
| `migrations` | 記錄 | G3 |
| `activation_events` | 記錄 | G1 一律在啟用時載入 |
| `idle_policy` | 強制 | `resident`｜`on_demand`；**與 Agent 的 5 分鐘規則無關** |
| `resource_budget` | 記錄＋比對 | 可省略（預設 `{}`）；`memory_mib`、`cpu_percent` 各自可省略或為 `null`，有值時須為 `u32`（0～4294967295），不接受其他欄位。例 `{ "memory_mib": 20 }` 或 `{ "memory_mib": 20, "cpu_percent": 5 }`；逐欄比對政策上限（服務類 64 MiB、10%），超過 → `budget_exceeded`。省略或 `null` 不代表獲准無上限，最終由 Core 政策決定 |
| `rescue` | 記錄 | `{ "disable_safe": true }`：`dittoctl rescue disable` 可以直接停用它 |

對 `declarative_bundle/core_builtin`，SDK 接受 Rust `Manifest` 的省略預設值：`runtime` 為 `{}`；`platform`、`slots`、`provides`、`requires`、`optional`、`conflicts`、`commands`、`shortcuts`、`events`、`permissions`、`migrations`、`activation_events` 為 `[]`；`config_schema` 為 `{ "type": "object" }`。空 `platform` 不限制平台，空 `permissions` 不授予權限。明確宣告的值仍須符合型別、範圍與政策規則；整個欄位為 `null` 不套預設值，`runtime.node`／`runtime.qt` 則依 Rust 的 `Option<String>` 可省略或為 `null`。SDK 不會把預設值寫回 manifest；service／QML 的 runtime 與入口必填檢查維持原狀。

## config 的檢查

SDK 在作者端檢查 `config_schema` 與其中的 `default`（`packages/host-sdk/src/manifest/rules.ts`）；Core 在預檢檢查實際寫入的 `config`（`crates/ditto-core/src/config_schema.rs`，#161）。兩邊用同一組關鍵字與同一套判定，所以 SDK 接受的 `config`，Core 也接受。

- **何時檢查**：一筆變更寫入條目的 `config`（`add_entry`、`set_entry_config`），或把條目換到另一個套件版本（`upgrade_entry`）時，以**該版本** manifest 的 `config_schema` 檢查變更後的 `config`。升版後沿用的舊 `config` 若不符新版 schema，整筆變更被拒，不會默默通過。切換 Profile 時，對目標 Profile 中與目前 Profile 不同的條目做同樣檢查。
- **何時不再檢查**：變更沒碰到的條目不重新檢查，所以 #161 之前存下、不符 schema 的條目仍可載入、停用與移除；Core 啟動與參與者同步也不檢查。撤銷、限時回復、救援與監督停用是回到 Core 已保存的 revision，不重新檢查，以免擋住回復的路。同一套件版本的 manifest 不會改變（重新安裝同版本但內容不同會被拒），所以保存時通過檢查的 revision，之後不會因為 schema 改變而變得不符。
- **匯入**：`profiles.import_validate` 與 `profiles.import` 把不符 schema 的 `config` 列為**非阻擋**的 `schema_invalid` 問題（`why` 同下）。匯出會把疑似秘密或私人路徑的值換成 `null`，這可能讓 `config` 不符 schema，需要匯入後再補；補好之前，切換到該 Profile 會在預檢被拒。
- **結果**：不符時原因碼為 `schema_invalid`，見 [protocol-0.2.md §8.3](protocol-0.2.md#83-預檢) 的 `why` 清單；整筆 ChangeSet 被拒，Profile 不寫入。套件未安裝時仍只回 `package_missing`，不另做 schema 檢查。
- **超出子集的 schema**：含子集以外關鍵字（例如 `pattern`、`const`、`$ref`）、最上層不是物件 schema，或關鍵字的值無法判定（`properties` 不是物件、`required` 不是字串陣列、子 schema 不是物件或布林）時，Core 不判定這份 `config`，而是以 `config_schema_unsupported` 拒絕。SDK 對這種 manifest 同樣報錯。SDK 會略過的格式錯誤（`minimum` 不是數字、`enum` 不是陣列、`properties` 或 `required` 為 `null`），Core 也略過。

## 套件格式 `.dittopkg`（D-10 提案）

tar ＋ zstd，根目錄有 `manifest.json`，其餘是 `dist/`（cordis）或 `qml/`（qml）。Cordis 插件必須是**單一 ESM bundle**，不含 `node_modules`，不含原生 addon。套件的 sha256 是**整個 `.dittopkg` 檔案**的雜湊；安裝後展開到 `$XDG_DATA_HOME/ditto/packages/sha256/<sha256>/`（唯讀）。

SDK 的 `validate` 可驗證宣告式組合；`pack` 目前仍只支援 Cordis／QML，通過驗證不代表宣告式組合可由 SDK 打包。

Profile 的條目以 `(package, version)` 鎖定；同一 `package` 可以並存多個版本，安裝新版本不影響既有 revision（MOD-04）。
