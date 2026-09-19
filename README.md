# Ditto

以對話驅動的可組合 Linux 桌面系統。使用者描述工作需求，Ditto 組合桌面布局、插件、操作方式與外觀；每次變更皆可檢查、保存與回復。

Ditto 同時是專案名稱與預設角色。Soft Jelly／柔光果凍是預設桌面形象，並不限制其他組合的風格。

## 文件與原型

- [完整 PRD v0.4.0](docs/product/Ditto-PRD-v0.4.0.md)：26 節、116 項需求、32 組驗收情境。
- [前端互動原型](apps/desktop-prototype/)：完整原始碼、角色素材、配置測試與建置設定。
- [研究與互動決策](docs/research/RESEARCH-AND-INTERACTION.md)：來源、設計對應、原型邊界與原生移植接點。
- [分階段實作計畫](milestones/01/README.md)：G0～G5 工作分解、驗收矩陣、風險與待決策。
- [開發導覽 AGENTS.md](AGENTS.md)：權威文件位置、五條不可違反原則與 [skill 集合](.agents/skills/README.md)。
- [已部署體驗](https://ditto-soft-jelly-desktop.neil0628.chatgpt.site)：依既有存取權限開放，並非 GitHub Pages。

## 正式架構方向

| 層級 | 技術與責任 |
| --- | --- |
| 桌面介面 | Qt Quick／Quickshell：QML 元件、桌面呈現與角色動畫 |
| 系統核心 | Rust：權威配置、權限、變更協調、監督與回復 |
| 插件組合 | Node.js／Cordis：Context、服務依賴、事件與插件生命週期；按桌面服務需求常駐 |
| 對話 Agent | 獨立 Node.js／TypeScript 程序，按需啟動，整合 Harness／LLM |

Cordis 是主要插件組合模型與實際宿主，不僅是 Agent 內部實作。Agent 退出不應中斷 Cordis 桌面服務。詳細邊界及資源目標以 PRD 為準。

## 執行前端原型

需求：Node.js 22 或以上、pnpm 10.11.0。

```bash
cd apps/desktop-prototype
pnpm install --frozen-lockfile
pnpm dev
```

```bash
pnpm test
pnpm build
```

Vite 會輸出本機網址；正式靜態檔案產生在 `apps/desktop-prototype/dist/`。點擊 Ditto 或按 Ctrl/Cmd＋J，試說「幫我做開發桌面，保留原本配色」。

## 目前完成範圍

已完成瀏覽器互動原型：對話變更卡、試看／保留／撤銷、組合保存、模組啟停、視窗與工作區、筆記、待辦及故障回復示範。資料儲存在目前瀏覽器。

目前的自然語言採本機規則解析，元件由受限模板組合；檔案、終端與系統狀態為示範。尚未實作 Rust 核心、Cordis 宿主、原生 Linux 桌面控制或真實 LLM。網頁原型不代表 PRD 的原生效能與安全要求已通過。

## 驗證與發行

原型附 8 項配置／意圖測試；瀏覽器流程驗證紀錄見研究文件。原生開發依 PRD 的 G0～G5 門檻推進。

本次匯入未指定專案開源授權；對外發行前需依 PRD 完成依賴、名稱與角色素材審查。
