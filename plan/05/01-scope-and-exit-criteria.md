# G3 範圍與出口

2026-10-13 owner 已依 D-46 接受 G2 功能完成並要求完整 G3；下列 G2 表格保留開工時的證據快照，量測缺口繼續追蹤。

本檔為執行提案，權威順序見 [README](README.md)。盤點基底 `a88bce8`，日期 2026-10-13。

## 1. 現有實作與缺口

| 實際位置 | 已有行為 | G3 缺口 |
| --- | --- | --- |
| `crates/ditto-confine/src/main.rs` | Landlock ABI ≥6、檔案允許清單、connect broker、abstract socket／signal scoping、私有 status fd；ABI 不足拒絕執行 | 後端用途，不是生成宿主；沒有生成 cgroup／deadline 的完整證據，不可照搬 `confined:true` 為 `full` |
| `crates/ditto-core/src/jobs_pool.rs`、`src/bin/ditto-worker.rs` | 兩個重型工作並行、排隊、取消、systemd scope 配額、受信任工作種類 | 不接受生成候選，不是 OS 安全沙箱；未有可發現的生成工作 |
| `crates/ditto-store/src/schema.rs` | schema v3、Profile／revision／套件／會話／工作權威狀態 | 沒有 `GeneratedArtifact`、驗證歷程、候選父版本與資料遷移紀錄 |
| `crates/ditto-protocol/src/manifest.rs` | manifest 與選用 `data_schema`；Rust-first schema 管線 | 沒有生成描述／驗證報告／強制執行等級的正式契約 |
| `packages/host-sdk/templates/qml-provider/` | 作者用的自由 QML Dock 範本 | 不可直接提供給模型執行；需要固定模板引用與封閉的資料描述 |
| `packages/agent-runtime/src/tool-catalog.ts` | 安裝套件組合、Core 工具白名單，明言尚無新插件生成 | 沒有 development Consumer；必須同 Provider／Definition 一起交付 |
| `shell/providers/` | 可替換可信供應者、健康與交接 | 不能載入任意候選；生成預覽須獨立；啟用僅可解譯已核可描述 |
| `docs/upstream/harness-g2-port.md` | 三類移植盤點、9 檔雜湊與工具釘選 | AT-18 尚需對應實際運行與 G3 新增範圍 |

`bwrap` 在參考平台受 AppArmor 的非特權 user namespace 規則阻擋，G2 已有明確證據。提案沿用倉庫內的 `ditto-confine`，不另移植 Harness sandbox，也不要求放寬系統政策。其不足須以測試與實際回報揭露。

## 2. G2 十九項交接

全部依 [G2-exit §2](../../.agents/notes/gate-reviews/G2-exit.md) 盤點；「有開發證據」不等於「已交接」。下列各列保留開工時的 **待 G2 評審** 快照；目前功能交接依 D-46 已接受，未執行量測不回填。本次 G3 實作與出口狀態見 [G3-exit](../../.agents/notes/gate-reviews/G3-exit.md)。

| G2 出口 | G2 現況 | 交接狀態 | 影響 G3／仍缺證據 |
| --- | --- | --- | --- |
| EX2-01 三類一個計畫 | 部分 | 待 G2 評審 | 生成後仍走同一 ChangeSet；參考機原生應用 |
| EX2-02 多輪保持範圍 | 部分 | 待 G2 評審 | #27 再修改不擴大範圍；參考機重跑 |
| EX2-03 Profile 與撤銷 | 部分 | 待 G2 評審 | #21／25 回退；未儲存應用存活 |
| EX2-04 GUI／Agent 競爭 | 有開發證據 | 待 G2 評審 | #19／25 base revision 與撤權競爭 |
| EX2-05 斷線／逾時／取消 | 有開發證據 | 待 G2 評審 | #24／26 持久工作與未知結果；真模型行為 |
| EX2-06 授權與注入 | 有開發證據 | 待 G2 評審 | #19／23 共用授權、鎖定／撤銷；真模型注入 |
| EX2-07 閒置退出 | 有開發證據 | 待 G2 評審 | #26 工作用 lease 不靠聊天視窗；參考機 approval 等待 |
| EX2-08 受理前後終止 | 有開發證據 | 待 G2 評審 | #25 不重播已受理啟用；參考機 |
| EX2-09 keyring／隱私 | 有開發證據 | 待 G2 評審 | #20 來源最小化、缺秘密引用的匯入端到端 |
| EX2-10 離線／停用 | 部分 | 待 G2 評審 | 無 Agent 可查候選、回復；實體斷網流程 |
| EX2-11 語意任務 | 部分；v3 48／50、47／50 | 待 G2 評審 | #28 真模型；目前為巢狀桌面＋Chrome，須參考機 Firefox |
| EX2-12 冷啟動 | 部分 | 待 G2 評審 | G3 不新增常駐服務；真後端／參考機首字 |
| EX2-13 首幀 | 部分 | 待 G2 評審 | 預覽與卡片；實體 wp_presentation |
| EX2-14 四態冷登入 | 參考機未執行；VM Agent p95 168.5～171.6 MiB 超過 150 | 待 G2 評審 | 資源基線；Core／協定依 D-46 接線，量測缺口保留，不改門檻 |
| EX2-15 工作池／配額 | 有開發證據；D-44 hard limit 未設定 | 待 G2 評審 | #16／26／31；不能把 worker limits 當 sandbox |
| EX2-16 聊天外觀／七態 | 部分 | 待 G2 評審 | 預覽／修復／失敗文字，實體中文與 reduced motion |
| EX2-17 會話／設定持久 | 有開發證據 | 待 G2 評審 | #20 來源、工具屏障與重啟對帳 |
| EX2-18 來源／契約／身分 | 有開發證據 | 待 G2 評審 | #19／29，CI 首次 runner 執行與重新產生檢查 |
| EX2-19 真實訂閱矩陣 | 部分；10 項已跑，第二帳號／耗盡未產生 | 待 G2 評審 | #26／28 生成成本與錯誤，不推定帳號矩陣完成 |

## 3. 五項出口（照錄上位計畫）

- [ ] AT-06：生成待辦摘要與快捷動作面板，有新產物、驗證與預覽，可啟用並繼續修改。
- [ ] AT-07：無效 QML／逾時／非法 imports 不進主 Shell；顯示失敗且桌面可用。
- [ ] AT-18：三類固定上游能力運行，功能、來源、相容性與修改均可追溯。
- [ ] AT-22：新插件資料 schema 升級後回退，依快照／相容政策回復。
- [ ] 生成插件在隔離宿主中受檔案／網路／程序與時間邊界限制；無法執行時降為可檢視候選。

AT-26／29 依 [milestones/01/04](../../milestones/01/04-verification.md) 也在 G3 首次驗證；不等到 G4 才處理未信任候選與超限。自由 QML／Node／原生入口、資料連接器、嵌入式腳本引擎及 G4 發行授權盤點均不在本階段範圍。
