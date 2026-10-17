# G4 交接

本檔彙整進入 G4 時仍開著的項目，指定承接 issue。「有證據」只照原紀錄陳列，不因階段接受改寫為通過。

## 1. G3 交接（D-47、G3-exit §4、plan/05/06 §5）

| 項目 | 現況 | 承接 |
| --- | --- | --- |
| 真模型訂閱登入與 AT-06 真模型 | 2026-10-14 舊 head 有實體證據；`17f5d76` 只有 VM（腳本模型） | #44 |
| 實體座位重新登入、AT-07／22／26／29 實體重跑 | 同上 | #44、#56 |
| 參考機鑰匙圈與 GDM 狀態 | 2026-10-17 為切換工作階段開啟自動登入與預設 `ditto`；自動登入不解鎖鑰匙圈。owner 選擇暫時保留，非長期配置核定（來源：[#44 背景與還原清單](https://github.com/relvo-labs/Ditto/issues/44)） | #44 |
| 未合併的參考機操作分支 `hermes/g3-physical-qualification` | 針對 `17f5d76`；需決定改基底到 `main` 或棄用 | #44 |
| 模板更新後舊 validation 的相容性與重驗證（G3-exit §4.3） | 未實作 | #50 |
| 生成工作資源：worker scope＋native service 合計（§4.2） | 512 MiB 是單一宿主硬上限，不是活動成本 | #53 |
| 對話刪除是邏輯遮蔽（§4.4） | 不保證備份與磁碟抹除 | #59、#60 已知限制 |
| Qt6Test 執行期依賴、Codex 再散布、名稱與角色素材（§4.5） | 待審 | #51 |
| 救援遇到較新生成資料的語意 | 三個選項待 owner 決定 | #41 |

## 2. D-38 後續（屬 G4 的部分）

| D-38 列 | 承接 |
| --- | --- |
| G0 EX-02／08、G1 EX1-13：實體鍵盤中文輸入 | #38、#49（雙螢幕下焦點） |
| G0 EX-05、G1 EX1-10、D-06a：分層預算核定 | #53 |
| G0 EX-04、NFR-05：幀時交叉量測未達 95% | #52 |
| G0-PLAT-01、D-12／21／31：第二人重建、估算核定 | #50（以安裝包重建）、[05 §1](05-decisions-and-risks.md) |
| G1 EX1-01／02：非實作者七步錄影、安裝負例文字走查 | #56 |
| G1 EX1-12：密碼解鎖錄影 | #59 |
| G1 EX1-13、SHELL-05：實體第二螢幕、桌面基本面、Super＋數字、音量／網路 | #49、#48 |
| G1 EX1-11：UI 首幀與啟動器切換 | #52 |
| G1 EX1-04：清理壓力 tasks 複測兩次 | #56（AT-19） |
| G1 EX1-15：連續五晚 nightly、必要檢查設定 | #56 |
| G1 EX1-14、D-11：授權清單、名稱與角色素材 | #51 |
| G1 內建套件同版本不同內容的升版 | #50 |
| D-04／08／10／15／16／26～35 核定與來源清單同步 | [本計畫 §4](#4-既有未核定決策盤點) |

## 3. G2 follow-up

#35 D-44 收緊（併 #53）、#36 帳號矩陣、#37 語意集（併 #56）、#38 參考機補測（併 #55、#47、#44）、#39 hostd 恢復判定。這些 issue 保留原內容，掛在 #42 之下；不重複開工。

## 4. 既有未核定決策盤點

2026-10-17 讀 `39da297` 的決策紀錄與實作，結論如下。「實作現況」只說明程式碼目前的選擇，不等於決策已核定。

| 議題 | 紀錄狀態 | 實作現況 | 處置 |
| --- | --- | --- | --- |
| D-04 Cordis 來源 | 計畫預設，無紀錄 | `packages/host-runtime/vendor/` 鎖定 Harness `477b4f4`，修改紀錄見其 README | 需 owner 核定；#51 盤點前完成 |
| D-08 生成執行隔離 | 計畫預設，待核定 | G3 以 `ditto-confine` 與兩個固定模板落地（[generated-template-boundary](../../docs/platform/generated-template-boundary.md)） | 需 owner 核對實作邊界並核定；D-47 只接受階段出口，不代表核准此技術提案 |
| D-10 套件格式 | 提案（[manifest](../../docs/contracts/manifest.md)） | `.dittopkg`、整檔 sha256、內容地址展開 | 需 owner 核定；#50 依 D-18 一併處理 |
| D-15 Profile 儲存 | 計畫預設 | SQLite 權威（WAL、`synchronous=FULL`）、JSON 匯出 | 需 owner 核定 |
| D-16 兩個 Cordis 服務 | 計畫預設 | `packages/plugins/svc-tasks`、`svc-notification-policy` | 需 owner 核定 |
| D-17 生成插件選型 | 2026-10-14 已決定，僅記於 #34 | 兩個固定模板 | 本計畫補錄 [D-17](../../.agents/notes/decisions/2026-10-14-d17-g3-generated-plugin-selection.md) |
| D-26 Core 並行與 SQLite | 提案 | 單一協調器（mpsc）、`rusqlite` bundled、WAL＋FULL | 需 owner 核定 |
| D-27 hostd 連線與身分 | 提案 | 共用 `core.sock`；`on_behalf_of` 以已分派條目驗證 | 需 owner 核定 |
| D-28 通知伺服端 | 提案 | `ditto-system` 的 `notify.rs`，策略詢問 50 ms | 需 owner 核定 |
| D-29 救援形態 | 提案 | `shell/rescue/`、`dittoctl rescue`、`--offline` | 需 owner 核定；與 #41 一起看 |
| D-30 鎖定客戶端 | 提案 | `shell/lock/` 經 ext-session-lock | 需 owner 核定 |
| D-31 G1 估算 | 提案 | — | 歷史估算；併入 D-12 |
| D-32 hostd 候選策略 | 提案 | `defaultStrategy = 'isolate_rebuild'`（策略 A） | 需 owner 核定 |
| D-33 布局策略路徑 | 提案 | Wayfire 受控交接（`simple-tile`） | 需 owner 核定 |
| D-34 10 個簡單插件 | 提案 | 驗證用 built-ins（`install-session.sh --verification-relay`） | 需 owner 核定；#53 A/B 使用 |
| D-35 協定 0.2 凍結 | 已被 D-39 取代（2026-10-09） | 已由 [D-39](../../.agents/notes/decisions/2026-10-09-d39-protocol-0-3-freeze.md) 協定 0.3 取代 | 標為被取代 |

表內仍待 owner 核定的提案建議在 G4 開工評審批次核對，結果逐列回寫 `milestones/01/05-risks-decisions.md`。未確認前只把現有程式碼當作盤點基線，不以「照計畫實作」或階段接受代替核定；各提案只阻擋依賴該決策的實作或出口，不阻擋不相關工作與本文件交付。D-31 的歷史估算與 D-12 一起核對，D-35 不再另行核定。
