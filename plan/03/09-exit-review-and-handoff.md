# 09｜出口評審與 G2／G3 交接

> 對應 `milestones/01/03` 的階段出口評審檢查表與 `ditto-decision-record` 第 4 步。

## 1. 評審程序

| 時點 | 動作 |
| --- | --- |
| W14 末（M4） | 預檢十五項門檻，列出缺口；確認 nightly 的 G1 套件已全部上線 |
| W15 | **功能凍結**：只修缺口與補證據；清理壓力與延遲量測；資源量測第 1 次 |
| W16 | 資源量測第 2 次；人工驗收 M-01～M-09；移植紀錄定稿 |
| W17 | 資源量測第 3 次；nightly 連續 5 晚完成；產生所有報告；逐項預檢 |
| W18 | 評審會議；逐項裁決；寫 `.agents/notes/gate-reviews/G1-exit.md`；回寫 `milestones/01/03`（門檻結果）、`04`（量測數字）、`05`（決策與新風險） |

評審不是簡報，是逐項核對證據檔案。**門檻結果只寫「通過」而沒有量測條件、原始資料位置與對應 commit 的，視為未完成核對。**

## 2. 評審紀錄範本

`.agents/notes/gate-reviews/G1-exit.md` 的固定結構：

```markdown
# G1 出口評審

| 欄位 | 內容 |
| --- | --- |
| 評審日期 | YYYY-MM-DD |
| 版本指紋 | 核心／Qt／Quickshell／Wayfire／Rust／Node／Ditto commit／harness commit／vendored Cordis 版本 |
| 參考機 | 硬體識別（含第二螢幕型號） |
| 出席 | 角色 |

## 1. 門檻逐項結果

| 門檻 | 結果 | 證據 | 備註 |
| --- | --- | --- | --- |
| EX1-01 手動跨插件切換與保存 | 通過 ｜ 未通過 ｜ 條件通過（附條件） | artifacts 路徑、錄影 | |
| EX1-02 預檢拒絕 | | | |
| EX1-03 回復 | | | |
| EX1-04 清理壓力 | | | |
| EX1-05 無 Node 救援 | | | |
| EX1-06 跨語言契約 | | | |
| EX1-07 Cordis 獨立服務 | | | |
| EX1-08 生命週期 L-01～L-10 | | | 正例與負例分列 |
| EX1-09 持久故障 | | | |
| EX1-10 分層資源基線 | | | |
| EX1-11 本機操作、切換與存活 | | | |
| EX1-12 救援、監督與鎖定 | | | |
| EX1-13 桌面基本面 | | | |
| EX1-14 移植紀錄與來源守門 | | | |
| EX1-15 CI 與 nightly | | | |

（不得只寫整體結論。「條件通過」必須寫出條件與解除時點；任何一項仍為條件通過時，G1 出口尚未通過，除非範圍或門檻變更已依決策程序核定並回寫上位文件。）

## 2. 量測數字與條件

（EX1-10 的四組狀態、3 次重複的個別結果、完整程序清單、排除清單、hostd 的 Node 三欄；EX1-11 的 p50／p95／最大值；EX1-04 的計數快照與趨勢檢定結果。）

## 3. 未達標項目

（每項：實際數據、原因分析、調整提案與核定紀錄。未核定的提案不構成通過。）

## 4. skill 狀態核對

（`ditto-cordis-plugin`、`ditto-failure-and-rescue` 依實際 API 與救援能力表核對，提出轉 stable 或維持 draft；`ditto-permission-and-secrets` 記錄 G1 已落地與待 G2 的部分。）

## 5. 本階段產生的新風險與新決策

（回寫 milestones/01/05 的清單，列出對應列。）

## 6. 下一階段的估算修正

（G2／G3 的人週修正與理由，特別是協定 0.2 凍結後 G2 的起點與 G1 實際人力耗用。）
```

## 3. 交付物清單

出口評審時逐項確認存在且可開啟：

| # | 交付物 | 位置 |
| --- | --- | --- |
| 1 | 儲存層與遷移 | `crates/ditto-store/` |
| 2 | Core：協調器、預檢、路由、授權、監督、恢復、套件 | `crates/ditto-core/` |
| 3 | 系統轉接 | `crates/ditto-system/` |
| 4 | 監督與救援 | `crates/ditto-supervisor/`、`crates/dittoctl/`（`rescue` 子命令）、`shell/rescue/` |
| 5 | 協定 0.2 契約產物 | `schema/`、`packages/protocol/src/generated/`、`docs/contracts/protocol-0.2.md` |
| 6 | Core↔hostd 協定與 manifest 規格 | `docs/contracts/host-protocol.md`、`docs/contracts/manifest.md`、`schema/manifest.json` |
| 7 | ProfileDocument 與儲存 schema | `docs/contracts/profile-document.md`、`docs/contracts/store-schema.md` |
| 8 | hostd 與交易層 | `packages/host-runtime/` |
| 9 | vendored Cordis 與修改集 | `packages/host-runtime/vendor/`、`vendor/README.md` |
| 10 | 兩個服務插件 | `packages/plugins/svc-tasks/`、`packages/plugins/svc-notification-policy/` |
| 11 | host-sdk 與範例 | `packages/host-sdk/` |
| 12 | 10 個簡單插件與故障夾具 | `packages/plugin-fixtures/` |
| 13 | Shell：供應者、四個中心、變更卡、鎖定、i18n | `shell/` |
| 14 | systemd user unit 與登入工作階段 | `packaging/` |
| 15 | 移植紀錄與沿用對照表 | `docs/upstream/cordis-port.md`、`milestones/01/02 §2` 更新 |
| 16 | 合成器能力差異表新列（C-15～C-19） | `docs/platform/compositor-capability-matrix.md` |
| 17 | 支援矩陣更新（第二螢幕、縮放值） | `docs/platform/support-matrix.md` |
| 18 | G1 驗證腳本 | `tests/g1/`、`tests/contract-vectors/0.2/` |
| 19 | 量測與驗證報告 | `artifacts/g1/`（不進版控，路徑固定） |
| 20 | 人工驗收簽核表 | `.agents/notes/gate-reviews/G1-manual-acceptance.md` |
| 21 | 決策紀錄（D-04／08／10／15／16／26～35） | `.agents/notes/decisions/` |
| 22 | 出口評審紀錄 | `.agents/notes/gate-reviews/G1-exit.md` |
| 23 | 授權與依賴清單 | `licenses.yml` 產物、`docs/platform/dependency-inventory.md` |

