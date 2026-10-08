# Ditto

以對話驅動的可組合 Linux 桌面系統。使用者描述工作需求，Ditto 組合桌面布局、插件、操作方式與外觀；每次變更皆可檢查、保存與回復。

Ditto 同時是專案名稱與預設角色。Soft Jelly／柔光果凍是預設桌面形象，並不限制其他組合的風格。

**目前進度（2026-10-07）：G0 原生可行性與 G1 組合底座已完成，由 owner 依實際使用接受（[D-38](.agents/notes/decisions/2026-10-07-d38-g0-g1-owner-acceptance.md)）。** 下一開發階段為 G2，接入真實 Agent／LLM；剩餘功能、驗證證據與核定事項依 D-38 繼續追蹤。

## 文件與原型

- [完整 PRD v0.4.0](docs/product/Ditto-PRD-v0.4.0.md)：26 節、116 項需求、32 組驗收情境。
- [前端互動原型](apps/desktop-prototype/)：完整原始碼、角色素材、配置測試與建置設定。
- [研究與互動決策](docs/research/RESEARCH-AND-INTERACTION.md)：來源、設計對應、原型邊界與原生移植接點。
- [分階段實作計畫](milestones/01/README.md)：G0～G5 工作分解、驗收矩陣、風險與待決策。
- [G0 執行計畫](plan/02/README.md)：G0 的範圍界線、出口門檻、工作包與週序。
- [G1 執行計畫](plan/03/README.md)：組合底座、交易、宿主與驗證；[G0 評審](.agents/notes/gate-reviews/G0-exit.md)、[G1 評審](.agents/notes/gate-reviews/G1-exit.md)保存逐項接受與量測證據。
- [G2 執行計畫](plan/04/README.md)：Codex 個人訂閱＋app-server、Core 會話、授權與上下文、按需 Agent、對話介面；44個工作包與十九項出口，選型與估算為待核定提案。
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

13 項 `desktop.*` 能力可以列舉並操作真實的原生視窗：寫操作回讀比對後才算成功，合成器做不到的操作回 `unsupported`；Shell 的視窗與工作區只來自快照與事件，動畫期間不發任何請求；客戶端身分由受控啟動器綁定。

主要開發機是[開發工作站](docs/platform/dev-wayland-environment.md)：Qt 6.10.2、Quickshell 0.3.1 與 Wayfire 0.11.0 都在其上自源碼建置。**合成器是 Wayfire**（[D-02 決策紀錄](.agents/notes/decisions/2026-09-22-d02-compositor-wayfire.md)）；Sway 支援已遺棄，只保留為該決策的對照。在 Wayfire 上能力矩陣 12 格回讀驗證、0 格 `unsupported`，透明區點擊穿透雙向成立（[能力差異表](docs/platform/compositor-capability-matrix.md)）。

實體參考機、真機 runner、登入管理器工作階段與冷登入分層資源量測已建立。G0 的歷史量測與 G1 的版本回歸分開記錄；中文輸入的實體鍵盤證據與呈現時間交叉量測警訊依 [D-38](.agents/notes/decisions/2026-10-07-d38-g0-g1-owner-acceptance.md) 後續追蹤。

```sh
export PATH=~/wayfire/bin:$PATH LD_LIBRARY_PATH=~/wayfire/lib
export DITTO_WORKSPACE=$PWD DITTO_ARTIFACTS=$PWD/artifacts/g0 \
       DITTO_BINARIES=$PWD/target/debug WLR_RENDERER=gles2

bash tests/g0/compositor-probe/run.sh   # 兩層能力探測，含 C-07 點擊穿透
bash tests/g0/window-matrix/run.sh      # 能力 × 視窗形態矩陣
```

已遺棄的 Sway 對照仍可重現：`bash tests/g0/run-in-container.sh compositor-probe`。

## 目前完成範圍

已完成瀏覽器互動原型：對話變更卡、試看／保留／撤銷、組合保存、模組啟停、視窗與工作區、筆記、待辦及故障回復示範。資料儲存在目前瀏覽器。

網頁原型的自然語言採本機規則解析，元件由受限模板組合；檔案、終端與系統狀態為示範。原生側已有 Rust Core／SQLite、Profile／revision、ChangeSet 交易與回復、Cordis hostd、待辦與通知策略服務，以及可替換 Dock／啟動器、四個管理中心、救援與鎖定介面。

參考機已完成交易、回復、生命週期與故障注入驗證，完整桌面（Agent 不存在）的三次冷登入 PSS p95 為 449.9／449.1／450.9 MiB；條件與原始資料見 [G1 評審 §6](.agents/notes/gate-reviews/G1-exit.md#6-ex1-10-分層資源參考機2026-10-05)。真實 Agent／LLM、互動授權應答者與秘密儲存待 G2 實作。實體雙螢幕、部分桌面基本功能、人工錄影、五晚 nightly 與內建套件升版檢查列為後續工作。

## 驗證與發行

原型附 8 項配置／意圖測試；瀏覽器流程驗證紀錄見研究文件。原生開發依 PRD 的 G0～G5 門檻推進。

本次匯入未指定專案開源授權；對外發行前需依 PRD 完成依賴、名稱與角色素材審查。
