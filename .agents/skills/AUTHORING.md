# Ditto Skill 撰寫標準

日常速查。完整理由與對 `my-skills` 通用標準的差異登記見 [plan/01/03-authoring-standard.md](../../plan/01/03-authoring-standard.md)。

## 目錄與檔名

- 一個 skill 一個目錄，`kebab-case`，**必須以 `ditto-` 開頭**，且**必須等於 frontmatter `name`**。
- 主檔固定 `SKILL.md`。skill 檔案一律只寫在 `.agents/` 下；`.claude/skills` 是指向 `../.agents/skills` 的符號連結。
- 允許的附屬目錄：`references/`、`scripts/`、`templates/`、`examples/`、`data/`、`assets/`。
- 禁止納入版控：`.DS_Store`、`__pycache__/`、`*.pyc`、編輯器暫存檔。

## Frontmatter

```yaml
---
name: ditto-<kebab-case>          # == 目錄名
description: >-
  <一句說明能做什麼，接著 "Use when ..." 觸發情境。英文、句首大寫、≤ 500 字元。>
metadata:
  type: skill | agent             # 預設 skill
  category: architecture | runtime | agent | shell | quality | process
  status: stable | draft | deprecated
  language: zh-Hant | en
  related:
    - ditto-<other-name>
  version: "<semver>"             # 選用
---
```

- `description` **一律英文**，即使正文為繁中；必須含 `"Use when ..."`，並涵蓋 [觸發矩陣](../../plan/01/02-skill-taxonomy.md#4-觸發矩陣) 中屬於該 skill 的情境關鍵詞。
- 未列於上方的欄位一律不使用。**需求 ID 寫在 `## Authority`，不擴充 frontmatter。**
- `metadata.related` 必須與 [plan/01/02 §3 關係摘要](../../plan/01/02-skill-taxonomy.md#3-關係摘要) 一致，且雙向回列。

## 語言

正文繁體中文；段落標題英文 Title Case；程式碼、識別字、指令、路徑英文；需求 ID 與能力 ID 原樣。

## 正文骨架

固定段序，**粗體為必要**：

```
# <顯示名稱>
> <一句定位，== plan/01/02 的單一職責句>

**## Overview**          解決什麼問題、在什麼分層
**## Authority**         權威來源與需求 ID（見下）
**## When to Use**       觸發情境 ＋「不適用 → 用哪個 skill」邊界
**## Workflow**          判斷程序與檢查點，祈使句、可執行
## Rules                 選用：禁則與判準
## Calibrated Examples   有灰色地帶時必寫：正反例與落在哪側的理由
## Validation            選用：可執行的檢查
## References            有 references/ 時必寫
**## Related Skills**    列出 related 並標關係類型
```

主檔目標 **≤ 250 行**；超出時把深度內容抽到 `references/<topic>.md`，每個參考檔以 `> 用途：` 開頭。

## `## Authority` 的規則

這是 Ditto 專屬的必要段落，用來防止 skill 變成第二份權威。

```markdown
## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §14 變更交易、熱換與回復](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/01 §3 變更交易模型](../../../milestones/01/01-architecture.md)

對應需求：CHG-01、CHG-02、CHG-04
```

- 至少一條連結、至少一個需求 ID；ID 必須實際存在於 PRD（或 `milestones/01/05` 的 `D-xx`），由 lint 驗證。
- **引用 PRD 原文每處不超過 3 行**，且必須附連結。需要更長的內容改為指路。
- skill 與權威文件衝突時以權威文件為準，並依 `ditto-decision-record` 回報。

## `## Workflow` 的寫法

- 第一步通常是「先讀權威」，指向該情境的章節。
- 編號步驟或判準清單，不寫敘事段落。
- 每個判斷點給**判準**而非原則複述。反例：「要注意權限」；正例：「呼叫身分來自受控啟動器時才接受；manifest 自述的 `plugin_id` 一律拒絕」。
- 收尾給可執行的驗證。

## Related Skills

關係類型五種：**complements** / **generalizes** / **specializes** / **consumes** / **reviews**。

```markdown
## Related Skills

- `ditto-authority-boundaries` — 所有權裁決的上游總則（specializes 它）。
- `ditto-changeset-transaction` — 交易流程，與本 skill 併用（complements）。
```

## 驗證

```sh
node scripts/lint-skills.mjs               # 檢查
node scripts/lint-skills.mjs --write-index # 重新產生 README.md 與 RELATIONSHIPS.md
```

完整規則表與驗收清單見 [plan/01/06](../../plan/01/06-acceptance-and-validation.md)。
