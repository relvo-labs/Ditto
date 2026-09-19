# Ditto Agent Skills 建置計畫（plan/01）

本計畫定義如何在 Ditto 專案的 `.agents/skills/` 建立一組**專案內生效**的 agent skills，把 [PRD v0.4.0](../../docs/product/Ditto-PRD-v0.4.0.md) 與 [實作計畫 milestones/01](../../milestones/01/README.md) 中的開發原則，轉成 agent 在動手前會實際讀到的判斷程序。

計畫的結構與撰寫標準沿用 `../my-skills` 的通用 skill 規範；差異之處逐條登記於 [03-authoring-standard.md](03-authoring-standard.md#6-與-my-skills-標準的差異登記)。

## 背景

Ditto 目前有三份權威資產：PRD（需求）、`milestones/01`（實作順序）、前端原型（互動契約參考）。但沒有 `.agents/`：agent 在寫程式碼時無法被自動導向這些原則，只能靠人每次手動貼上下文。

PRD 的多數需求是**禁則與判斷程序**而非功能描述——「Cordis 不得保存第二份正式 Profile」「完成判斷依系統回讀」「隔離未就緒前只允許受限宣告式模板」「不得靜默調高門檻」。這類規則不寫進 skill，就只能靠 review 抓；而 review 抓到時通常已經寫完了。

## 目標

1. **原則可觸發** — 讓「新增一項能力」「寫一個 Cordis 插件」「宣稱某項完成」等工作情境，自動命中對應 skill。
2. **權威不重複** — skill 提供判斷程序與檢查點，**不複製 PRD 內容成為第二份權威**；這與專案本身「權威只有一份」的原則一致。
3. **與通用標準相容** — 沿用 `../my-skills` 的 frontmatter schema、正文骨架、關聯詞彙與索引慣例，差異逐條登記並可回饋上游。
4. **可驗證** — 補上 my-skills 目前缺少的自動化守門：lint 腳本與 CI 檢查。

## 計畫文件結構

| 文件 | 內容 |
| --- | --- |
| [README.md](README.md) | 本檔。計畫總覽、目標、導讀、範圍界線。 |
| [01-current-state-analysis.md](01-current-state-analysis.md) | 現況盤點：Ditto 資產、my-skills 標準、deepseek-harness `.agents` 模式、四項落差。 |
| [02-skill-taxonomy.md](02-skill-taxonomy.md) | 分類法、15 個 skill 的單一職責句與邊界、觸發矩陣。 |
| [03-authoring-standard.md](03-authoring-standard.md) | Ditto 撰寫標準：目錄、frontmatter、正文骨架（含 `## Authority`）、語言政策、與 my-skills 的差異登記。 |
| [04-index-and-relationships.md](04-index-and-relationships.md) | 索引與關聯地圖的設計與範本。 |
| [05-authoring-roadmap.md](05-authoring-roadmap.md) | 三波次撰寫路線圖、逐 skill 待辦、與 `milestones/01` 階段的對應。 |
| [06-acceptance-and-validation.md](06-acceptance-and-validation.md) | 驗收標準、lint 規則、lint 腳本設計、CI 整合、有效性抽樣測試。 |

建議閱讀順序：`01`（問題）→ `02`（要寫哪些、邊界在哪）→ `03`（怎麼寫）→ `04`（怎麼索引）→ `05`（何時寫）→ `06`（怎麼驗收）。

## 交付物一覽

計畫執行後，倉庫會多出：

```
.agents/
  skills/
    AUTHORING.md          撰寫標準速查（03 的摘要版）
    README.md             分類索引
    RELATIONSHIPS.md      關聯地圖
    .gitignore
    ditto-<name>/SKILL.md ×15（分三波交付）
  notes/                  決策紀錄（Wave 2 隨 ditto-decision-record 建立）
.claude/
  skills -> ../.agents/skills    （符號連結，使 skill 在本專案生效）
scripts/
  lint-skills.mjs         自動化守門
```

## 範圍界線

**納入**：skill 集合的分類、職責邊界、撰寫標準、索引與關聯、分波路線圖、驗收與 lint。

**不納入**：

- 各 skill 的正文內容本身——本計畫只定義寫什麼、邊界在哪、怎麼驗收；實際撰寫在 [05](05-authoring-roadmap.md) 的三波次執行。
- 修改 `../my-skills`——差異只做登記與回饋提案，不在本計畫動上游。
- 修改 PRD 或 `milestones/01`——若撰寫過程發現原則矛盾，記入 [05](05-authoring-roadmap.md) 的回饋清單，由產品裁決。
- 通用 skill 的引入（例如 `goal-mode`、`pict-test-designer`）——那是使用者環境的安裝決定，不是本專案的交付物。

## 一句話說明這組 skill 的分寸

skill 不是把 PRD 再寫一遍，而是**在 agent 即將做出違反原則的決定之前，把那個決定攔下來，並指向權威文件的對應章節**。
