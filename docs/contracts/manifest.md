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
| `config_schema` | 強制 | JSON Schema（draft 2020-12 的子集：`type`、`properties`、`required`、`enum`、`items`、`default`、`minimum`、`maximum`、`additionalProperties`）；`set_entry_config` 與 `add_entry` 的 config 依它驗證 |
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
| `resource_budget` | 記錄＋比對 | `{ "memory_mib": 20, "cpu_percent": 5 }`；超過政策上限（服務類 64 MiB、10%）→ `budget_exceeded` |
| `rescue` | 記錄 | `{ "disable_safe": true }`：`dittoctl rescue disable` 可以直接停用它 |

## 套件格式 `.dittopkg`（D-10 提案）

tar ＋ zstd，根目錄有 `manifest.json`，其餘是 `dist/`（cordis）或 `qml/`（qml）。Cordis 插件必須是**單一 ESM bundle**，不含 `node_modules`，不含原生 addon。套件的 sha256 是**整個 `.dittopkg` 檔案**的雜湊；安裝後展開到 `$XDG_DATA_HOME/ditto/packages/sha256/<sha256>/`（唯讀）。

Profile 的條目以 `(package, version)` 鎖定；同一 `package` 可以並存多個版本，安裝新版本不影響既有 revision（MOD-04）。
