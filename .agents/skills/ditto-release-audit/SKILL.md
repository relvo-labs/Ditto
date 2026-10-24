---
name: ditto-release-audit
description: >-
  Run the Ditto pre-release audit: inventory every dependency, font, icon and
  character asset with its licence and source, settle name and asset rights,
  assemble the shipping deliverables, and state known limitations honestly. Use
  when preparing a release or milestone build, adding a dependency that will
  ship, changing bundled assets, or reviewing the release checklist.
metadata:
  type: skill
  category: process
  status: stable
  language: zh-Hant
  related:
    - ditto-upstream-port
---

# Ditto 發行審查

> 發行前的來源與授權盤點、交付物清單與已知限制陳述。

## Overview

Ditto 要發行的東西不只是程式碼：它綁著 Qt、Quickshell、Cordis、Harness、合成器、一整棵傳遞依賴，加上字型、圖示與一個有辨識度的角色形象。這些各有各的授權條件，而角色與名稱的使用權在 PRD 裡是**尚未確定**的狀態。

審查在發行前一次做完是做不完的。這個 skill 的用法是**每次新增會被打包出去的東西時就跑一遍第 3 步**，讓發行前只剩彙整。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §24.1 發行要求](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [D-52 自有程式碼採 MIT](../../notes/decisions/2026-10-25-d52-mit-license.md) 與[根目錄 LICENSE](../../../LICENSE)
- [PRD v0.4.0 §23 成效指標與發布交付物](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/03 G4-PLAT-04 授權盤點](../../../milestones/01/03-phases.md)

對應需求：MOD-01、MOD-04、MOD-09、CFG-03、SEC-07

## When to Use

用於：準備發行或里程碑建置；新增會被打包出去的依賴；更換內建素材；審查發行檢查表。

不適用：

- 單一套件的移植紀錄與修改集 → `ditto-upstream-port`（本 skill 彙整它的產出）。
- 效能與資源是否達標 → `ditto-verification-evidence`。
- 已知限制的措辭 → `ditto-prose-standard`。

## Workflow

### 1. 先讀權威

打開 PRD §24.1 與 §23。本節給的是執行程序。

### 2. 確認盤點範圍

會被打包出去的一切都在範圍內：

- 執行期依賴（含傳遞依賴）與其鎖定版本
- Qt、Quickshell、合成器與系統元件
- vendored 的 Cordis 與移植自 Harness 的套件
- 字型、圖示
- **角色素材**（Ditto 的圖像、動畫與衍生資源）
- 生成模板與其中引用的範例資料

開發期工具不在範圍內，但**要明確列出為什麼不在**，不是默默略過。

### 3. 逐項盤點

每一項記錄：名稱、精確版本、來源、授權、是否修改、NOTICE 義務。

移植來的套件直接取用 `ditto-upstream-port` 的九欄紀錄，不要重複維護第二份。

三條容易出錯的規則：

- **不得把主專案授權套用到所有插件。** 每個插件有自己的授權。
- Ditto 自有程式碼已依 D-52 採 MIT；Linux、Ubuntu、Qt、Wayfire 等相依元件、第三方素材與 owner／使用者生成物不因本決定改授權。生成物的預設 `UNLICENSED` 保留，不能由主專案 metadata 推定為 MIT。
- 修改過的上游程式碼要保留修改說明與必要的散布資料。
- 生成或移植的程式碼保留可追溯來源；自動生成不免除上游義務。

### 4. 處理角色與名稱

PRD 已記錄 Ditto 自有程式碼採 MIT；名稱、商標、角色、圖示與美術素材的使用權**尚未確定**，商業模式與剩餘法律裁定仍由 owner 負責。MIT 不代表完整映像或第三方授權審查完成，亦不改變 D-49 的法律責任歸屬。

- 發行前必須完成這項審查，不得以「先發再說」推進。
- 盤點素材的產生方式與權利狀態：是自製、委製、生成，或取用他人作品。
- 生成素材要記錄生成工具與其輸出授權條款。
- **不得在文件中暗示法律審查已完成**——PRD 本身就聲明它不代表已完成法律審查。

### 5. 組裝交付物

發行交付物清單：

- 可安裝的工作階段
- 版本鎖定與依賴清單
- 預設組合（柔光果凍、開發、簡報）
- SDK 與生成模板
- 服務契約
- 使用與救援文件
- 相容矩陣
- 測試報告
- **已知限制**
- 更新與回退程序

缺任何一項都不算可發行。測試報告取自 `ditto-verification-evidence` 的量測結果，不另外寫一份。

### 6. 誠實列出已知限制

已知限制是交付物，不是可選的附註。至少涵蓋：

- 固定的平台支援矩陣，以及矩陣外的狀態（未測試，不是「應該可以」）。
- 合成器能力缺口與回傳 `unsupported` 的操作。
- 未達成的量測目標與其實際數字。
- P1 範圍中尚未提供的能力（第三方隔離自助安裝、更自由的生成、語音等）。
- 遙測與崩潰報告的資料範圍。

判準：**使用者踩到這個限制時，會不會覺得文件騙了他？** 會 → 寫進去。

### 7. 驗證

- 隨機抽三個打包出去的檔案，確認都能在盤點表中找到來源與授權。
- 對含金鑰引用的組合執行匯出，確認不含秘密與私人內容（AT-15）。
- 確認每個第三方授權的 NOTICE 都在發行包中。
- 依 `.nvmrc` 啟用 Node，執行 `node scripts/check-license.mjs` 與 `node --test scripts/check-license.test.mjs`，核對自有 metadata、MIT 文字、生成物預設及既有 vendor LICENSE／NOTICE 雜湊；這不代替實際發行包盤點。
- 確認已知限制清單涵蓋所有未達標的量測項目。
- 確認名稱與角色素材的權利狀態有書面結論。

## Calibrated Examples

**新增一個字型讓中文顯示更好看** → 進盤點，記錄授權與是否允許嵌入散布。字型授權常有「可安裝但不可重新散布」的條款，而桌面產品正是在散布它。

**角色素材是生成的，需要審查嗎？** → 需要，而且這正是最不確定的一項。要記錄生成工具、輸出的授權條款，以及是否可商用。「它是生成的所以沒有權利問題」不是結論，是待確認事項。

**「這個依賴是 MIT，不用記了吧。」** → 要記。MIT 要求保留著作權聲明與授權條文，發行包裡必須有對應的 NOTICE。寬鬆授權不等於沒有義務。

**「量測沒完全達標，發行說明就別提了。」** → 反例。已知限制是交付物。未達標的指標連同實際數字一起寫出來，比讓使用者自己發現好——而且 PRD 的誠實要求本來就不允許把目標寫成已達成。

**「這些是開發工具，不會打包出去。」** → 可以排除，但要在盤點表中**明列排除項與理由**。默默略過的結果是下次有人不確定它到底有沒有被打包。

**發行前才發現某個依賴的授權不相容** → 這就是第 2 步要在**每次新增依賴時**就跑的原因。到發行前才盤點，選項只剩延期或緊急替換。

## Related Skills

- `ditto-upstream-port` — 發行審查彙整各套件的移植紀錄，不重複維護第二份（consumes 它）。
