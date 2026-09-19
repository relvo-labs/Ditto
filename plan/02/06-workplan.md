# 06｜工作包、週序與估算

> 19 個工作包的執行細節與時序。狀態只在本文更新，不散落到其他文件。

## 1. 工作包總表

| ID | 工作流 | 名稱 | 前置 | 人週 | 出口證據 |
| --- | --- | --- | --- | --- | --- |
| G0-PLAT-01 | PLAT | 參考平台凍結 | — | 2 | 支援矩陣＋可重建映像 |
| G0-PLAT-02 | PLAT | 工具鏈凍結 | P-01 | 1 | 版本矩陣＋鎖定檔 |
| G0-PLAT-03 | PLAT | 合成器能力盤點與 D-02 | P-01 | 3 | 探針套件＋能力差異表＋決策紀錄 |
| G0-PLAT-04 | PLAT | 輸入法鏈路驗證 | P-01、S-01 | 1 | 輸入法報告（EX-08） |
| G0-PLAT-05 | PLAT | 真機 runner 與 nightly | P-01 | 1 | 3 晚連續綠燈（EX-09） |
| G0-CORE-01 | CORE | 倉庫骨架與 CI | P-02 | 1 | 可建置骨架＋6 條工作流 |
| G0-CORE-02 | CORE | 契約管線與能力目錄 | C-01 | 2 | schema 產物＋目錄一致性 gate（EX-06） |
| G0-CORE-03 | CORE | 最小 IPC | C-02 | 2.5 | Core 服務＋TS client＋契約測試 |
| G0-CORE-04 | CORE | 呼叫身分綁定 | C-03 | 1 | 三項負例測試（EX-07） |
| G0-CORE-05 | CORE | 合成器轉接 | C-03、P-03 | 2.5 | 13 項能力＋矩陣結果（EX-01） |
| G0-CORE-06 | CORE | `dittoctl probe` | C-03 | 1 | 6 個子命令＋矩陣腳本資料來源 |
| G0-SHELL-01 | SHELL | 最小 Quickshell 工作階段 | P-02、P-03 | 2.5 | 可登入桌面 |
| G0-SHELL-02 | SHELL | 角色層與本機動畫 | S-01 | 2 | 角色元件＋拔掉 Core 仍動 |
| G0-SHELL-03 | SHELL | 命中區 | S-02、P-03(C-07) | 1 | 穿透與不穿透雙向驗證 |
| G0-SHELL-04 | SHELL | 狀態訂閱與命令接線 | S-01、C-03 | 2.5 | 快照重連＋RPC 計數器 |
| G0-QA-01 | QA | 資源量測工具與報告 | C-01 | 2 | `ditto-measure`＋報告範本 |
| G0-QA-02 | QA | UI 重啟存活驗證 | S-01、C-05 | 1 | 20 次循環結果（EX-03） |
| G0-QA-03 | QA | 工具配額基線 | P-01 | 1 | 配額基線文件 |
| G0-QA-04 | QA | 幀時與熱路徑驗證 | S-04、P-05 | 1 | 幀時＋RPC 計數（EX-04） |

