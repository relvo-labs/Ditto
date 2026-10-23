# 05｜風險登記、待決策清單與估算假設

## 1. 風險登記

風險等級＝影響 × 發生可能性。**阻斷級**代表若成真會使既有交付作廢或使 MVP 範圍必須改寫。

| ID | 風險 | 等級 | 徵兆 | 處理與決策門檻 |
| --- | --- | --- | --- | --- |
| R-01 | **Quickshell 與 Wayfire 對接不完整**。Quickshell 的工作區整合清單為 Hyprland／i3／Sway，未列 Wayfire | 阻斷 → **降為中**（2026-09-22） | G0 盤點發現 layer-shell、toplevel 管理或工作區協定缺口 | 已處理：layer-shell（C-01）、toplevel 管理（C-02／C-03）與命中區（C-07）在 Wayfire 上實測成立；工作區不經 Quickshell，改走 Core 的 `desktop.workspaces.*`（`wayfire.rs`，回讀驗證）。合成器決策見 [D-02 紀錄](../../.agents/notes/decisions/2026-09-22-d02-compositor-wayfire.md)。**剩餘風險：C-08 的虛擬鍵盤診斷沒有中文提交，待實體鍵盤判定** |
| R-02 | **Cordis 上游 API 未穩定**（4.0.0-rc），浮動版本上線 | 高 | 同步上游後契約測試大量失敗 | 鎖定 vendored commit，隔離移植修改集，交付契約測試與更新紀錄（[02 §1](02-cordis-adoption.md#1-來源與版本鎖定)） |
| R-03 | **上游 loader 非交易式**，插件啟用失敗留下部分套用的樹 | 高 | G1 prepare／commit 測試出現殘留實例 | 自建兩階段交易層；必要時降為候選 realm 整棵 dispose 的粗粒度回復，並在「部分完成」語意內明確回報 |
| R-04 | **對話只停留在設定捷徑**，未證明可組合性 | 高 | 任務集全是單一設定項 | MVP 強制跨模組任務、多輪修正與受限新插件生成；任務集組成比例列入 QA 驗收 |
| R-05 | **模型規劃錯誤或過度修改** | 高 | 回讀不一致、使用者調整被覆寫 | schema、差異、範圍授權、基底 revision、實際回讀與回復五道關卡（G1 先於 G2 就位） |
| R-06 | **生成程式破壞桌面** | 高 | 候選進入主 Shell 或造成崩潰 | 測試宿主、受限模板、獨立候選、預算與救援；隔離未就緒前只允許宣告式模板 |
| R-07 | **熱換造成狀態丟失** | 中高 | 交接後長任務或索引遺失 | 明確擁有者、四級交接、操作紀錄與快照 |
| R-08 | **跨程序租約增加延遲**，NFR-04 未達標 | 中 | 插件切換 p95 超過 2 秒 | 心跳輕量化、租約操作批次化；必要時附數據調整門檻 |
| R-09 | **Agent 冷啟動降低對話體驗** | 中 | NFR-13 未達標 | UI 即時顯示啟動、按需載入依賴、量測冷態；**不得以永久常駐掩蓋未達標** |
| R-10 | **多宿主與依賴重複耗用**，PSS 預算超標 | 中高 | 19.1 分層量測超出 | 共用可信服務、依啟動事件載入；程序數上限與 PSS 預算一併驗收 |
| R-11 | **Rust 核心膨脹或阻塞** | 中 | 主服務回應延遲、重建置阻塞 | 核心只做權威狀態與協調；重建置／解析移出；外部監督處理無回應 |
| R-12 | **Rust／QML／TS 跨語言成本** | 中 | 契約漂移、重複型別維護 | 固定資料 schema、單一事實來源產生型別、契約測試；不跨程序暴露內部物件 |
| R-13 | **動畫耗電與輸入問題** | 中 | 幀時不穩、輸入區誤攔截 | 真機幀時量測、遮擋暫停、減少動畫、輸入區測試 |
| R-14 | **首版範圍膨脹** | 中高 | P1 能力被當作 MVP 依賴 | 一平台、有限核可來源、受限生成；P1 不作隱性依賴 |
| R-15 | **無 Node 救援模式被當成完整桌面**（報告誤導） | 中 | 資源報告只列救援模式數字 | 報告強制分列四種狀態；審查時檢查程序清單 |
| R-16 | **沙箱強制執行僅 partial 被當作 full** | 中高 | 較舊 Landlock ABI 或核心版本 | 平台凍結時固定核心版本；`partial` 必須向上暴露；要求絕對邊界的消費方拒絕 |
| R-17 | **秘密外洩至日誌、匯出或崩潰報告** | 高 | 掃描命中 | 秘密只存引用；每階段出口執行外洩掃描；遙測預設不傳視窗標題、文件、剪貼簿與對話 |
| R-18 | **角色與名稱權利未釐清** | 中 | 公開發布前才發現 | G4 完成名稱、角色、圖示與素材使用權審查；本計畫不假設已完成法律審查 |
| R-19 | **真機 CI 不可得或不穩定** | 中 → **低（待三晚觀察）** | 效能數字波動大、無法重現 | `ditto-ref-ws-rtx4060-01` 已註冊 user-service runner 並通過 preflight；仍以 EX-09 三個連續夜間結果確認穩定度，虛擬機不代替圖形證據 |
| R-20 | **各工作流尚未指派 owner** | 中 | 決策或工作包停滯 | G0 整體 owner 已由 Lei-k 擔任；各工作流負責人仍須指派，見 [G0 啟動進度](../../plan/02/06-workplan.md#7-進度紀錄) |

## 2. 待決策清單

沿用 PRD 25 節並補上本計畫新增項。**最晚時點**過後仍未決者，視為阻擋該階段出口。2026-10-07 owner 依 D-38 接受 G0／G1 完成，剩餘未決項轉為 D-38 後續追蹤，仍依各列保留提案或待核定狀態。

| # | 議題 | 本計畫預設 | 最晚時點 | 決策者 |
| --- | --- | --- | --- | --- |
| D-01 | 發行版、GPU 與 XWayland 範圍 | **2026-09-22 已決定**：Ubuntu 24.04.2／kernel 6.17／RTX 4060；Firefox、foot、Kate；XWayland 僅診斷（[紀錄](../../.agents/notes/decisions/2026-09-22-d01-reference-platform.md)）；2026-09-26 Firefox 改為 156.0.1 rev 8969（[D-01a](../../.agents/notes/decisions/2026-09-26-d01a-firefox-156-0-1.md)） | G0 | 平台工程 |
| D-02 | **合成器選擇**（Wayfire vs Sway／Hyprland vs 自寫轉接） | **2026-09-22 已決定：Wayfire，Sway 遺棄**（[紀錄](../../.agents/notes/decisions/2026-09-22-d02-compositor-wayfire.md)）。C-08 自動診斷未得到中文提交，出口門檻尚未通過 | **G0 出口** | 平台工程＋產品 |
| D-03 | Qt／Quickshell／Rust／Node 版本 | **2026-09-22 已決定**：Qt 6.10.2、Quickshell 0.3.1、Rust 1.98.1、Node 22.23.2、pnpm 10.11.0（[紀錄](../../.agents/notes/decisions/2026-09-22-d03-toolchain-freeze.md)） | G0 | 全體 |
| D-04 | **Cordis 來源**（Harness vendored fork vs 上游） | 沿用 Harness fork 的鎖定 commit；理由見 [02 §1](02-cordis-adoption.md#1-來源與版本鎖定)；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 前 | Runtime |
| D-05 | Harness 移植範圍（哪些具體套件） | 模型適配器、工具、會話三類；具體清單由 G0／G1 盤點決定 | G2 前 | Runtime＋Agent |
| D-06 | 分層資源預算與工具硬上限 | **部分已決定**：D-06b 工具三類初始配額已核定（[紀錄](../../.agents/notes/decisions/2026-09-22-d06b-tool-quotas.md)）；D-06a Core／Shell PSS：2026-10-05 已取得合格三次冷登入量測，[提案](../../.agents/notes/decisions/2026-10-05-d06a-core-shell-pss.md)待核定 | G0／G1 | 全體 |
| D-07 | 嵌入式腳本引擎（QuickJS／Lua） | **不列入 MVP**；P1 另行選型 | P1 | Runtime |
| D-08 | 生成執行隔離實作 | 先受限模板與隔離試載入，不直接啟用任意程式；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 前 | Runtime＋安全 |
| D-09 | 模型、預算與憑證儲存 | **2026-10-07 部分已決 D-09a**：支援 Codex 個人訂閱登入，以 app-server 為必要且優先後端（[紀錄](../../.agents/notes/decisions/2026-10-07-d09a-codex-subscription-app-server.md)）；API 可替換。模型／effort、quota、keyring 實測仍待定；不核定預算放寬 | G2 M1 真請求前 | Agent＋產品 |
| D-10 | 套件格式與發布來源 | 核可來源＋本機包，固定版本與雜湊；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 | Runtime |
| D-11 | 商業授權與角色素材 | **2026-10-21 依 D-49**：由 owner 處理，Agent 不列為阻擋；#51 盤點僅作工程輸出（[紀錄](../../.agents/notes/decisions/2026-10-21-d49-g4-mvp-owner-acceptance.md)） | 公開發布前 | 產品＋法務 |
| D-12 | 團隊、owner 與工期 | G0 結果後估算 | G0 結束 | 管理 |
| D-13 | **契約型別方向**（Rust-first schemars vs TS-first） | **2026-09-22 已決定**：Rust-first schemars → JSON Schema → TS（[紀錄](../../.agents/notes/decisions/2026-09-22-d13-rust-first-contracts.md)） | G0 | Core |
| D-14 | **IPC 傳輸細節**（Unix socket 路徑、認證方式、事件佇列上限） | **2026-09-22 已決定**：Unix socket 0600、受控啟動器綁定身分、佇列 1024（[紀錄](../../.agents/notes/decisions/2026-09-22-d14-ipc-transport.md)） | G0 | Core |
| D-15 | **Profile 儲存格式**（SQLite 結構與匯出文字格式） | SQLite 為權威，匯出採可審查文字格式；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 | Core |
| D-16 | **兩個非 AI Cordis 服務插件的具體選型** | 任務／待辦資料服務 ＋ 通知策略服務；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 早期 | Host＋產品 |
| D-17 | **兩種受限生成插件的具體選型** | **2026-10-14 已決定**：待辦摘要面板＋工作區快捷動作面板（[補錄](../../.agents/notes/decisions/2026-10-14-d17-g3-generated-plugin-selection.md)） | G3 前 | owner |
| D-18 | **安裝與發行形態**（原生套件 vs Flatpak vs tarball） | **2026-10-21 依 D-49**：不採工作階段安裝包，改做完整 Linux 發行版，另立主規劃（[紀錄](../../.agents/notes/decisions/2026-10-21-d49-g4-mvp-owner-acceptance.md)） | G4 前 | owner |
| D-19 | **真機 CI runner 的取得方式** | **2026-09-22 已決定並註冊**：主要參考機以 user systemd service 提供 `ditto-refmachine`／`ditto-ci`（[紀錄](../../.agents/notes/decisions/2026-09-22-d19-reference-runner.md)） | G0 | 管理＋QA |
| D-20 | **語意任務集的模型版本固定策略** | 固定版本＋保留集；模型更新時重跑並記錄 | G2 | QA＋Agent |
| D-21 | **G0 估算修正（26 → 31 人週）** | 提案：納入 [G0 執行計畫的增補與加嚴](../../plan/02/README.md#4-對-milestones01-的增補與加嚴登記)；未核定前仍以 26 人週為上位計畫建議值 | G0 啟動評審 | 管理＋產品 |
| D-22 | **參考編輯器選擇** | **2026-09-22 已決定**：Kate，以 D-Bus 建立未儲存文件、Wayland clipboard 回讀 SHA-256（[紀錄](../../.agents/notes/decisions/2026-09-22-d22-reference-editor-kate.md)） | G0 W2 | 平台工程＋QA |
| D-23 | **能力目錄一致性 gate 的嚴格度** | **2026-09-22 已決定**：四項檢查任一失敗即擋合併（[紀錄](../../.agents/notes/decisions/2026-09-22-d23-catalog-gate-strict.md)） | G0 CORE-02 開工前 | Core |
| D-24 | **`ditto-qml-shell` 轉 `stable` 的判定** | **2026-09-22 已決定**：生產 24 矩形遮罩雙向驗證後轉 stable（[紀錄](../../.agents/notes/decisions/2026-09-22-d24-qml-shell-stable.md)） | G0 出口 | Shell |
| D-25 | **自動化測試的第一線環境** | **2026-09-27 已決定**：參考機上的 libvirt 開發 VM 為第一線自動化測試；結果只是開發證據，出口門檻不變（[紀錄](../../.agents/notes/decisions/2026-09-27-d25-vm-first-automation.md)） | G0 | 平台工程＋QA |
| D-36 | **EX-09 的判定方式** | **2026-09-27 已決定（放寬）**：由連續 3 晚改為同一已進版 commit 的 3 次獨立參考機執行，可在同一天，並須先通過 3 輪 VM；只適用 G0（[紀錄](../../.agents/notes/decisions/2026-09-27-d36-ex09-same-day-runs.md)） | G0 出口 | 參考機 owner；產品 owner 於出口評審確認 |
| D-26 | **Core 的並行模型與 SQLite 函式庫**（plan/03 提案） | 待決策提案：std 執行緒＋單一協調器＋唯讀連線池；`rusqlite` bundled；WAL＋`synchronous=FULL`。G1 實作暫採此值（[plan/03/08](../../plan/03/08-decisions-and-risks.md#12-本計畫新增的待決策提案)）；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 M0 | Core |
| D-27 | **hostd 的連線與身分**（plan/03 提案） | 待決策提案：共用 `core.sock`；kind `hostd` 經受控啟動器；`on_behalf_of` 以已分派條目表驗證；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 M0 | Core＋Host |
| D-28 | **通知伺服端的擁有者**（plan/03 提案） | 待決策提案：Core 的 `ditto-system`；策略詢問 50 ms，失敗預設顯示；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 W3 | Core＋Shell |
| D-29 | **救援介面形態與離線寫入**（plan/03 提案） | 待決策提案：`shell/rescue/` 獨立設定＋`dittoctl rescue` fallback；`--offline` 持 `core.lock` 只允許兩種寫入；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 W9 | Runtime＋平台 |
| D-30 | **鎖定客戶端的程序形態**（plan/03 提案） | 待決策提案：獨立程序 `ditto-lock`，由 Core 啟動；依 C-19 實測；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 W6 | Shell＋平台 |
| D-31 | **G1 估算與人力修正**（plan/03 提案） | 待決策提案：124 → 140.5 人週；選項 A（11 人、18 週）；**2026-10-17 盤點：待 owner 核定；歷史估算併 D-12 核對**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 M0 | 管理＋產品 |
| D-32 | **交易層的候選策略**（plan/03 提案） | 待決策提案：預設策略 A，依預先承諾判準決定是否改 B；兩者不混用；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | 判準 G1 M0；定案 W3 | Host |
| D-33 | **布局策略在 Wayfire 上的實作路徑**（plan/03 提案） | 待決策提案：依 C-15 探測決定受控交接或工作階段重啟等級；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 W3 | 平台＋產品 |
| D-34 | **10 個簡單插件的固定集合**（plan/03 提案） | 待決策提案：5 個 QML 狀態型＋5 個 Cordis 設定型，版本鎖定；**2026-10-17 盤點：待 owner 核定**（[實作與處置來源](../../plan/06/02-handoff.md#4-既有未核定決策盤點)） | G1 W8 | QA＋Host |
| D-35 | **協定 0.2 的凍結政策**（plan/03 提案） | **2026-10-17 盤點：已被取代**；0.2 提案保留為歷史，現行協定 0.3 依 2026-10-09 [D-39](../../.agents/notes/decisions/2026-10-09-d39-protocol-0-3-freeze.md)。來源核對見 [G4 盤點](../../plan/06/02-handoff.md#4-既有未核定決策盤點) | G1 M3 | Core＋Agent |
| D-37 | **G0 出口評審前開始 G1 實作** | **2026-09-27 已決定（偏離 plan/03 開工條件）**：使用者判斷既有測試足以開工；G0 未通過項目帶進 G1 追蹤，G1 門檻不變（[紀錄](../../.agents/notes/decisions/2026-09-27-d37-g1-start-before-g0-exit.md)） | G1 開工 | 參考機 owner；產品 owner 於 G0 出口評審確認 |
| D-38 | **G0／G1 階段完成裁定** | **2026-10-07 已決定**：owner 依實際使用接受 G0、G1 完成；後續重心為 G2，剩餘功能、證據與核定事項繼續追蹤，量測數字與門檻維持原樣（[紀錄](../../.agents/notes/decisions/2026-10-07-d38-g0-g1-owner-acceptance.md)） | G0／G1 結束 | 使用者／專案 owner Lei-k |
| D-39 | **G2 跨程序契約與生命週期** | **2026-10-09 已決定**：協定 0.3 以目前形狀凍結，`agent.turns.trace` 與 approval 綁定（含刪除設定檔的 `profiles.delete`）列入契約（[紀錄](../../.agents/notes/decisions/2026-10-09-d39-protocol-0-3-freeze.md)） | G2 M0 契約凍結 | Core＋Agent＋Shell |
| D-40 | **可保存的原生區域布局** | **2026-10-09 已決定**：浮動視窗的比例區域規則；依用戶端提交的幾何判定，容差 2 px、幾何穩定 150 ms（[紀錄](../../.agents/notes/decisions/2026-10-09-d40-floating-region-layout.md)） | G2 跨三類組合前 | 平台＋Core |
| D-41 | **Core 會話與 AI 偏好持久化** | **2026-10-09 已決定**：依實作定案（事件檔＋SQLite 索引、工具前落盤、保存到使用者刪除）；30 天自動清除另議（[紀錄](../../.agents/notes/decisions/2026-10-09-d41-conversation-storage.md)） | G2 儲存遷移前 | Core＋Agent＋owner |
| D-42 | **G2 增補與估算修正** | **2026-10-09 已決定**：保留 44 包範圍追蹤，125 人週不作承諾；剩餘工作依剩下的項目估（[紀錄](../../.agents/notes/decisions/2026-10-09-d42-g2-estimate.md)） | G2 M0 初估、M1 校正 | owner＋各工作流 |
| D-43 | **G2 保留集與驗收重複方式** | **2026-10-09 已決定**：兩組各 ≥45／50、保留集降幅 ≤5 pp；「詢問」不限問號；刪除設定檔經 approval 詢問後依本人決定放行；oracle v3 兩組重跑（[紀錄](../../.agents/notes/decisions/2026-10-09-d43-semantic-holdout-and-judging.md)） | G2 M2 語意基線前 | QA＋Agent＋owner |
| D-44 | **Codex app-server 程序與限制** | **2026-10-09 已決定**：1 controller＋至多 1 個 confine 內的 app-server；Agent scope 暫定 MemoryMax 256 MiB；2026-10-13 參考機活動中後端達 209 MiB，先給後端寬鬆上限 1G、收緊待 #35；暖態 ≤150 MiB 不變（[紀錄](../../.agents/notes/decisions/2026-10-09-d44-codex-process-and-limits.md)） | G2 M0 probe、M1 可寫之前 | Core＋平台＋Agent＋owner |
| D-45 | **G2 出口前開始 G3 獨立基礎設施** | **2026-10-13 依使用者指示開始**：疊在 `a88bce8` 的 `codex/g3-restricted-generation`；G2／G3 證據分開，Core／協定等 G2 參考機量測結束（[紀錄](../../.agents/notes/decisions/2026-10-13-d45-g3-independent-foundation.md)） | G3 獨立工作開工；正式接線前重核 | 使用者／專案 owner |
| D-46 | **G2 功能接受與完整 G3 整合** | **2026-10-13 owner 裁定**：「G2 目前功能已經算完成，你繼續實完G3」；取代 D-45 接線等待條件，未執行量測仍追蹤（[紀錄](../../.agents/notes/decisions/2026-10-13-d46-g2-functional-acceptance-and-g3-integration.md)） | G3 正式接線 | 使用者／專案 owner |
| D-47 | **G3 出口依開發 VM 證據通過** | **2026-10-17 owner 裁定**：接受 `17f5d76` VM 15/15，未涵蓋項轉 G4；G4 從合併後 main 開始（[紀錄](../../.agents/notes/decisions/2026-10-17-d47-g3-exit-vm-evidence.md)） | G3 出口 | owner |
| D-48 | **新預設右下改助理入口** | **2026-10-17 owner 要求**：新 store 預設右下改有標籤的助理入口，不再放重複 Ditto；optional avatar 與舊 Profile 保留。助理符號待 owner 定；`soft-jelly-light`／`dock_pill` 為可逆交接（[紀錄](../../.agents/notes/decisions/2026-10-17-d48-default-assistant-entry.md)） | G4 預設呈現 | owner |
| D-49 | **owner 判定 MVP 可接受** | **2026-10-21 owner 判斷**：MVP 接受；六項出口證據未補者列缺口、不改列通過；D-11 由 owner 處理；D-18 改走完整發行版（[紀錄](../../.agents/notes/decisions/2026-10-21-d49-g4-mvp-owner-acceptance.md)） | G4 出口 | owner |
| D-50 | **#159 Shell 擴充契約（UI-P01）** | **2026-10-22 已決定（安全預設，待 owner 檢視）**：設定頁用多條目 area `ui.settings_page`；跨信任設定先採宣告式表單（前提是 Core 端 `config_schema` 驗證）；UI 暫態只在 Shell 記憶體；UI SDK 為 `root:/sdk/Ditto/Ui` qmldir 模組；舊 Profile 不遷移、走內建 fallback。D-49 由 PR #147 保留（[紀錄](../../.agents/notes/decisions/2026-10-22-d50-shell-extension-contracts.md)） | UI-P02 開工 | coordinator（owner 事先授權安全預設） |

## 2.1 G4 開工時的既有決策盤點

D-38 所列 D-04／08／10／15／16／26～35 已逐項對照 `39da297` 實作，見 [plan/06/02 §4](../../plan/06/02-handoff.md#4-既有未核定決策盤點)。D-17 已補錄；D-35 由 D-39 取代；其餘需 owner 核定的項目保持提案，不把程式碼選擇冒充決策。

## 3. 團隊與估算假設

### 3.1 建議責任分工（PRD 22 節）

G0 整體 owner 已由 Lei-k 擔任（2026-09-19 使用者確認）；下表的人力與各工作流負責人仍是建議值，尚待 D-12 的後續分工與工期核定。

| 工作流 | 職責 | 建議人力 |
| --- | --- | --- |
| 產品 | 需求與取捨、決策紀錄、使用者測試 | 1 |
| Shell／設計 | QML、互動、柔光果凍、角色、無障礙、i18n | 2（含 1 設計） |
| Runtime（Core） | Rust 核心、契約、變更協調、權限、回復 | 2 |
| Runtime（Host） | Cordis 宿主、橋接、SDK、桌面服務插件 | 2 |
| Agent | 意圖、規劃、移植、生成 | 1–2 |
| 平台工程 | 合成器、系統整合、打包、發行 | 1 |
| QA | 真機、故障注入、量測、模型任務集 | 1 |

合計約 10–11 人。

### 3.2 估算假設

1. 人力於 G0 開始時到位且穩定；owner 於 G0 結束前指派完成。
2. 實體參考機與真機 CI runner 於 G0 中期可用。
3. 合成器決策（D-02）在 G0 出口做出；若需自寫 Wayfire 轉接，G1 增加 6–10 人週。
4. Cordis 沿用 Harness fork（D-04）；若改用上游，G1 增加 8–12 人週用於重新修復生命週期缺口。
5. 模型供應者於 G2 開始前可用，含可測試的配額。
6. 估算不含：法務審查、市場化工作、G5 範圍、非參考平台的移植。

### 3.3 工期匯總（建議值，G0 後核定）

| 階段 | 人週 | 曆時 |
| --- | --- | --- |
| G0 | 26 | 6–8 週 |
| G1 | 124 | 14–18 週 |
| G2 | 84 | 10–12 週（與 G1 後段交錯，實際曆時可壓縮 4–6 週） |
| G3 | 64 | 8–10 週 |
| G4 | 82 | 10–12 週 |
| **合計至 MVP** | **約 380 人週** | **約 12–15 個月** |

PRD 明示「時程待 G0 結果、人力與預算確定後估算，不以尚未驗證的工期作承諾」。上表為規劃輸入，不構成承諾。

## 3.4 G0 期間已留下的決策紀錄

以下決策不在 D-01～D-20 清單上，但半年後會被重新提起，因此留了紀錄：

| 日期 | 決策 | 紀錄 |
| --- | --- | --- |
| 2026-09-19 | G0 合成器轉接採「中立介面＋合成器 IPC 後端」，**不代表 D-02 已決定** | [紀錄](../../.agents/notes/decisions/2026-09-19-g0-compositor-adapter-seam.md) |
| 2026-09-19 | 受控啟動器以已開啟的描述子交付一次性 token，不走環境變數 | [紀錄](../../.agents/notes/decisions/2026-09-19-launcher-identity-handover.md) |

D-01、D-02、D-03、D-06b、D-13、D-14、D-19、D-22、D-23、D-24、D-25、D-36 已決定；D-06a 與 D-12 的工作流分工仍未結。G0 期間取得的探測與量測資料見 [plan/02 §7](../../plan/02/06-workplan.md#7-進度紀錄)。

## 4. 決策紀錄格式

每項決策落定時，於本文件對應列補上：

```
決策日期  2026-XX-XX
結論      （實際選擇）
依據      （量測數據或評估結果的位置）
影響      （受影響的階段、工作項與估算變動）
決策者    （角色）
```

不得只更新「本計畫預設」欄而無決策紀錄。
