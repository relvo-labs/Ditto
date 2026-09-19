# Ditto

以對話驅動的可組合 Linux 桌面系統。使用者描述工作需求，Ditto 組合桌面布局、插件、操作方式與外觀；每次變更皆可檢查、保存與回復。

Ditto 同時是專案名稱與預設角色。Soft Jelly／柔光果凍是預設桌面形象，並不限制其他組合的風格。

## 文件與原型

- [完整 PRD v0.4.0](docs/product/Ditto-PRD-v0.4.0.md)：26 節、116 項需求、32 組驗收情境。
- [前端互動原型](apps/desktop-prototype/)：完整原始碼、角色素材、配置測試與建置設定。
- [研究與互動決策](docs/research/RESEARCH-AND-INTERACTION.md)：來源、設計對應、原型邊界與原生移植接點。
- [分階段實作計畫](milestones/01/README.md)：G0～G5 工作分解、驗收矩陣、風險與待決策。
- [G0 執行計畫](plan/02/README.md)：G0 的範圍界線、出口門檻、工作包與週序。
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

## G0 原生開發切片

已建立 [Rust 契約與 Core](crates/ditto-core/README.md)、[合成器轉接](crates/ditto-compositor/README.md)、[診斷 CLI](crates/dittoctl/README.md)、[Quickshell 工作階段](shell/README.md)、[合成器探針](tools/compositor-probe/README.md)與[資源採樣器](crates/ditto-measure/README.md)。

在開發容器內，13 項 `desktop.*` 能力可以列舉並操作真實的原生視窗：寫操作回讀比對後才算成功，合成器做不到的操作回 `unsupported`；Shell 的視窗與工作區只來自快照與事件，動畫期間不發任何請求；客戶端身分由受控啟動器綁定。

**還沒有**：實體參考機與真機 runner、合成器選型決策（D-02）、輸入法、透明區點擊穿透驗證、有效的幀時與記憶體數字、登入管理器工作階段。容器與開發 VM 的結果是開發證據，不是出口門檻的判定。逐項現況見[進度紀錄](plan/02/06-workplan.md#7-進度紀錄)。

```sh
bash tests/g0/run-in-container.sh window-matrix   # 能力 × 視窗形態矩陣
bash tests/g0/run-in-container.sh shell-session   # 工作階段、命中遮罩、熱路徑
```

## 目前完成範圍

已完成瀏覽器互動原型：對話變更卡、試看／保留／撤銷、組合保存、模組啟停、視窗與工作區、筆記、待辦及故障回復示範。資料儲存在目前瀏覽器。

目前的自然語言採本機規則解析，元件由受限模板組合；檔案、終端與系統狀態為示範。原生側已有 Core、合成器轉接與 Quickshell 工作階段，但沒有 Cordis 宿主、Agent 或真實 LLM，也沒有在實體參考機上量測過。網頁原型與開發環境的結果都不代表 PRD 的原生效能與安全要求已通過；進度以 [G0 工作包紀錄](plan/02/06-workplan.md#7-進度紀錄) 為準。

## 驗證與發行

原型附 8 項配置／意圖測試；瀏覽器流程驗證紀錄見研究文件。原生開發依 PRD 的 G0～G5 門檻推進。

本次匯入未指定專案開源授權；對外發行前需依 PRD 完成依賴、名稱與角色素材審查。
