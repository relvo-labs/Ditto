---
name: ditto-upstream-port
description: >-
  Record and constrain every port of upstream code into Ditto: pin the commit,
  classify the port kind, log each local modification, state the host contract
  and trust level, carry the licence obligations, and list the test matrix. Use
  when vendoring or updating Cordis, porting a DeepSeek Harness package,
  adopting any third-party source, or reviewing an upstream sync.
metadata:
  type: skill
  category: process
  status: stable
  language: zh-Hant
  related:
    - ditto-cordis-plugin
    - ditto-release-audit
---

# Ditto 上游移植

> 從 Cordis、Harness 或其他上游取用程式碼時的分類、紀錄與義務。

## Overview

Ditto 的底座有很大一部分是移植來的：Cordis 插件框架、Harness 的模型適配器、工具流水線與會話儲存。移植省下的時間是真的，但它把兩個成本延後了——上游變動時要知道自己改過什麼，以及發行時要交代每一份程式碼的來源與授權。

這兩件事都無法事後補做。修改集沒有逐條記錄，半年後沒有人分得出哪些是上游的、哪些是我們改的；授權沒有在取用當下盤點，發行前的審查會變成考古。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §9 插件生成與移植需求](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §24.1 發行要求](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/02 §1 來源與版本鎖定／§5 移植紀錄要求](../../../milestones/01/02-cordis-adoption.md)

對應需求：MOD-01、MOD-04、GEN-09、AT-18

## When to Use

用於：vendored 引入或更新 Cordis；移植 Harness 套件；取用任何第三方原始碼；審查一次上游同步。

不適用：

- 移植進來的 Cordis 插件怎麼寫 → `ditto-cordis-plugin`。
- 發行前的整體授權與交付物審查 → `ditto-release-audit`。
- 這次移植要不要做、屬於哪個階段 → `milestones/01` 的階段安排。

## Workflow

### 1. 先讀權威

打開 `milestones/01/02 §1` 與 `§5`。Cordis 的來源決策與紀錄欄位在那裡；本節給的是每次移植要走的程序。

### 2. 分類這次移植

| 類型 | 意思 | 代價 |
| --- | --- | --- |
| 直接沿用 | 原封不動使用 | 最低；上游更新容易 |
| 薄轉接 | 外面包一層適配，內部不改 | 低；轉接層要自己測 |
| 修改移植 | 改動上游原始碼 | **高**：每次同步都要重新套用修改集 |
| 保留外部宿主 | 不進我們的程序，透過協定使用 | 中；多一個程序邊界 |

**優先序由上而下。** 選到「修改移植」時要說明為什麼薄轉接不行——這個決定會在往後每一次上游同步時收費。

### 3. 固定來源

每個移植套件都要記錄，缺一項就不算完成：

```
package            上游套件名與版本
upstream_repo      倉庫位置
upstream_commit    固定 commit（不是分支、不是 tag 範圍）
port_kind          直接沿用 | 薄轉接 | 修改移植 | 保留外部宿主
modifications      修改摘要，逐條
host_contract      執行於哪個宿主
trust_level        信任等級
license            授權與 NOTICE 義務
test_matrix        對應測試與實際結果
```

**不得依浮動版本上線。** 上游標示 API 尚未穩定時尤其如此——Cordis 目前就是這個狀態。

### 4. 修改集要逐條可查

每一處與上游的差異都要列出：改了什麼檔案、為什麼、上游若修好了能不能撤掉。

判準：**上游發布新版時，有人能不能只看這份紀錄就重新套用所有修改？** 不能 → 紀錄不夠細。

每條修改要標註退場條件（「上游合併 PR #NN 後可移除」），否則修改集只會單向變長。

### 5. 沿用範圍要分四欄

對每個移植來的框架，維持「直接沿用 / 新增 Ditto 橋接 / Rust 原生能力 / 尚未支援」的對照表。

**「尚未支援」欄是重點**：任何文件都不得把 Ditto 新增的東西描述成上游既有能力。Cordis 沒有提供桌面交易、跨程序沙箱、配置回復與跨宿主租約——這些是我們加的，要寫在我們這一欄。

### 6. 不為統一語言而重寫

不得為了追求單一語言，把已經可以沿用的插件全部重寫。判準是**這次重寫解決了什麼具體問題**；「用同一種語言比較整齊」不是問題。

反向也成立：需要 Rust 權威保證的東西不要因為「TS 那邊有現成的」就留在宿主裡。兩邊的邊界見 `ditto-authority-boundaries`。

### 7. 授權義務隨程式碼走

- 保存適用的 LICENSE、NOTICE、來源、修改說明與必要散布資料。
- **不得把主專案授權套用到所有插件。**
- 生成或移植的程式碼保留可追溯來源；**不得宣稱自動生成即免除上游義務**。

### 8. 同步程序

更新一個已移植的套件時：

1. 記下上游新的 commit。
2. 覆蓋原始碼。
3. **重新套用修改集**——或在上游已修好時撤掉該條，兩種情況都要更新紀錄。
4. 更新版本與 commit。
5. 跑完整測試與建置。

### 9. 驗證

- 三類上游能力（模型適配器、工具、會話）實際運行，且功能、來源、相容性與修改皆可追溯（AT-18）。
- 每個移植套件的紀錄九個欄位齊全。
- 四欄沿用對照表與實際程式碼一致。
- 授權盤點可交給 `ditto-release-audit` 直接彙整。

## Calibrated Examples

**沿用 Harness 的 Cordis fork 而非上游** → 這是「直接沿用」加一份明確理由：fork 已修復可重入卸載的缺口，而 Ditto 的交易式卸載直接依賴那些性質。紀錄要寫清楚 fork 修了什麼、以及將來切回上游需要先確認什麼——否則上游發穩定版時會有人想直接切過去。

**Harness 的 session 儲存要接到 Ditto 的 Core** → 「薄轉接」：實作一個 Core 支援的持久化提供方，上游的 session 介面不改。**不要**改上游原始碼讓它直接寫我們的資料庫——那會把每次同步的成本變成永久的。

**上游某個函式差一個參數才夠用** → 先試薄轉接（外面包一層補上）。真的非改不可才進「修改移植」，並在修改集裡寫明退場條件：上游接受了對應的 PR 之後就撤掉。

**「這個套件我們只用了兩個函式，抄過來就好。」** → 抄過來也是移植，一樣要記錄來源、commit 與授權。省略紀錄不會讓授權義務消失，只會讓發行前的審查找不到它。

**上游更新了，衝突很多，乾脆重寫一份** → 先確認重寫解決了什麼。若答案是「不用再處理衝突」，那是把一次性成本換成永久的維護責任，而且失去上游後續的修正。這個決定需要走 `ditto-decision-record`。

**把某個 Harness 套件的 README 直接複製過來當我們的文件** → 不行。它描述的是上游的宿主與契約，我們的宿主不同。要寫我們自己的，並在來源欄指向上游。

## Related Skills

- `ditto-cordis-plugin` — 移植進來的 Cordis 套件同時受兩者約束（complements）。
- `ditto-release-audit` — 發行審查彙整各套件的移植紀錄（reviews：那裡 consumes 本 skill 的產出）。
