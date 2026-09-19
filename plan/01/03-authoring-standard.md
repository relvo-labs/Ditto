# 03 — Ditto Skill 撰寫標準

本標準是 `.agents/skills/` 的**單一事實來源**。新增或修改 skill 必須符合本文件。日常速查版摘要為 `.agents/skills/AUTHORING.md`（見 [04](04-index-and-relationships.md)）。

基底是 `../my-skills/skills/AUTHORING.md`；差異逐條登記於 [§6](#6-與-my-skills-標準的差異登記)。

## 1. 目錄與檔名

```
.agents/
  skills/
    AUTHORING.md
    README.md
    RELATIONSHIPS.md
    .gitignore
    ditto-<name>/
      SKILL.md
      references/        （選用）
.claude/
  skills -> ../.agents/skills
```

- 每個 skill 一個目錄，名稱 `kebab-case`，**必須以 `ditto-` 前綴開頭**，且**必須與 frontmatter `name` 完全相同**。
- 主檔固定 `SKILL.md`（大寫）。
- 允許的附屬目錄與 my-skills 相同六種：`references/`、`scripts/`、`templates/`、`examples/`、`data/`、`assets/`。
- `.claude/skills` 是指向 `../.agents/skills` 的符號連結（沿用 deepseek-harness 模式），使 skill 在本專案生效；**skill 檔案本身一律只寫在 `.agents/` 下**。
- 禁止納入版控：`.DS_Store`、`__pycache__/`、`*.pyc`、編輯器暫存檔。以 `.agents/skills/.gitignore` 排除。

## 2. Frontmatter Schema（YAML）

### 必填

```yaml
---
name: ditto-<kebab-case>          # == 目錄名
description: >-
  <一句說明能做什麼，接著 "Use when ..." 觸發情境。英文、句首大寫、≤ 500 字元。>
---
```

### 受控可選欄位

```yaml
metadata:
  type: skill | agent              # 預設 skill
  category: architecture | runtime | agent | shell | quality | process
  status: stable | draft | deprecated
  language: zh-Hant | en           # 正文主要語言
  related:
    - ditto-<other-name>
  version: "<semver>"
```

### 規則

- **`description` 一律英文、句首大寫、含 `"Use when ..."`**，即使正文為繁中。這是觸發與跨語言可發現性的關鍵，與 my-skills 一致。
- `description` 必須涵蓋 [02 §4 觸發矩陣](02-skill-taxonomy.md#4-觸發矩陣)中屬於該 skill 的情境關鍵詞。
- 長描述用 `>-` 折疊樣式。字串含冒號或特殊字元時才加引號。
- 未列於本 schema 的欄位一律不使用。**需求 ID 與階段追溯寫在正文 `## Authority` 段落，不擴充 frontmatter。**
- frontmatter 以標準 `---` 起訖。
- `metadata.source` 與 `license` 在本集合不使用：skill 皆為本專案原創；若未來引入外部 skill，另行登記。

## 3. 語言政策

| 元素 | 語言 |
| --- | --- |
| `description` | 英文 |
| 正文 | 繁體中文（`metadata.language: zh-Hant`），與專案文件一致 |
| 段落標題 | 英文 Title Case（骨架固定，見 §4） |
| 程式碼、識別字、指令、檔案路徑 | 英文 |
| 需求 ID、能力 ID、事件名 | 原樣（`CHG-04`、`desktop.windows.move`、`agent/pre-step`） |

## 4. 正文骨架

固定段序。`Overview`、`Authority`、`When to Use`、`Workflow`、`Related Skills` 為必要段落。

```markdown
# <Skill 顯示名稱>

> <一句定位，== 02 的單一職責句>

## Overview          (必要)  這個 skill 解決什麼問題、在什麼分層。
## Authority         (必要)  權威來源與需求 ID。見下方規則。
## When to Use       (必要)  觸發情境 ＋「不適用 → 用哪個 skill」邊界。
## Workflow          (必要)  判斷程序／檢查點，祈使句、可執行。
## Rules             (選用)  禁則與判準，do/don't。
## Calibrated Examples (選用) 校準過的正反例。
## Validation        (選用)  可執行的檢查指令。
## References        (選用；有 references/ 時必要)
## Related Skills    (必要)  列出 metadata.related 並標關係類型。
```

### `## Authority` 的規則（Ditto 專屬）

這是本標準對 my-skills 骨架的唯一擴充，用來防止 skill 變成第二份權威。

```markdown
## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §14 變更交易、熱換與回復](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/01 §3 變更交易模型](../../../milestones/01/01-architecture.md)

對應需求：CHG-01～09、CFG-05、CFG-06、CON-07
```

規則：

- 每個 skill 必須有 `## Authority`，且至少一條連結、至少一個需求 ID。
- 需求 ID 必須實際存在於 PRD（由 lint 驗證）。
- **引用 PRD 原文每處不超過 3 行**，且必須附連結。需要更長的內容，改為指路而非複製。
- skill 與權威文件衝突時，以權威文件為準，並依 [05](05-authoring-roadmap.md) 的回饋清單回報。

### `## Workflow` 的寫法

採 deepseek-harness 的祈使句與檢查點風格：

- 第一步通常是「先讀契約」——指向該情境的權威章節。
- 用編號步驟或判準清單，不用敘事段落。
- 每個判斷點給出**判準**而非原則複述。反例：「要注意權限」；正例：「呼叫身分來自受控啟動器時才接受；manifest 自述的 `plugin_id` 一律拒絕」。
- 收尾給一段可執行的驗證（指令或檢查清單）。

### `## Calibrated Examples` 的寫法

Harness 的 `dsh-archive-agent-notes` 是範本：給**正反各數例**並說明為何落在該側，讓判斷有刻度。Ditto 的 skill 在有灰色地帶時（例如「這算配置修改還是插件生成」「這個失敗算部分完成還是失敗」）必須提供校準例。

### 長度

主檔目標 **≤ ~250 行**。超出時把深度內容抽到 `references/<topic>.md`，主檔加 `## References` 列出每檔一句用途；每個參考檔以 `> 用途：...` 開頭。

## 5. Related Skills 慣例

- 關係類型沿用 my-skills 五種：**complements** / **generalizes** / **specializes** / **consumes** / **reviews**。
- `metadata.related` 預設雙向；單向關係（`generalizes`／`specializes`／`consumes`／`reviews`）在 `## Related Skills` 標明方向。
- 格式：

```markdown
## Related Skills

- `ditto-authority-boundaries` — 所有權裁決的上游總則（specializes 它）。
- `ditto-changeset-transaction` — 交易流程，與本 skill 併用（complements）。
```

## 6. 與 my-skills 標準的差異登記

| # | 差異 | 理由 | 回饋上游的建議 |
| --- | --- | --- | --- |
| D-1 | 位置為 `.agents/skills/` 並以 `.claude/skills` 符號連結生效，而非 `skills/` | my-skills 是策展工作區（自承「修改不會改變環境行為」）；Ditto 需要**專案內實際生效**。採 deepseek-harness 已驗證的模式 | 建議 my-skills 的 AUTHORING 增補「策展集合 vs 專案內集合」兩種佈局 |
| D-2 | `metadata.category` 使用 Ditto 專案分類法（architecture／runtime／agent／shell／quality／process），而非 my-skills 的六分類 | my-skills 分類是題材導向（design-ui／backend／…），對單一專案的工程分層不具區辨力 | 建議上游允許 repo-local category enum，並在集合根的 `AUTHORING.md` 宣告 |
| D-3 | 新增必要段落 `## Authority` | Ditto 的核心原則是「權威只有一份」；skill 必須指路而非複製，否則會與 PRD 各自演化 | 建議上游將其列為**選用**段落，供有外部權威文件的專案使用 |
| D-4 | 名稱強制 `ditto-` 前綴 | 與可能同時安裝的通用 skill 區隔，避免命名碰撞 | 建議上游將「專案內集合建議加前綴」寫入標準 |
| D-5 | 不使用 `metadata.source` 與 `license` | 本集合皆為原創，無上游來源與授權宣告 | 無 |
| D-6 | 補上 my-skills 尚未實作的 lint 與 CI | my-skills 自承無自動化守門，一致性靠人工 | **可直接回饋**：Ditto 的 `scripts/lint-skills.mjs` 規則集可移植為 my-skills 的 `lint_skills.py` 實作 |

**刻意不偏離的部分**：frontmatter 必填欄位、`description` 英文與 "Use when ..." 句式、正文段序與段名、`When to Use` 的邊界句要求、六種附屬目錄、≤250 行、關係五詞彙、禁止納管檔案清單。

## 7. 撰寫檢查表

每個 skill 完成前逐項確認（可自動化者見 [06](06-acceptance-and-validation.md)）：

- [ ] 目錄名 == `name`，有 `ditto-` 前綴。
- [ ] `description` 英文、含 "Use when ..."、≤500 字元、涵蓋觸發矩陣關鍵詞。
- [ ] `metadata` 僅含允許欄位；`category` 屬六分類；`status`、`language` 已標。
- [ ] 必要段落齊全：Overview／Authority／When to Use／Workflow／Related Skills。
- [ ] `## Authority` 有連結與需求 ID，且 ID 在 PRD 中存在。
- [ ] 沒有超過 3 行的 PRD 原文複製。
- [ ] `When to Use` 含「不適用 → 導向」邊界句。
- [ ] `Workflow` 第一步指向權威章節；每個判斷點有判準而非原則複述。
- [ ] 有灰色地帶者提供校準正反例。
- [ ] `metadata.related` 每項存在，且雙向一致。
- [ ] 主檔 ≤ ~250 行；有 `references/` 者主檔含 `## References`。
- [ ] 索引 `README.md` 與 `RELATIONSHIPS.md` 已同步。
