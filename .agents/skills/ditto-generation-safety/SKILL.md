---
name: ditto-generation-safety
description: >-
  Keep Ditto plugin generation inside its limits: prefer composition over
  generation, restrict what generated code may import or reach, validate every
  candidate in an isolated test host with OS-level limits, cap the repair
  budget, never treat partial enforcement as full, and roll back on activation
  failure. Use when implementing or reviewing generation templates, the test
  host, sandbox policy, generated-artifact records, or activating a candidate.
metadata:
  type: skill
  category: agent
  status: stable
  language: zh-Hant
  related:
    - ditto-agent-changeset
    - ditto-permission-and-secrets
---

# Ditto 受限生成

> 受限生成與隔離執行：模板優先、限制能力、隔離驗證、預算與回復。

> **status: stable** — G3 的正式形狀已核對：Rust `Description`、五關固定 Qt runner、`generated-templates-v1` 分項 attestation、Core 發布／啟用與資料回退；見 [生產邊界](../../../docs/platform/generated-template-boundary.md)。這不是 G3 出口或任意 QML／Node 隔離通過宣告。

## Overview

「對話能做出新插件」是 Ditto 的賣點之一，也是它最容易把桌面弄壞的地方。生成的 QML 與 JavaScript 一樣可能有檔案與程序能力；靜態掃描或人工確認**不能取代執行隔離**。

所以這條路徑的設計前提是反過來的：不是「先生成再想辦法確認它安全」，而是**在隔離就緒之前，只允許輸出受限的宣告式模板**。能生成不等於能執行。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §9 插件生成與移植需求](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §12.1 插件種類與信任分級](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §17 權限、信任與生成程式碼](../../../docs/product/Ditto-PRD-v0.4.0.md)

對應需求：GEN-01、GEN-02、GEN-03、GEN-04、GEN-05、GEN-06、GEN-07、GEN-08、SEC-05、SEC-12、AT-22

## When to Use

用於：實作或審查生成模板、測試宿主、沙箱政策、生成物紀錄、候選啟用流程；決定某段生成內容可不可以執行。

不適用：

- 什麼時候該走生成而不是組合 → `ditto-agent-changeset`（路徑優先序在那裡）。
- 使用者授權範圍與秘密處理 → `ditto-permission-and-secrets`。
- 生成失敗後的回復協調 → `ditto-changeset-transaction`。

## Workflow

### 1. 先讀權威

打開 PRD §9 與 §12.1。本節只給執行判準。

### 2. 確認真的需要生成

生成是第三順位。先確認前兩條路徑都不行：宣告式配置改不到、既有能力也組不出來。**不得**把單純的配置修改偷偷改成生成路徑。

走生成時**必須明示「這是新增插件」**，並套用對應的測試與執行規則——使用者要知道自己剛才不是改了一個設定，而是多了一個插件。

### 3. 先看隔離就緒沒有

這是整條流程的閘門：

| 隔離狀態 | 允許輸出 |
| --- | --- |
| 未建立 | **只允許受限宣告式模板**（固定模板引用 ＋受限描述） |
| 已建立且強制執行為 `full` | 模板輸出，並可在測試宿主驗證後啟用 |
| 已建立但強制執行為 `partial` | **視同不足**：`partial` 不得當作 `full`。要求絕對邊界的候選必須拒絕，或把這個差異明確向上暴露 |

`partial` 常見於較舊的核心 ABI 或後端能力缺口。它的意思是「有些承諾管不住」，不是「大致管得住」。

### 4. 限制生成物的能力

生成插件可用的 imports、檔案、網路與程序能力都要**列舉允許**，不是列舉禁止：

- 允許的 imports 是白名單，白名單外一律拒絕載入。
- 檔案存取限定在候選自己的工作區。
- 網路預設關閉。
- 不得產生或載入原生動態庫；MVP 不開放 Agent 生成並直接載入任意原生庫。

目前 MVP 沒有任意 imports／程式碼欄位；原始碼是固定模板封裝。試載與預覽在獨立宿主，啟用後由主 Shell 自己的固定模板解讀描述，不載入套件 QML。受控 runner 的系統／Qt 依賴唯讀白名單另列於生產邊界；不是候選的檔案授權。

限制要由**程序與能力代理**落實。`node:vm`、Worker、QML import 限制與 Cordis 的依賴注入**都不是 OS 安全沙箱**——這條在架構上已經定案，不要在生成路徑上重新爭論。

