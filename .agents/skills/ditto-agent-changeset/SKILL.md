---
name: ditto-agent-changeset
description: >-
  Turn a user request into a validated Ditto ChangeSet instead of guessing:
  discover capabilities and schemas at run time, never invent a command, pick
  the cheapest of the three change paths, handle vague targets, track the base
  revision, show real phases, and recover after a disconnect. Use when
  implementing or reviewing Agent intent parsing, tool calls, planning,
  multi-turn corrections, or what the Agent reports back.
metadata:
  type: skill
  category: agent
  status: stable
  language: zh-Hant
  related:
    - ditto-changeset-transaction
    - ditto-generation-safety
---

# Ditto Agent 規劃

> Agent 從自然語言到結構化 ChangeSet 的規劃行為。

> **status: stable** — 2026-10-08 依 G2-AGENT-01／05 核對：Agent 每個 turn 從 `desktop.capabilities.list` 取可用能力，只開放有 Ditto 工具說明的那些（`packages/agent-runtime/src/tools.ts`、`tool-catalog.ts`），目錄外的呼叫回 `unsupported call`；Codex 內建工具由 Core 衍生的模型目錄關閉。第 6 步的最近目標由 Core 在 claim 時附上（`recent_changes`），第 10 步的恢復以 turn trace 與開機對帳實作（`agent.turns.trace`、`turns::reconcile_dispatched`）。語意行為仍待真實模型的 QA-01 評分。

## Overview

Agent 在 Ditto 裡的角色比一般助理窄：它**提出計畫**，不執行權威寫入。所有輸出都要先變成結構化 ChangeSet，經 Core 的確定性驗證才會碰到桌面。

窄，是因為模型會做三件危險的事：憑空產生不存在的命令、把自己說過的話當成已經發生的事實、以及在使用者剛調整過設定之後覆蓋掉它。這三件事各有對應的機制，本 skill 把它們變成寫程式時的判準。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §7 對話與意圖執行需求](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §8 三條桌面改造路徑](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §15.4 宿主與 Agent 生命週期](../../../docs/product/Ditto-PRD-v0.4.0.md)

對應需求：CON-01、CON-02、CON-03、CON-04、CON-05、CON-06、CON-07、CON-08、CON-09、CON-10、CON-11、CFG-06、RUN-03、RUN-04、NFR-13、AT-24

## When to Use

用於：實作或審查 Agent 的意圖解析、工具呼叫、規劃、多輪修正、進度與結果回報；Agent 重啟後的恢復。

不適用：

- ChangeSet 的驗證、套用、回讀與回復 → `ditto-changeset-transaction`。
- 生成新插件的安全規則 → `ditto-generation-safety`。
- 授權範圍與是否要問 → `ditto-permission-and-secrets`。
- 回覆與狀態文字怎麼寫 → `ditto-prose-standard`。

## Workflow

### 1. 先讀權威

打開 PRD §7 與 §8。本節只給實作判準。

### 2. 能力從目錄取得，不從記憶取得

每次規劃前**動態取得能力目錄與 schema**。模型不得憑記憶或訓練資料產生命令名稱。

- 目錄裡沒有的能力 → 這件事目前做不到，走第 6 步的缺口說明。
- **不得**先宣稱成功再發現命令不存在。呼叫前就該知道它在不在。
- schema 用於約束參數；驗證在 Core，但 Agent 不該把明顯不合 schema 的東西送出去。

### 3. 選最便宜的路徑

執行優先序固定，往下一級要有理由：

```
1. 修改宣告式配置        ← 位置、主題、尺寸、快捷鍵、通知模式
2. 組合現有元件／能力    ← 替換啟動器、新增面板、連接既有服務
3. 生成受限插件          ← 前兩者都做不到時
4. 新增受控外部工具      ← 最後手段
```

判準：**這個需求能不能用已存在的東西表達？** 能 → 不要生成。位置、主題、待辦面板實例這類一般需求，不得要求重新編譯核心、重啟桌面或常駐新程序。

改走生成路徑時**必須明示「這是新增插件」**，並套用對應的測試與執行規則，見 `ditto-generation-safety`。

### 4. 產生 ChangeSet，不產生指令

模型輸出的是結構化變更集：基底 revision、逐項差異、所需權限、前置條件、回復計畫。**自然語言文字不直接當權威配置。**

- 每項變更都要能對應到能力目錄裡的一個操作。
- 帶上取得計畫時的 `base_revision`；Core 會用它檢查競爭修改。
- 不要在 ChangeSet 裡塞入 Agent 自己的推測（「使用者大概也想要…」）。多做的每一項都是使用者沒要求的變更。

### 5. 處理含糊目標

