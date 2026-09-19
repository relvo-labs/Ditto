# 06 — 驗收標準與自動化驗證

my-skills 目前**沒有**跨 skill 的自動化 lint 或 CI，一致性靠人工比對。Ditto 補上這一段，並把規則集設計成可回饋上游的形狀（[03 §6 D-6](03-authoring-standard.md#6-與-my-skills-標準的差異登記)）。

## 1. 驗收檢查清單（DoD）

### 每個 skill

- [ ] 目錄名 == frontmatter `name`，且有 `ditto-` 前綴、為 kebab-case。
- [ ] frontmatter 以標準 `---` 起訖，僅含 [03 §2](03-authoring-standard.md#2-frontmatter-schemayaml) 允許欄位。
- [ ] `description` 為英文、句首大寫、含 "Use when ..."、≤500 字元。
- [ ] `description` 涵蓋 [02 §4](02-skill-taxonomy.md#4-觸發矩陣) 中屬於該 skill 的情境關鍵詞。
- [ ] `metadata.category` 屬六分類；`type`、`status`、`language` 已標。
- [ ] 必要段落齊全且順序正確：`Overview`、`Authority`、`When to Use`、`Workflow`、`Related Skills`。
- [ ] `## Authority` 至少一條權威連結、至少一個需求 ID，且每個 ID 在 PRD 中存在。
- [ ] 無超過 3 行的 PRD 原文連續複製。
- [ ] `## When to Use` 含「不適用 → 導向」邊界句（出現至少一個其他 skill 名）。
- [ ] `## Workflow` 第一步指向權威章節；每個判斷點給判準而非原則複述。
- [ ] 有灰色地帶者含 `## Calibrated Examples`，且正反例皆有。
- [ ] `metadata.related` 每項指向存在的 skill；`## Related Skills` 標明關係類型。
- [ ] 標題無全大寫；主檔 ≤ ~250 行（超出已抽 `references/`）。
- [ ] 有 `references/` 者主檔含 `## References`，且每個參考檔以 `> 用途：` 開頭。
- [ ] 無 `.DS_Store`／`__pycache__`／`*.pyc`。

### 全域

- [ ] `.agents/skills/` 下存在 `AUTHORING.md`、`README.md`、`RELATIONSHIPS.md`、`.gitignore`。
- [ ] `.claude/skills` 符號連結存在且指向 `../.agents/skills`。
- [ ] 根目錄 `AGENTS.md` 存在且 ≤60 行，只做導覽不承載規則。
- [ ] `README.md` 的分類表與各 frontmatter 一致（由腳本產生）。
- [ ] `RELATIONSHIPS.md` 的明細與圖與 `metadata.related` 一致。
- [ ] 雙向關係一致（單向類型除外）。
- [ ] 每個 [02 §4](02-skill-taxonomy.md#4-觸發矩陣) 的情境至少被一個 skill 的 `description` 覆蓋。

## 2. Lint 規則

| 規則 | 檢查 | 嚴重度 | 來源 |
| --- | --- | --- | --- |
| `name-matches-dir` | `name` == 目錄名 | error | my-skills |
| `name-prefix` | 名稱以 `ditto-` 開頭 | error | Ditto |
| `frontmatter-present` | 每個 `SKILL.md` 有合法 frontmatter | error | my-skills |
| `schema-fields` | 僅含允許欄位；必填齊全 | error | my-skills |
| `description-english` | `description` 為英文起首大寫 | warn | my-skills |
| `description-use-when` | `description` 含 "Use when " | error | Ditto（強化 my-skills 的 warn） |
| `description-length` | ≤500 字元 | warn | my-skills |
| `category-enum` | `category` ∈ 六分類 | error | Ditto（分類法不同） |
| `required-sections` | 五個必要段落齊全且順序正確 | error | Ditto（強化：含順序與 `Authority`） |
| `authority-section` | `## Authority` 含 ≥1 連結與 ≥1 需求 ID | error | Ditto |
| `requirement-ids-resolve` | `## Authority` 的需求 ID 存在於 PRD，或為 `milestones/01/05` 的 `D-xx` 決策 ID | error | Ditto |
| `no-duplicated-authority` | 無 >3 行的 PRD 原文連續複製 | warn | Ditto |
| `boundary-sentence` | `## When to Use` 提及至少一個其他 skill 名 | warn | Ditto |
| `related-exists` | `related` 每項對應存在的 skill | error | my-skills |
| `related-bidirectional` | 雙向關係一致（單向類型除外） | warn | my-skills |
| `related-matches-plan` | `metadata.related` 的配對與 [02 §3 關係摘要](02-skill-taxonomy.md#3-關係摘要) 完全一致 | error | Ditto |
| `related-declared-in-body` | `related` 每項在 `## Related Skills` 出現 | warn | Ditto |
| `references-listed` | 有 `references/` ⇒ 主檔有 `## References` 且逐檔列出 | error | my-skills |
| `reference-purpose-header` | 每個參考檔以 `> 用途：` 開頭 | warn | my-skills |
| `heading-no-allcaps` | 無全大寫 `##` 標題 | warn | my-skills |
| `mainfile-length` | `SKILL.md` ≤250 行 | warn | my-skills |
| `no-cruft` | 無 `.DS_Store`／`__pycache__`／`*.pyc` | error | my-skills |
| `trigger-coverage` | 觸發矩陣提到的名稱皆在名冊內；每個已交付 skill 至少是一個情境的首要 skill | warn | Ditto |
| `index-fresh` | `README.md`／`RELATIONSHIPS.md` 與 frontmatter 產生結果一致 | error | Ditto |
| `symlink-present` | `.claude/skills` 指向 `../.agents/skills` | error | Ditto |

`requirement-ids-resolve` 是本規則集最有價值的一條：它讓「skill 引用了一個不存在的需求」在 CI 就被擋下，而不是等到有人照著做才發現。

`related-matches-plan` 讓 [02 §3](02-skill-taxonomy.md#3-關係摘要) 成為關係的單一事實來源：`RELATIONSHIPS.md` 的圖與明細由該表產生，關係類型與方向不需要從 `## Related Skills` 的散文中猜測。

## 3. Lint 腳本設計

位置 `scripts/lint-skills.mjs`。Node 實作，與專案工具鏈一致，無額外相依。

```
用法：
  node scripts/lint-skills.mjs              檢查全部規則，有 error 時 exit 1
  node scripts/lint-skills.mjs --check      同上，另驗證索引新鮮度（CI 用）
  node scripts/lint-skills.mjs --write-index 重新產生 README.md 與 RELATIONSHIPS.md
  node scripts/lint-skills.mjs --json       機器可讀輸出
```

實作要點：

0. **實作位置**：`scripts/lint-skills.mjs`，Node 22，零相依。
1. **frontmatter 解析不引入 YAML 相依**：schema 受控且簡單（純量、巢狀一層、字串陣列），自行解析並對不支援的結構明確報錯，優於引入相依後仍要驗 schema。
2. **需求 ID 索引**：啟動時掃 `docs/product/Ditto-PRD-v0.4.0.md`，以 `/\b(CON|GEN|DES|AVA|MOD|CFG|CHG|RUN|SEC|REC|NFR|AT)-\d{2}\b/g` 建立存在集合；`## Authority` 中的 ID 逐一比對。範圍寫法（`CHG-01～09`）展開後再比對。
3. **索引產生**：`README.md` 與 `RELATIONSHIPS.md` 中由標記包夾的區段才被覆寫（沿用 deepseek-harness 的 `BEGIN GENERATED ... do not edit between markers` 慣例），區段外的手寫前言保留。
4. **原文複製偵測**：把 PRD 正規化為行集合，對 skill 正文做連續 3 行以上的完全比對命中檢查。引號區塊內且鄰近有連結者放行。
5. **退出碼**：error → 1；只有 warn → 0 但輸出摘要。CI 以 `--check` 執行。

## 4. CI 整合

| 管線 | 觸發 | 內容 | 阻擋合併 |
| --- | --- | --- | --- |
| skills lint | **非 draft** 的 PR（`opened`／`synchronize`／`reopened`／`ready_for_review`），以及 push 到 `main` | `node scripts/lint-skills.mjs --check` | 是 |
| 索引新鮮度 | 同上 | `--write-index` 後 `git diff --exit-code` | 是 |

路徑條件：`.agents/**`、`docs/product/**`、`plan/01/**`、`scripts/lint-skills.mjs`、workflow 自身。

`docs/product/**` 也列入觸發條件：PRD 改動可能讓某個 skill 引用的需求 ID 消失，這正是 `requirement-ids-resolve` 要攔的情形。

**draft 期間不跑。** 草稿階段的 skill 常處於半完成狀態（`## Authority` 還沒填、related 還沒回列），此時的失敗是雜訊不是訊號。轉為 ready 時由 `ready_for_review` 補跑一次，因此不會有「一路 draft 到底、合併前從未檢查」的漏洞。push 事件限定 `main`，用意是守護預設分支，功能分支的檢查交給 PR。

## 5. 有效性抽樣測試

lint 只能證明格式正確，不能證明 skill 有用。每波交付後，以真實任務抽樣驗證：

| 抽樣任務 | 期望 | 判定 |
| --- | --- | --- |
| 「新增 `desktop.notifications.suppress` 能力」 | 命中 `ditto-capability-contract`；不需回頭讀 PRD 全文即可寫出含 `readback`、封閉錯誤集與取消語意的描述子 | Wave 1 |
| 「這個新設定存哪裡」 | 命中 `ditto-authority-boundaries`；得到明確歸屬與禁則 | Wave 1 |
| 「這批測試通過了，可以說 CHG-04 完成嗎」 | 命中 `ditto-verification-evidence`；被要求提供回讀證據與量測條件 | Wave 1 |
| 「寫一個提供待辦資料的 Cordis 插件」 | 命中 `ditto-cordis-plugin`；產出含 `inject`、effect disposer 與租約註冊 | Wave 2 |
| 「Agent 可以直接改 Profile 嗎」 | 命中 `ditto-authority-boundaries` 或 `ditto-agent-changeset`；得到否定與正確路徑 | Wave 2 |
| 「生成的面板測過了，可以啟用嗎」 | 命中 `ditto-generation-safety`；被要求確認隔離就緒與強制執行完整性 | Wave 3 |

**判定標準**：任務描述不提 skill 名稱的情況下被正確觸發，且依 skill 的 Workflow 可獨立完成判斷。未達成者，修正該 skill 的 `description` 觸發詞或 Workflow 判準，不修改抽樣任務。

## 7. 需求追溯覆蓋

`requirement-ids-resolve` 保證被引用的 ID 都存在，但不保證需求都被覆蓋。後者以下列量測回答：

```sh
# 統計 skill 正文引用的相異 PRD ID 佔 PRD 全部 ID 的比例
node -e "…"   # 見 plan/01 的交付紀錄；每波交付後重跑
```

**2026-09-19 的量測：119／148（80%）。** 未被任何 skill 引用的 29 項分為四類，皆為**刻意不覆蓋**：

| 類別 | 項目 | 理由 |
| --- | --- | --- |
| P1 範圍 | AVA-09、CFG-08、CON-12、CON-13、GEN-10、RUN-09、SEC-10 | 不作 MVP 依賴；對應 skill 在該能力進入範圍時再擴充 |
| 純功能需求，無判斷點 | DES-01／02／05／06／07／08／09、CFG-01、MOD-03、MOD-06 | 「把這個功能做出來」不需要 skill 攔截決定，對應 [02 §4](02-skill-taxonomy.md#4-觸發矩陣) 的「未覆蓋的情境」 |
| 效能指標 | NFR-01／02／03／04／10／11 | 完整清單在 [milestones/01/04](../../milestones/01/04-verification.md)；`ditto-verification-evidence` 指路而不複製，這正是 `no-duplicated-authority` 想維持的分工 |
| 驗收情境 | AT-01／03／05／08／17／21 | 各 skill 引用代表性情境即可，完整矩陣由 `milestones/01/04` 擁有 |

新增 skill 或 PRD 改版後重跑這項量測；若某個**有判斷點**的需求落進未覆蓋清單，那是 skill 集合的缺口，不是量測噪音。

## 8. 已知限制（誠實陳述）

- lint 無法判斷判準是否**正確**，只能判斷格式與引用是否成立。正確性靠 review 與抽樣測試。
- `no-duplicated-authority` 的行比對會漏掉改寫後的複製；它擋的是明顯搬運，不是所有重複。
- 抽樣測試依賴當下模型行為，結果需記錄執行日期與模型版本，不作為長期保證。
- 本計畫不驗證 skill 在其他 agent 平台（非 Claude Code）的載入行為。
- 需求追溯覆蓋率只證明 ID 被提及，不證明該需求的判斷程序寫得正確或完整。