### 5. 產出完整的生成物

每個候選必須包含：原始碼、manifest、依賴鎖定、設定 schema、測試／驗證結果、生成來源。缺一項的候選不得進入啟用流程。

`GeneratedArtifact` 另外記錄原始需求、來源、程式版本、驗證與啟用紀錄——這是之後要能回答「這東西哪來的」的唯一依據。

### 6. 在隔離測試宿主驗證

候選**先在隔離測試宿主載入**，不得直接覆寫使用中的 Shell 或救援程式。

驗證順序固定，前一關過不了就不進下一關：

```
語法 → 契約 → 載入 → 焦點 → 基本互動
```

通過後才提供真實預覽。**預覽中的測試資料必須標示**，不得讓使用者以為看到的是自己的真實資料。

測試宿主受 OS 層限制：檔案、網路、程序與時間邊界，以 cgroup 或等效機制設定記憶體、CPU 與程序數上限。**候選 OOM 或超限時終止候選，不得連帶終止桌面。**

無法在隔離中執行時，降為**可檢視候選**——可以看程式碼，不能啟用。

### 7. 控制修復預算

自動修復最多三輪。超出後**保留結果並說明問題**，不繼續燒預算。

判準：每一輪都要有可觀察的進展（錯誤變了、通過的關卡多了）。同一個錯誤重複出現兩次就停，那是模型在原地打轉。

### 8. 啟用失敗要回復

啟用失敗 → 自動停用候選並回復，**原始碼與診斷保留供修正**。桌面必須維持可用。

對話修改已生成的插件會**產生新版本**，不破壞可回復的舊版本，並顯示變更範圍。資料 schema 升級與回退遵循遷移政策，見 `ditto-changeset-transaction`。

### 9. 驗證

- 注入無效 QML、逾時與非法 imports，確認不進主 Shell、顯示失敗、桌面可用（AT-07）。
- 注入無窮迴圈、超量記憶體與超量任務，確認配額與佇列生效、可取消、故障程序被終止而桌面與最近可用配置保留（AT-26）。
- 安裝含任意 QML／Node／原生入口的未信任候選，確認不進主 Shell 或 Core；隔離未就緒時拒絕啟用，而核可模板仍可正常生成（AT-29）。
- 生成至少兩種原先未安裝的、可運作的插件，並可繼續以對話修改（AT-06）。
- 升級生成插件的資料 schema 後回退，確認依快照與相容政策回復，舊版不誤讀新資料（AT-22）。

## Calibrated Examples

**「做一個顯示待辦進度的小面板。」** → 若已有待辦服務，這是路徑 2 的組合，**不是生成**。只有在缺 UI 且模板組不出來時才生成，而且要明講多了一個插件。

**生成的插件通過了所有測試，可以視為可信嗎？** → 不行。一般自由 QML 不因為通過測試就升格為可信；它仍儲存受限描述與固定模板引用，執行位置與權限不變。測試證明它能動，不證明它被限制住。

**「靜態掃描過了，沒有危險呼叫。」** → 不足以放行。掃描抓得到明顯的東西，抓不到動態組出來的呼叫。SEC-05 要的是**執行時**的檔案、網路、程序與時間邊界，不是掃描結論。

**候選在測試宿主裡把記憶體吃爆** → 終止候選，桌面不受影響。這正是把測試宿主放在獨立程序 ＋cgroup 的理由。若這件事會影響到桌面，那是隔離設計有缺口，不是候選寫得太糟。

**修復到第三輪還在同一個錯誤** → 停。保留產物與診斷，說明卡在哪裡。第四輪不會比第三輪聰明，但會再花一次預算，而且會讓使用者一直等。

**「這次只是改生成插件的一行文字，不用重新驗證吧？」** → 要。修改產生新版本，新版本走同一條驗證流程。舊版本保持可回復。差別只在流程可以很快，不在流程可以跳過。

**隔離還沒做好，但使用者現在就想要一個新面板** → 給受限宣告式模板能做到的版本，並說明目前的界線。**不要**為了這次需求先放行一個自由 QML 候選——GEN-04 的「隔離未建立前只允許受限模板」就是為了擋住這個情境。

## Related Skills

- `ditto-agent-changeset` — 生成是規劃路徑中最受限的一條；何時該走這條在那裡（specializes 它）。
- `ditto-permission-and-secrets` — 隔離與授權共同構成信任邊界：那裡管誰被允許，這裡管執行時被限制成什麼樣（complements）。
