---
name: ditto-decision-record
description: >-
  Record a Ditto decision so a later reader can tell what was chosen, on what
  evidence, and what it changed. Use when settling an item on the open-decisions
  list, closing a phase exit review, adopting a target that differs from the
  planned one, rejecting an approach worth remembering, or discovering a
  contradiction between the PRD and the implementation plan.
metadata:
  type: skill
  category: process
  status: stable
  language: zh-Hant
  related:
    - ditto-verification-evidence
---

# Ditto 決策紀錄

> 待決策落定、階段出口結果與計畫回饋的紀錄格式與存放。

## Overview

Ditto 的計畫刻意留了 20 項待決策與一整套待驗證的資源目標。這些東西會在未來 12 個月內陸續落定，而落定的當下往往只有一個人知道理由。

沒有紀錄的後果很具體：半年後有人想改合成器、想調高記憶體門檻、想重新評估 Cordis 來源，卻找不到當初為什麼這樣選，於是整件事被重新辯論一次——或者更糟，被悄悄改掉。

本 skill 的成本很低：一次決策五個欄位。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [milestones/01/05 §2 待決策清單／§4 決策紀錄格式](../../../milestones/01/05-risks-decisions.md)
- [milestones/01/03 階段出口評審檢查表](../../../milestones/01/03-phases.md)
- [PRD v0.4.0 §19.1（預算須以有紀錄的決策核定）／§25 待決策清單](../../../docs/product/Ditto-PRD-v0.4.0.md)

對應需求：NFR-06、NFR-12、AT-25

## When to Use

用於：待決策清單的 D-01～D-20 任一項落定；階段出口評審結束；核定與計畫不同的目標或門檻；否決一個值得記住的方案；發現 PRD 與實作計畫矛盾。

不適用：

- 某個數字達不達標、證據夠不夠 → `ditto-verification-evidence`。本 skill 記錄決策，那個 skill 產生決策所依據的數據。
- 一般的程式碼變更理由 → 寫在 PR 描述裡。**不是每件事都需要決策紀錄**，判準見第 1 步。

## Workflow

### 1. 先判斷這需不需要紀錄

需要紀錄：

- 待決策清單上的項目落定。
- 核定的門檻、預算或範圍**與計畫所寫的不同**。
- 一個方案被否決，而它在未來仍然會誘人（例如「為什麼不乾脆全部用 Rust 重寫」）。
- 階段出口評審。
- PRD 與 `milestones/01` 之間的矛盾及其裁決。

不需要紀錄：可以從程式碼、測試或 git 歷史讀出來的事；只影響單一 PR 的實作取捨；尚未定案的討論（那是提案，不是決策）。

**判準：半年後有人想推翻這個決定時，他需要知道什麼而程式碼裡沒有？** 答案就是紀錄的內容。

### 2. 選存放位置

| 種類 | 位置 | 檔名 |
| --- | --- | --- |
| 待決策落定 | `.agents/notes/decisions/` | `YYYY-MM-DD-<kebab-slug>.md` |
| 階段出口評審 | `.agents/notes/gate-reviews/` | `G<n>-exit.md` |

同時**回寫來源清單**：`milestones/01/05` 的對應列補上決策日期與結論摘要（一行），指向紀錄檔。只改清單不寫紀錄，或只寫紀錄不回寫清單，兩者都不算完成。

### 3. 寫決策紀錄

五個欄位，缺一不可：

```markdown
# D-02 合成器選擇

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-XX-XX |
| 狀態 | 已決定 ｜ 已推翻（指向新紀錄） |
| 決策者 | 平台工程 ＋產品 |

## 結論

（實際選擇，一句話說完。）

## 依據

（量測數據或評估結果**的位置**，不是結論的複述。沒有數據就說明是依據什麼判斷。）

## 考慮過但沒選的方案

（每個方案一行：是什麼、為什麼沒選。這一節是半年後最有價值的部分。）

## 影響

（受影響的階段、工作項與估算變動。）
```

### 4. 寫階段出口評審

五項，對應 `milestones/01/03` 的檢查表：

1. 出口門檻**逐項**結果：通過／未通過／條件通過（附條件）。不得只寫整體結論。
2. 量測數字與量測條件（版本、硬體、PID 與 cgroup 對應、採樣期間）。
3. 未達標項目的數據與調整提案。
4. 本階段產生的新風險與新決策，回寫 `milestones/01/05`。
5. 下一階段的估算修正。

### 5. 處理計畫回饋

發現 PRD 與 `milestones/01` 矛盾、或某項原則無法寫成可判斷的判準時：

1. 記入 `plan/01/05` 的回饋清單（日期｜情形｜來源位置｜處理狀態｜結論）。
2. **不得自行在 skill 或程式碼裡裁決**——那會產生第三份互相矛盾的權威。
3. 裁決後更新對應權威文件，並在此留下決策紀錄。

### 6. 驗證

- 紀錄檔的五個欄位都有實質內容，「依據」不是結論的改寫。
- `milestones/01/05` 的對應列已回寫，且指向存在的紀錄檔。
- 被推翻的舊紀錄狀態已更新並指向新紀錄；**舊紀錄不刪除**。
- 階段出口評審的門檻項目數與 `milestones/01/03` 的檢查表一致。

## Calibrated Examples

**「G0 決定採用 Wayfire。」** → 需要紀錄，且「依據」必須指向 G0 的合成器能力差異表，而不是寫「評估後認為可行」。「考慮過但沒選」要列出 Sway 與 Hyprland，並說明為何不選——因為這正是後續若 Wayfire 出問題時，第一個會被重新提起的選項。

**「待機 PSS 核定為 640 MiB，而非計畫的 600。」** → 需要紀錄。這是與計畫不同的門檻，屬於最需要留痕的一類。依據必須指向實際量測報告；影響欄要寫出這對 Agent 暖態門檻與後續階段的連帶調整。**只改 `milestones/01` 的數字而不留紀錄，就是這個專案明令禁止的「靜默調高門檻」。**

**「這次 PR 把重試次數從 3 改成 5。」** → 不需要決策紀錄，寫在 PR 描述即可。除非這個數字是某項需求的核定值（例如生成自動修復的三輪預算），那就需要。

**「我們決定不用上游 cordis 而用 Harness 的 fork。」** → 需要紀錄。這是典型的「未來仍會誘人」類型：日後有人看到上游發了穩定版就會想切回去。紀錄要寫清楚 fork 修了什麼、切回上游需要先確認什麼。

**「討論過要不要支援 X11，還沒結論。」** → 不是決策，是待決策。加進 `milestones/01/05` 的清單並設定最晚時點，不寫進 `decisions/`。

**「這個決策後來錯了，要改。」** → 寫新紀錄，把舊紀錄的狀態改為「已推翻」並互相指向。不刪除、不改寫舊紀錄的內容——當初為什麼那樣決定，跟現在為什麼要改，是兩件都值得留下的事。

## Related Skills

- `ditto-verification-evidence` — 產生決策所依據的量測數據；未達標的調整必須留下紀錄（complements）。