合計 31 人週。與 `milestones/01` 的差異見 [§5](#5-估算與差異說明)。

## 2. 逐包執行細節

格式：**目的｜步驟｜完成判準｜必讀 skill**。步驟只列會影響順序或判斷的關鍵步，不列瑣事。

### G0-PLAT-01 參考平台凍結
- **目的**：讓之後每個數字都綁定在一個可重建的機器上。
- **步驟**：① 確認硬體取得管道與交期（**第一天就要啟動，交期是 G0 的最大不確定性**）；② 安裝候選發行版並記錄 [02 §2](02-platform-and-compositor.md#2-凍結維度g0-plat-01) 的全部維度；③ 寫可重建的安裝腳本；④ 選定並凍結參考應用集合，特別確認編輯器能從外部檢查未儲存緩衝；⑤ 記錄 Landlock／cgroup／秘密儲存的平台事實。
- **完成判準**：另一個人依 `packaging/reference-image/` 能重建出版本指紋一致的機器。
- **skill**：`ditto-verification-evidence`、`ditto-decision-record`（D-01）。

### G0-PLAT-02 工具鏈凍結
- **目的**：固定 Rust／Node／pnpm／Qt／Quickshell 版本與鎖定檔。
- **步驟**：① 選 Node LTS 時同時檢查與未來 vendored Cordis 的 `engines` 區間相容；② 建立 `rust-toolchain.toml`、`.nvmrc`、`packageManager`；③ 記錄 Quickshell 用到的 QML 模組與其在凍結發行版中的可得性。
- **完成判準**：乾淨環境依鎖定檔可建置；版本矩陣進 `docs/platform/support-matrix.md`。
- **skill**：`ditto-decision-record`（D-03）。

### G0-PLAT-03 合成器能力盤點與 D-02
- **目的**：查清楚合成器能做什麼、不能做什麼，並做出決策。
- **步驟**：① 先寫**合成器中立**的探針套件（[02 §4.1](02-platform-and-compositor.md#41-探針要合成器中立)）；② 全域列舉；③ 對 C-01～C-14 逐項功能探測；④ 專屬 IPC 另行探測並標記綁定；⑤ 填能力差異表（四態，「部分支援」必須寫明差異）；⑥ 依預先承諾判準做 D-02；⑦ 寫決策紀錄並回寫 `milestones/01/05`。
- **完成判準**：EX-02。
- **skill**：`ditto-decision-record`、`ditto-verification-evidence`。

### G0-PLAT-04 輸入法鏈路驗證
- **目的**：確認中文可以輸入，而不是假設它會動。
- **步驟**：見 [02 §6](02-platform-and-compositor.md#6-輸入法鏈路g0-plat-04)。
- **完成判準**：EX-08；候選視窗位置問題若無解，記為「部分支援」並說明影響，不得標記通過。
- **skill**：`ditto-prose-standard`（報告措辭）。

### G0-PLAT-05 真機 runner 與 nightly
- **目的**：讓效能與資源數字具備效力。
- **步驟**：① 註冊 self-hosted runner 並標籤化；② 建立 `nightly-refmachine.yml` 與 `weekly-measure.yml`；③ 每次執行輸出版本指紋；④ 確認 artifacts 保留期。
- **完成判準**：EX-09。
- **skill**：`ditto-verification-evidence`。

### G0-CORE-01 倉庫骨架與 CI
- **目的**：建立 G0 需要的目錄與六條工作流，**不多建**。
- **步驟**：① 依 [03 §1](03-core-and-contracts.md#1-倉庫骨架g0-core-01) 建立目錄；② 建立 cargo workspace 與 pnpm workspace；③ 六條工作流；④ 授權掃描從第一天就跑。
- **完成判準**：空骨架可建置，六條工作流全綠。
- **skill**：`ditto-authority-boundaries`（不建立第二條配置寫入路徑）。

### G0-CORE-02 契約管線與能力目錄
- **目的**：Rust-first 型別產生，並把 seam 三角規則變成 CI 規則。
- **步驟**：① `ditto-protocol` 加 schemars；② `export-schema` 產生 `schema/*.json` 與 `catalog.json`；③ TS 產生管線；④ 新鮮度 gate；⑤ **目錄一致性 gate 的四項檢查**；⑥ 契約版本規則寫進程式碼註解與 `docs/`。
- **完成判準**：EX-06 的五項。
- **skill**：`ditto-capability-contract`。

### G0-CORE-03 最小 IPC
- **目的**：一條可用、可測、會明確拒絕錯版的通道。
- **步驟**：① socket 與換行分幀；② `params._meta` 信封；③ 握手與版本協商（不相容即拒絕）；④ 封閉錯誤集與碼映射；⑤ 事件流：快照、`seq`、佇列上限、`resync_required`；⑥ 取消與逾時，含 `outcome: "unknown"`；⑦ TS client。
- **完成判準**：契約測試涵蓋正常編解碼、錯版拒絕、亂序事件、重連補事件、佇列溢位。
- **skill**：`ditto-capability-contract`。

### G0-CORE-04 呼叫身分綁定
- **目的**：讓 G1 的權限模型不必建在自述身分上。
- **步驟**：① peer credential 檢查；② 受控啟動器發放一次性 token；③ 綁定表；④ 忽略訊息中自填身分；⑤ 三項負例測試。
- **完成判準**：EX-07。
- **skill**：`ditto-permission-and-secrets`。

### G0-CORE-05 合成器轉接
- **目的**：13 項能力真的能操作原生應用。
- **步驟**：① 依差異表實作各能力，每項標註所依賴的協定列；② 不支援者回 `unsupported` 並在目錄標記 `availability`；③ **每個寫操作實作回讀比對**；④ 事件來源接上訂閱；⑤ 連線中斷處理（立即標記不可用、送 `resync_required`、重連重建投影不重播）。
- **完成判準**：EX-01 矩陣全部有明確結果。
- **skill**：`ditto-capability-contract`、`ditto-failure-and-rescue`。

### G0-CORE-06 `dittoctl probe`
- **目的**：能力的第二個消費者，也是矩陣腳本的資料來源。
- **步驟**：見 [03 §7](03-core-and-contracts.md#7-dittoctl-probeg0-core-06)。寫操作子命令一律自動回讀比對。
- **完成判準**：六個子命令可用，`--json` 輸出可被矩陣腳本消費；文件明確聲明它不是救援 CLI。
- **skill**：`ditto-prose-standard`（避免誇大範圍）。

### G0-SHELL-01 最小 Quickshell 工作階段
- **目的**：可登入、可操作原生應用的桌面。
- **步驟**：① Quickshell 入口與表面宣告；② layer-shell 頂部面板（anchor、exclusive zone）；③ Dock；④ 工作區指示與執行中視窗清單；⑤ token 最小集，**同時定義降低透明度與減少動畫的替代值**。
- **完成判準**：從登入管理器可進入工作階段，能啟動並操作參考應用。
- **skill**：`ditto-qml-shell`。

### G0-SHELL-02 角色層與本機動畫
- **目的**：角色會動，且不依賴任何服務。
- **步驟**：① 素材分層並登記來源；② 呼吸、眨眼（不等間隔）、晃動、注視、點擊回彈；③ 狀態值做成公開屬性並綁定文字標籤；④ **終止 Core 驗證動畫不中斷**。
- **完成判準**：[04 §10](04-shell-and-avatar.md#10-驗證清單) 的第 1 項；不得出現思考等無對應任務的狀態。
- **skill**：`ditto-qml-shell`。

### G0-SHELL-03 命中區
- **目的**：透明區不攔截點擊。
- **步驟**：① 建置期產生 alpha 命中遮罩；② 設定 input region；③ 雙向驗證（穿透／不穿透）；④ 快捷鍵喚回路徑；⑤ 若 C-07 為部分支援，依既定順序降級並記錄。
- **完成判準**：[04 §5.1](04-shell-and-avatar.md#51-驗證怎麼做) 的腳本化驗證通過。
- **skill**：`ditto-qml-shell`。

### G0-SHELL-04 狀態訂閱與命令接線
- **目的**：UI 的資料全部來自快照＋事件，且熱路徑不過 IPC。
- **步驟**：① `DittoClient` 握手與訂閱；② 視窗與工作區投影；③ `seq` 不連續即重新訂閱；④ 隱藏元件停止更新；⑤ `RpcCounter`；⑥ Core 不可用時顯示真實狀態。
- **完成判準**：熱路徑 RPC 計數為 0；重連後狀態正確重建。
- **skill**：`ditto-qml-shell`、`ditto-process-budget`。

### G0-QA-01 資源量測工具與報告
- **目的**：一個從第一天就格式正確的量測工具。
- **步驟**：① cgroup／單元式程序發現；② 採集欄位；③ JSONL 輸出與報告產生器；④ **排除清單做成顯式輸入**；⑤ 狀態標籤與「本階段不可量測」的標記機制。
- **完成判準**：報告範本包含 [05 §1.3](05-measurement-and-verification.md#13-輸出) 的全部欄位。
- **skill**：`ditto-verification-evidence`、`ditto-process-budget`。

### G0-QA-02 UI 重啟存活驗證
- **目的**：證明換 UI 不傷害使用者的工作。
- **步驟**：見 [05 §5](05-measurement-and-verification.md#5-ui-重啟存活驗證g0-qa-02)。
- **完成判準**：EX-03。
- **skill**：`ditto-verification-evidence`。

### G0-QA-03 工具配額基線
- **目的**：確認平台的資源限制機制可用，且候選 OOM 不會拖垮桌面。
- **步驟**：見 [05 §6](05-measurement-and-verification.md#6-工具配額基線g0-qa-03)。
- **完成判準**：三個案例通過，建議初始值進入 EX-05 的決策。
- **skill**：`ditto-process-budget`。

### G0-QA-04 幀時與熱路徑驗證
- **目的**：把 NFR-05 初測與熱路徑禁令變成 nightly 可重跑的檢查。
- **步驟**：見 [05 §4](05-measurement-and-verification.md#4-幀時取樣g0-qa-04)。
- **完成判準**：EX-04 的兩條判準。
- **skill**：`ditto-verification-evidence`、`ditto-qml-shell`。

## 3. 關鍵路徑與並行

```
硬體取得 ─► PLAT-01 ─┬─► PLAT-02 ─► CORE-01 ─► CORE-02 ─► CORE-03 ─┬─► CORE-05 ─► QA-02
                      │                                              ├─► CORE-04
                      ├─► PLAT-03（探針）──► D-02 決策 ──────────────┘
                      ├─► PLAT-05（runner）                          └─► CORE-06
                      └─► QA-03

                        SHELL-01 ─► SHELL-02 ─► SHELL-03
                              └───► SHELL-04 ─► QA-04
                        QA-01（與 CORE 並行）
```

**關鍵路徑**：硬體取得 → PLAT-01 → PLAT-03 → D-02 → CORE-05 → EX-01。

三個可以獨立推進、不必等關鍵路徑的工作：QA-01（量測工具只需骨架）、QA-03（只需平台）、CORE-02／03（契約與 IPC 不依賴合成器決策——**只要能力目錄的描述子不假設某個合成器一定支援**）。

最容易被低估的依賴：SHELL-01 需要 PLAT-03 的 C-01（layer-shell）結果才能確定面板怎麼掛。若 C-01 探測延後，SHELL-01 只能先做背景與角色，面板延到探測後。

## 4. 週序與檢查點

| 週 | PLAT | CORE | SHELL | QA | 檢查點 |
| --- | --- | --- | --- | --- | --- |
| W1 | **啟動硬體取得**；平台候選安裝 | — | — | — | G0 整體 owner 已確認為 Lei-k；各工作流負責人須在 W1 指派（D-12 的 G0 部分） |
| W2 | PLAT-01 完成；PLAT-02；探針套件開發 | CORE-01 | — | QA-01 起 | — |
| W3 | PLAT-03 功能探測；PLAT-05 | CORE-02 | SHELL-01 起 | QA-01；QA-03 | **W3 末：差異表初版**——阻斷級缺口在此浮現 |
| W4 | PLAT-03 收斂；專屬 IPC 探測 | CORE-03 | SHELL-01 完成 | QA-03 完成 | **W4 末：D-02 必須決策**（逾期阻擋出口） |
| W5 | PLAT-04 | CORE-05 起；CORE-04 | SHELL-02 | QA-01 完成 | 若 W4 決定換合成器，依 W3～W4 的備案探針結果實作並吸收差異 |
| W6 | 缺口處理方案定稿 | CORE-05；CORE-06 | SHELL-03；SHELL-04 起 | QA-02 | **W6 末：EX-01 矩陣首次全跑** |
| W7 | 支援矩陣定稿 | 缺口修補 | SHELL-04 完成 | QA-04；量測第 1、2 次 | 量測需要 3 次重複，**W7 一定要開始** |
| W8 | 授權盤點彙整 | — | — | 量測第 3 次；報告 | **出口評審**（見 [08](08-exit-review-and-handoff.md)） |

6 週是待評估的時程提案，**不是已核定的 G0 出口版本**。若要把 PLAT-04 或 SHELL-03 後移，或在 W6 進行出口評審，須先證明九項門檻仍能全部通過；做不到時應提出時程修正，不能以「條件通過」替代出口通過。任何範圍或門檻變更須依決策程序核定並回寫上位文件。**不得**縮短量測次數或跳過 nightly。

## 5. 估算與差異說明

| 工作流 | milestones/01 | 本計畫 | 差 | 理由 |
| --- | --- | --- | --- | --- |
| PLAT | 6 | 8 | ＋2 | PLAT-05 真機 runner（＋1，原計畫未列為工作項）；合成器探針套件的中立化設計（＋1，換合成器時省回來） |
| CORE | 8 | 10 | ＋2 | CORE-06 `dittoctl probe`（＋1）；目錄一致性 gate 與身分負例測試（＋1） |
| SHELL | 8 | 8 | — | — |
| QA | 4 | 5 | ＋1 | QA-04 幀時與熱路徑腳本化 |
| **合計** | **26** | **31** | **＋5** | |

這是**提案**。依 `ditto-decision-record`，核定後回寫 `milestones/01/05 §3.3`；未核定前 `milestones/01` 的數字仍然有效。

### 5.1 人力假設

| 工作流 | 建議人力 | G0 期間的實際需求 |
| --- | --- | --- |
| 平台工程 | 1 | W1–W7 全程 |
| Runtime（Core） | 2 | W2 起全程 |
| Shell／設計 | 2（含 1 設計） | 設計在 W1–W3 產出素材分層與 token，工程 W3 起 |
| QA | 1 | W2 起全程 |
| 產品 | 1 | 決策點（W4 的 D-02、W8 的出口評審） |

以 7 人在 8 週內完成 31 人週約為 55% 的有效投入率，符合同時要建立基礎設施的階段特性。若人力不足 7 人，優先保住關鍵路徑（PLAT-01／03、CORE-03／05），提出人力或時程修正；任何工作包後移都須先檢查對九項出口門檻的影響。受影響門檻可在評審中列為「條件通過」並寫明解除時點，但 G0 出口仍未通過。

## 6. 每週檢查點清單

每週結束時逐項回答，寫進進度紀錄：

1. 關鍵路徑上的工作包是否照計畫推進？延遲幾天？
2. 本週有沒有發現新的阻斷級合成器缺口？
3. 有沒有任何「先這樣、之後再改」的決定？若有，它是否會在 G1 造成返工？（尤其是配置寫入路徑與熱路徑）
4. nightly 是否綠燈？連續失敗超過兩晚即視為阻塞。
5. 是否有已到期未決的決策？（見 [07 §1](07-decisions-and-risks.md#1-g0-必須落定的決策)）
6. 本週是否產生應記錄而未記錄的決策？

## 7. 進度紀錄

更新日期 2026-09-19。狀態只有四種：**未開始**、**進行中**、**開發環境已完成**（程式與腳本可重複執行，但判定所需的實體參考機證據還沒有）、**完成**。門檻的通過與否一律在出口評審判定，本表不代表出口結果。

### 7.1 工作包狀態

| ID | 狀態 | 證據與缺口 |
| --- | --- | --- |
| G0-PLAT-01 參考平台凍結 | **未開始** | 實體機未到位。[支援矩陣草稿](../../docs/platform/support-matrix.md)已記錄候選規格與開發 VM 的平台事實（Landlock ABI 1、cgroup 控制器、`systemd --user` 未委派 `cpu`、`bwrap` 0.6.1、無 Secret Service）。`packaging/reference-image/` 尚不存在 |
| G0-PLAT-02 工具鏈凍結 | **進行中** | `rust-toolchain.toml`、`.nvmrc`、`packageManager` 與兩份鎖定檔已進版控；Qt／Quickshell／合成器版本目前只有[開發容器的值](../../docs/platform/dev-wayland-environment.md)。D-03 未核定 |
| G0-PLAT-03 合成器盤點與 D-02 | **進行中** | 探針已有兩層並實跑：全域列舉 55 個 global，功能探測給出 C-01 支援、C-02 支援、C-03 部分支援（maximize／minimize 請求後狀態不變）、C-04 需轉接、C-05 需轉接（`ext_workspace_manager_v1` 有公告但無客戶端）、C-06 部分支援。[能力差異表](../../docs/platform/compositor-capability-matrix.md)已建立。**C-07、C-08、C-09～C-14 未探測；Wayfire 完全未測；D-02 未決** |
| G0-PLAT-04 輸入法鏈路 | **未開始** | 容器未安裝輸入法；`docs/platform/input-method-report.md` 尚不存在 |
| G0-PLAT-05 真機 runner | **進行中** | `nightly-refmachine.yml` 與 `weekly-measure.yml` 已建立並指向 `ditto-refmachine` 標籤；**沒有自架 runner，兩條工作流一次都沒有執行過** |
| G0-CORE-01 倉庫骨架與 CI | **開發環境已完成** | `ditto-protocol`／`ditto-compositor`／`ditto-core`／`dittoctl`／`ditto-measure` 五個 crate、pnpm workspace、六條工作流齊備。nightly 與 weekly 待 runner |
| G0-CORE-02 契約管線與能力目錄 | **開發環境已完成** | 13 項能力的描述子由 Rust 產生 `schema/*.json` 與 TS 型別；目錄一致性 gate（handler、consumer、readback、`claimable`）與 schema 新鮮度在 PR 快檢執行。EX-06 的五項判準逐項有對應檢查，出口評審時核對 CI 紀錄 |
| G0-CORE-03 最小 IPC | **開發環境已完成** | 換行分幀、`params._meta` 信封、握手與版本拒絕、11 個封閉錯誤、事件快照與 `seq`、佇列上限與 `resync_required`、重連補事件、`$/cancel`（不可取消者明確回報未取消）、逾時與 `outcome: "unknown"`；Rust 21 項與 TS 9 項測試涵蓋跨語言編解碼、錯版拒絕、重訂閱與溢位 |
| G0-CORE-04 呼叫身分綁定 | **開發環境已完成** | 受控啟動器實際接線：token 經已開啟的描述子交付、先綁 PID 與執行檔再釋放。三項負例在容器實跑全部被拒（`tests/g0/identity-negative`）。開發模式仍是共用 token，程式與文件都標明不是 EX-07 證據 |
| G0-CORE-05 合成器轉接 | **開發環境已完成** | 13 項能力對真實合成器可用；每個寫操作回讀比對，回讀不一致回 `conflict`；平鋪視窗座標與 minimize／maximize 回 `unsupported`；斷線立即標記不可用並送 `resync_required`，重連重建投影。矩陣 23 格全部有明確結果（`artifacts/g0/window-matrix-*.jsonl`）。**參考應用集合只有終端一種** |
| G0-CORE-06 `dittoctl probe` | **完成** | 七個子命令（handshake／capabilities／outputs／workspaces／windows／window／events），寫操作自動回讀，`--json` 是矩陣腳本的資料來源；文件明說不是救援 CLI |
| G0-SHELL-01 最小 Quickshell 工作階段 | **進行中** | 背景、頂部面板、Dock、工作區指示與視窗清單可用，exclusive zone 實測生效（平鋪視窗被限制在 59～664 之間）。**沒有登入管理器工作階段檔，「從登入管理器進入」未驗證** |
| G0-SHELL-02 角色層與本機動畫 | **開發環境已完成** | 呼吸、不等間隔眨眼、注視、點擊回彈；終止 Core 後角色存活且動畫不中斷。身體層沿用凍結原型素材，臉部由 QML 繪製，來源已登記（`shell/avatar/layers/SOURCES.md`）。未做思考等無對應任務的狀態 |
| G0-SHELL-03 命中區 | **進行中** | 命中遮罩由 alpha 通道在建置期產生（24 個矩形）並以 `set_input_region` 套用，新鮮度進 PR 快檢。**透明區與不透明區的雙向點擊驗證沒有做**：容器的 headless seat 沒有指標裝置 |
| G0-SHELL-04 狀態訂閱與命令接線 | **開發環境已完成** | 快照＋事件投影、`seq` 不連續即重新訂閱、Core 不可用時顯示真實狀態。閒置、游標與拖曳期間請求數為 0；5 次明確命令各 1 個請求 |
| G0-QA-01 資源量測工具與報告 | **開發環境已完成** | `ditto-measure` 的採樣與報告、固定變因清單、完整流程腳本（冷啟動、暖機、三次重複）；工具本身拒絕在非參考機產生可引用的數字。GPU 欄位與實機採樣未做 |
| G0-QA-02 UI 重啟存活 | **開發環境已完成** | 20 次循環（10 次正常、10 次 `SIGKILL`）全部通過，未儲存內容雜湊不變，重啟中位數 130 ms。**編輯器目前是替身程序**，參考機須改用凍結的編輯器 |
| G0-QA-03 工具配額基線 | **進行中** | 三案例在開發 VM 實跑：記憶體生效（scope 被終止、見證程序不受影響）、程序數生效（64 次 fork 只成功 15 次）、**CPU 未生效**（`systemd --user` 未委派 `cpu` 控制器）。建議初始值尚未提出 |
| G0-QA-04 幀時與熱路徑 | **開發環境已完成** | 四段互動腳本、逐幀取樣與逐段請求計數已可重跑並產出 artifacts。**軟體算繪的幀時不是 NFR-05 數據** |

### 7.2 出口門檻現況

| 門檻 | 現況 | 還缺什麼 |
| --- | --- | --- |
| EX-01 原生應用可控 | 機制成立，證據不足 | 凍結的參考應用集合（瀏覽器／終端／編輯器）與參考機上的矩陣執行 |
| EX-02 合成器缺口與 D-02 | 未達成 | C-07、C-08 等未探測；備案合成器未測；決策紀錄未寫 |
| EX-03 Shell 重啟零終止 | 腳本可重跑，容器內全數通過 | 參考機、凍結編輯器 |
| EX-04 幀時與熱路徑 | 熱路徑判準已機械化通過 | 參考機的幀時數字與 `wp_presentation` 交叉驗證 |
| EX-05 PSS 預算與配額 | 流程與工具就緒 | 參考機三次量測；CPU 配額委派問題；決策核定 |
| EX-06 契約與目錄一致性 | 檢查已在 PR 快檢執行 | 出口評審逐項核對 CI 紀錄 |
| EX-07 身分無法自述 | 三項負例在容器全部被拒 | 參考機重跑並納入評審 |
| EX-08 中文輸入 | 未開始 | 輸入法安裝與三處人工驗證 |
| EX-09 真機 runner 與 nightly | 未達成 | 註冊 runner，連續三晚綠燈 |

### 7.3 期間的其他紀錄

| 日期 | 項目 | 內容 |
| --- | --- | --- |
| 2026-09-19 | G0 整體 owner（D-12 的 G0 部分） | Lei-k 已確認；各工作流負責人未指派 |
| 2026-09-19 | 開發環境 | [Wayland／Qt／Quickshell 容器紀錄](../../docs/platform/dev-wayland-environment.md)；所有容器結果皆為開發證據 |
| 2026-09-19 | 決策紀錄 | [G0 合成器轉接路徑](../../.agents/notes/decisions/2026-09-19-g0-compositor-adapter-seam.md)、[啟動器 token 交付方式](../../.agents/notes/decisions/2026-09-19-launcher-identity-handover.md) |
| 2026-09-19 | `ditto-qml-shell` skill | 仍為 `draft`。轉 `stable` 的條件是 C-07 的雙向點擊驗證完成；目前未完成，不得改標記 |
| 2026-09-19 | 對計畫的偏離 | `shell/providers/` 的目錄名改用底線（`panel_top`、`dock_bottom`）：QML 模組名不接受連字號。`dittoctl probe` 比計畫多一個 `outputs` 子命令，因為 `desktop.outputs.list` 需要一個 Consumer |
