# #139／#141 — SDK 與 Rust manifest 契約對齊計畫 v0.2

本計畫保留第一個 checkpoint 的依據，並增補 #141 的宣告式預設值修正；驗證狀態依下表記錄。

- M/T2；base `e2dfd644ac54b75921f6c4ac8042d42cb04d084a`。來源缺陷不是 #138 網路修正新增。使用者既有授權包含發現新問題要處理；此修復只對齊既有權威，不新增／猜測預算或改 Core 政策。
- Rust `ResourceBudget` 兩欄皆 `Option<u32>`，serde default/skip-none，deny_unknown_fields（manifest.rs:106-112）；生成 schema/manifest.json 無 required，兩欄接受 integer/null。SDK rules.ts:243-248 卻強制兩欄為 number。
- 全部11個 builtin：7個QML providers只有memory_mib；2個service兩欄都有；2個declarative沒有budget。程式盤點在 task evidence/frozen-builtins.json，不把9個子集當作全部。
- Core preflight 只對有值的欄位比政策上限，未填不等於核准無上限；SDK service ceiling 64MiB/10%維持，不修改任一manifest值。
- builtin QML/declarative pack_dir 直接tar；Cordis才經SDK pack→validate，故「全部打包成功」沒有驗證所有QMLmanifest。此計畫不擴張為重寫打包流程。

## 步驟與驗收
1. 完整讀 selected skills/權威，以真SDK validate及既有內建panel建立同一behavioral RED。檢查Rust/schema的presence/null與數值範圍；不猜政策。
2. 最小修改SDK budget驗證；保留每個明確宣告值的型別／數值域／封閉key與service cap拒絕。不因任一欄缺少就跳過另一個欄位的cap檢查。缺budget、空object、單欄、雙欄、null欄位、0、合法u32邊界/過大/負數/小數/非finite/錯型/未知key均需matrix，按權威確定預期，不自行收緊合法資料。
3. 測試inventory納入全部builtin實際producer；真SDK validate/pack的panel正向witness與錯budget反向control，schema有/無兩路一致。必要文件只澄清既有optional語意。
4. 聚焦GREEN、SDK完整tests/typecheck/build、受影響workspace/consumer gates；不改Rust/schema/manifest內容除非證據顯示生成漂移，且先報告。
5. 首個coherent commit後coordinator push Draft；fresh獨立review後另由#138整合已驗證fix並重跑原REDgate。不能因#139提交就宣稱#138VM已修。

## 非目標
不變更資源上限或配置值、不設定預設CPU、不跳過validator、不借用新#138 native module安裝、不更改原生addon／分發政策、不碰#134/#137、VM或憑證。若正確契約仍需新owner預算／政策決策，停止，不以測試通過取代核准。

## Checkpoint 2：#141 宣告式預設值

- 起點為 `ac998929b369bd24f3dd441c324d15792e924563`（Draft PR #140）；#139 的 100 項預算矩陣已通過，完整 SDK 為 141 通過／1 失敗，舊證據保留。
- Rust `Manifest` 的 serde default／生成 schema 是依據：runtime `{}`、所有 Vec 欄位 `[]`、config_schema `{ "type": "object" }`。僅對正確的 `declarative_bundle/core_builtin` 組合採用；明確 null／錯型不套預設值。runtime 內的 Option 成員依 Rust 可為 null。
- Rust 預設值也適用其他種類，但本次不擴張 service／QML SDK 必填條件。保留必要身分、版本、信任、kind/host、health／cleanup／idle、入口與政策檢查；空 permissions 不授予任何權限。
- Caller map：`validateManifest` 由 `validatePackage` 呼叫；後者由 CLI validate 與 pack 呼叫。SDK pack 仍只支援 Cordis／QML，不新增 declarative pack。所有 builtin 原檔保持不變。
- 順序：在先前 HEAD 建立兩個實際 builtin CLI 與逐欄預設值 RED → 最小規則／測試／文件修正 → 完整 30 份 inventory 雙 schema、SDK tests/typecheck/build、預算與 CLI、反向相依 gates → 全綠新 commit `[skip ci]` 後停止，交 coordinator 發布與獨立 review。

| 追蹤列 | Checkpoint 1／先前 HEAD | Checkpoint 2 |
| --- | --- | --- |
| #139 optional／u32 預算、panel validate／pack | GREEN；100 預算 controls 通過 | GREEN；100 controls 與 panel 雙 schema validate／pack 重跑通過 |
| #141 floating／simple-tile 原始 CLI validate | 各 exit 1；缺 10 個 defaulted 欄位 | GREEN；兩個原始 builtin 在 schema 有／無兩路皆通過，pack 仍以不支援拒絕 |
| #141 default omissions／explicit defaults 與明確非法宣告 | defaults＋CLI 197 項，41 失敗／156 通過，exit 1 | GREEN；同組 197／197，exit 0（其中 defaults 186、CLI 11） |
| 全部 11 builtin／完整 30 manifest，雙 schema | 2 個 declarative 失敗；SDK 141／1 | GREEN；60 次 manifest 驗證全通過；完整 SDK 332／332、typecheck／build exit 0 |
| 獨立 review／#138 整合與 VM | 尚未執行 | 由 coordinator 後續驗證 |

三個反向相依套件已在本候選來源重跑：20 項 tests、typecheck、build 全部 exit 0，未沿用先前通過宣稱。原始 RED、逐指令退出碼／來源雜湊與 #141 狀態表位於 `/data/hermes/ditto-runs/g4-impl/b12/sdk139/run2-defaults/writer/`；第一個 checkpoint 的 raw logs 保持不變。本紀錄屬實作驗證，不代表獨立 review 或 #138 VM 已通過。