`CLAUDE.md` 的「目錄」與「專案現況」段落在出口後更新，反映 `docs/contracts/` 與 `packages/` 的新內容；更新時只寫已驗證的事實（`ditto-prose-standard`）。

## 4. G2 開工前置條件

G2 可以在 M3（W11）開始，條件見 [07 §4](07-workplan.md#4-g2-可開工點m3) 的 G2-S1～S6。以下是 G2 依賴 G1 交出、而且在 G1 出口前必須完成的項目；任一缺失，G2 的對應工作只能延後而不能繞過：

| G2 需要 | 來自 G1 | 缺失的後果 |
| --- | --- | --- |
| 凍結的協定 0.2 與完整能力目錄 | CORE-15、CORE-05 | G2-AGENT-05 的工具封裝會追著契約跑，且模型可能被引導呼叫不存在的能力（CON-03） |
| ChangeSet 的完整狀態機與四種結果類別 | CORE-03／07／08 | G2-AGENT-06 的「意圖 → ChangeSet」沒有可驗證的落點；模型輸出直接變成配置（違反原則 3） |
| 單一授權入口與 `agent` 主體 | CORE-06 | G2-CORE-02 的 approval seam 沒有可接的入口，AT-14 無從驗證 |
| 基底 revision 檢查 | CORE-03 | AT-10 無從驗證；Agent 會覆寫使用者剛做的調整 |
| `operation_id` 查詢與崩潰恢復 | CORE-08、CORE-11 | AT-11、AT-28 無從驗證；Agent 重啟後可能重播副作用（RUN-04） |
| hostd 的存活與 Agent 無關 | HOST-11、EX1-07 | AT-24 的「Cordis 服務保持運行」沒有基線 |
| 會話儲存的預留表 | CORE-01 | G2-AGENT-04 的 Core-backed `SessionPersistence` 需要破壞性遷移 |
| Agent 替身的教訓 | QA-07 | G2 的 Agent 生命週期測試要從零設計 |

## 5. G3 開工前置條件

`milestones/01` 規定 G3 **不得繞過** G1 的變更與救援基礎。G3 開工時必須確認：

| G3 需要 | 來自 G1 |
| --- | --- |
| 候選在 prepare 階段不取得正式資源、失敗自動 abort | HOST-02、SHELL-13 |
| 監督停用故障插件、救援恢復最近可用組合 | CORE-10、PLAT-03／04 |
| 配額施加機制（測試宿主類 profile 已有參數與測試） | CORE-14 |
| `GeneratedArtifact` 與 `MigrationRecord` 的預留表 | CORE-01 |
| manifest 的 `trust_level`、`data_schema`、`migrations` 欄位 | HOST-09 |
| D-08 的隔離方向與 G1 配額設計一致 | D-08 |

G1 未出口時 G3 不得開工，沒有例外。

## 6. 未解決事項的攜帶方式

| 種類 | 怎麼帶走 |
| --- | --- |
| 已知缺口（某項能力回 `unsupported`、某策略降級為工作階段重啟） | 寫進能力目錄的 `availability` 與差異表，**不是**寫進 TODO 註解 |
| 條件通過的門檻 | 在評審紀錄寫明條件與解除時點，並在 G2 的第一次週檢查點複查 |
| 未達標的指標 | 附數據的調整提案進入決策程序；核定前 `milestones/01` 的原始門檻仍然有效 |
| 新發現的風險 | 回寫 `milestones/01/05` 的風險登記，附徵兆與處理 |
| 對權威文件的回饋 | 記入 `plan/01/05` 的回饋清單，由產品裁決 |
| `draft` skill 的核對結果 | `ditto-cordis-plugin`、`ditto-failure-and-rescue` 提出轉 stable 或維持 draft 的判定與理由 |
| Agent 替身 | 由 G2 計畫決定保留為夾具或刪除；不得成為 `ditto-agentd` 的起點 |

**不接受的攜帶方式**：把未解決的事寫成「已完成但有小問題」、把門檻改寫成當前狀態、把某項能力從範圍中靜默移除，或把 G1 替身驗過的結果寫成 Agent 已驗證。
