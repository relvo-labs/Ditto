# 01 — 現況盤點與落差

## 1. Ditto 專案現況

| 資產 | 狀態 | 對 skill 的意義 |
| --- | --- | --- |
| `docs/product/Ditto-PRD-v0.4.0.md` | 完整，712 行、26 節、116 項需求、32 組驗收 | 需求權威。skill 必須引用而非複製 |
| `milestones/01/`（7 份，1164 行） | 完整，G0～G5 分階段計畫 | 實作順序權威。skill 的判斷程序多數源自此 |
| `docs/research/RESEARCH-AND-INTERACTION.md` | 完整 | 互動決策依據 |
| `apps/desktop-prototype/` | 凍結為互動契約參考 | skill 需說明「可沿用契約、不可沿用實作」的界線 |
| `.agents/` | **不存在** | 本計畫的建置目標 |
| `.claude/` | **不存在** | 需建立 `skills` 符號連結使 skill 生效 |
| `CLAUDE.md` / `AGENTS.md` | **不存在** | 見 §4 落差 G-4 |
| `scripts/` | **不存在** | lint 腳本的落點 |
| 程式碼 | 只有前端原型；Rust／Cordis／QML 尚未開工 | **時機正確**：skill 在第一行實作程式碼之前就位，成本最低 |

**關鍵觀察**：專案處在「原則已寫清楚、實作尚未開始」的狀態。這是建立 skill 的最佳時點——G0 一旦開工，契約管線、量測工具與程序邊界會同時被寫下，此時若無 skill 導引，後續要改的是已經長出來的結構。

## 2. `../my-skills` 通用標準盤點

`my-skills` 是個人策展工作區，收錄 18 個 skill，並已產出三份標準文件。

| 文件 | 內容 | 對本計畫的採用 |
| --- | --- | --- |
| `skills/AUTHORING.md` | frontmatter schema、正文骨架、目錄慣例、語言政策、關聯詞彙 | **全面採用**，差異逐條登記 |
| `skills/README.md` | 依 category 分組的一覽表 | 採用格式 |
| `skills/RELATIONSHIPS.md` | 五種關係（complements／generalizes／specializes／consumes／reviews）＋Mermaid 圖 | **採用詞彙與圖式** |
| `plan/01/` 七份文件 | 現況→分類→標準→索引→路線圖→驗收 | **採用計畫結構**（本計畫即同一形狀） |

要點：

- **`description` 一律英文、句首大寫、含 `"Use when ..."`**，即使正文為繁中。這是跨語言可發現性與觸發一致性的規則。
- 正文骨架固定段序：`Overview` → `When to Use` → `Workflow` →（選用段）→ `Related Skills`。前三段與最後一段為必要。
- `When to Use` 必須含「不適用 → 導向哪個 skill」的邊界句。
- 主檔目標 ≤ ~250 行，深度內容抽到 `references/`。
- 允許的附屬目錄固定六種：`references/`、`scripts/`、`templates/`、`examples/`、`data/`、`assets/`。
- **已知限制**：`my-skills` **沒有自動化 lint 或 CI**，一致性靠人工比對；其 `plan/01/06` 中的 `lint_skills.py`／`build_index.py` 仍是規劃骨架。

## 3. `../deepseek-harness/.agents` 模式盤點

Harness 是本專案的底座來源，其 `.agents` 是「專案內生效」的實作範例。

| 面向 | Harness 做法 | 本計畫評估 |
| --- | --- | --- |
| 位置 | `.agents/skills/<name>/SKILL.md`，並以 `.claude/skills -> ../.agents/skills` 符號連結生效 | **採用**。同時滿足使用者「寫在 `.agents` 中」的要求與 Claude Code 的載入路徑 |
| 命名 | 全部 `dsh-` 前綴（12 個） | **採用同形**，Ditto 用 `ditto-` 前綴 |
| frontmatter | 只有 `name` 與 `description`，無 `metadata` 區塊 | **不採用**。改採 my-skills 的 `metadata`（不影響載入，換得索引與關聯能力） |
| `description` | 長句、大量觸發關鍵字並列 | **採用寫法**，但受 my-skills 的 ≤500 字元與 "Use when ..." 句式約束 |
| 正文 | 祈使句、任務導向標題（`Read the contracts`／`Classify by future value`／`Archive one implemented triplet`）、校準過的正反例 | **採用語氣與校準例**，但段落骨架改用 my-skills 的固定段序 |
| 與文件的關係 | skill 一開頭就要求「先讀契約」，並以相對路徑指向 `AGENTS.md`、`docs/` | **採用**，這正是「不重複權威」的實作方式 |
| 驗證 | skill 內嵌可執行的驗證指令（`pnpm run verify-...`） | **採用**，Ditto 的 skill 應指向實際可跑的檢查 |

`dsh-archive-agent-notes` 是最值得模仿的樣本：它不重述規則，而是**先叫 agent 讀契約，再給分類判準、校準過的正反例、以及一段可執行的收尾程序**。

## 4. 落差

| # | 落差 | 影響 | 本計畫的處理 |
| --- | --- | --- | --- |
| G-1 | **原則無法觸發**。PRD 的禁則散在 26 節內，agent 不會主動去讀 | 違反原則的程式碼要到 review 才被發現，且常常已寫完 | 15 個 skill＋觸發矩陣（[02](02-skill-taxonomy.md#4-觸發矩陣)） |
| G-2 | **通用標準缺自動化守門**。my-skills 自承無 lint／CI | 集合長大後一致性必然漂移 | 交付 `scripts/lint-skills.mjs`＋CI（[06](06-acceptance-and-validation.md)） |
| G-3 | **兩種 skill 風格並存**（my-skills 的策展骨架 vs Harness 的任務祈使句） | 直接混用會產生格式不一的集合 | 明確裁決：骨架用 my-skills，語氣與校準例用 Harness（[03](03-authoring-standard.md)） |
| G-4 | **無 `AGENTS.md`／`CLAUDE.md`**。skill 需要一份「先讀什麼」的入口 | skill 各自指路，重複且易漂移 | 列為 Wave 1 的前置交付：根目錄 `AGENTS.md` 只做導覽，不承載規則（[05](05-authoring-roadmap.md)） |
| G-5 | **skill 有變成第二份權威的風險**。PRD 內容被複製進 skill 後會與 PRD 各自演化 | 出現兩份互相矛盾的「規則」 | `## Authority` 必要段落＋`no-duplicated-authority` lint 規則（[03](03-authoring-standard.md#4-正文骨架)、[06](06-acceptance-and-validation.md#2-lint-規則)） |

## 5. 不做的事

- 不把 PRD 的需求表搬進 skill。skill 引用需求 ID 與章節連結，正文只寫判斷程序。
- 不為尚未存在的程式碼寫「怎麼改這個檔案」型 skill。Wave 2、Wave 3 的 skill 刻意延後到對應子系統成形後再寫（見 [05](05-authoring-roadmap.md)）。
- 不改 `../my-skills`。差異只登記與提出回饋建議。