| 情況 | 做法 |
| --- | --- |
| 有合理且**可逆**的預設 | 直接繼續，在結果裡說明採用了什麼預設 |
| 影響實際資料或應用，且目標不確定 | **提供具體選項**，不要猜 |
| 指涉私人資料但無從確定 | 提供候選，或採可逆的空白狀態。**不得憑空指定私人資料夾** |

例：使用者說「左邊放專案」但系統不知道專案在哪 → 給候選或建立空的專案區，不要挑一個看起來像的資料夾填進去。

### 6. 多輪修正對應最近目標

「再窄一點」「保持顏色」這類修正要對應到**最近一次變更的目標**，只改相應項目，不重新覆蓋整個組合。

- 維持一個「最近變更目標」的指標，修正指令優先套用其上。
- 明確要求保留的項目（「顏色維持原本的」）必須在新 ChangeSet 中保持原值，而不是省略後由預設值填回。

### 7. 顯示真實階段

顯示正在理解、準備、試用、套用、驗證等**實際**階段，長操作可取消。

- 階段必須反映真的在做的事。任務停了就不要繼續顯示思考動畫。
- 模型延遲與本機套用延遲分開表達。
- Agent 冷啟動時，UI 先顯示啟動狀態——**不得以永久常駐掩蓋冷啟動未達標**。
- 關閉對話面板不是取消任務。

### 8. 結果依回讀，不依自述

每個結果是成功、失敗、部分完成或結果未知，判定依 Core 的回讀，**不依 Agent 說了什麼**。四類的判準見 `ditto-changeset-transaction`。

### 9. 缺口要說清楚

不支援的需求要說明**缺少什麼能力**，並提供組合、安裝或生成的可行路徑。只說「做不到」不算完成 CON-11。

### 10. 斷線與重啟

- 模型斷線後保留訊息與執行狀態；重連**先查操作結果**，不盲目重跑。
- Agent 重啟從已保存會話與 `operation_id` 恢復；**不因重新載入歷史而重播有副作用的工具**。
- 會話落盤歸 Core 的會話儲存，不在 Agent 程序記憶體裡，見 `ditto-authority-boundaries`。
- 無活動任務、待確認、建置或未移交長任務時，閒置 5 分鐘落盤退出——這是預設，不是可以靠常駐繞過的門檻。

### 11. 驗證

- 任務集用**不同措辭**測同一意圖，檢查實際桌面狀態而非回覆文字（NFR-12）。
- 在 Agent 準備期間手動改同一項設定，確認被拒而非覆寫（AT-10）。
- 中斷模型連線與工具逾時後重連，確認不重複副作用（AT-11）。
- 受理前與受理後各終止一次 Agent，確認未受理不執行、已受理由 Core 完成或回復（AT-28）。
- 閒置到期後確認 Agent 退出且 Cordis 服務保持運行；另測活動長任務不被誤殺（AT-24、NFR-16）。

## Calibrated Examples

**「幫我做一套寫程式用的桌面，左邊放專案，右邊保留終端，通知不要一直跳。」** → 一個 ChangeSet 跨三類能力：布局、啟動器內容、通知模式。全走路徑 1 與 2，不需要生成任何東西。「專案」無法確定時給候選或可逆的空白專案區。

**「終端再寬一點，顏色維持原本的。」** → 只修改布局中的終端寬度。顏色**明確保留原值**寫進 ChangeSet，不是省略掉讓預設值蓋回去。不重新套用整個組合。

**「做一個顯示目前專案待辦的小面板。」** → 先問路徑 2：有待辦服務嗎？有 → 組合現有能力，不生成。缺 UI 才走路徑 3，並明示這是新增插件。缺資料來源權限時，提供**可識別的示範資料**，不得冒充真實進度。

**模型想呼叫 `desktop.theme.set`，但目錄裡叫 `desktop.appearance.set`** → 呼叫前就該發現。動態取得目錄的意義就在這裡：不存在的命令不會被送出，也不會出現「已為你套用主題」然後什麼都沒發生。

**使用者問「我的桌面現在是什麼設定？」** → 這是讀取，不產生 ChangeSet。不要為了「有所行動」而順手改點什麼。

**工具回傳成功，Agent 回覆「已完成」** → 不夠。完成判定依回讀。工具回成功但回讀顯示未生效時，正確的回覆是失敗與已回復，不是成功。

**Agent 重啟後看到歷史裡有一個「安裝套件」的工具呼叫** → 不得重播。以 `operation_id` 查詢那次操作的真實結果，再決定要不要繼續。重播有副作用的工具是 RUN-04 直接禁止的行為。

## Related Skills

- `ditto-changeset-transaction` — Agent 的產出交由交易層驗證與執行；結果類別的判準在那裡（consumes 它）。
- `ditto-generation-safety` — 生成是規劃路徑中最受限的一條（generalizes 它：本 skill 是上游總則）。
