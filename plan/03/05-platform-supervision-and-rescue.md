# 05｜平台：監督、救援、雙螢幕與 Wayfire 路徑

> 對應工作包：G1-PLAT-01～05，以及 G1-CORE-10 的程序監督部分。開工前讀 `ditto-failure-and-rescue`（draft；PLAT-03／04 完成後核對第 3 步能力表並轉 stable）與 `ditto-process-budget`。

## 1. 監督分工

G1 有三層監督，每一層只監督它能正確判斷的對象：

| 監督者 | 監督對象 | 判斷依據 | 不做的事 |
| --- | --- | --- | --- |
| **systemd user manager** | Core、`ditto-supervisor` | 程序退出、`WatchdogSec` 逾時、重啟次數 | 不判斷 hostd 該不該活著 |
| **Core** | hostd、Shell、鎖定客戶端（經受控啟動器） | Profile 需求、心跳、租約 | 不監督自己 |
| **`ditto-supervisor`** | Shell 的回應性；Core 故障時啟動救援介面 | `shell.sock` 的 ping；systemd 的 `OnFailure` | 不寫任何配置；不依賴 Node |

`ditto-supervisor` 必須**獨立於被監督者**：不依賴 Shell、不依賴 Node、不隨一般插件更新而被替換（`ditto-failure-and-rescue` 第 4 步）。它是一個小型 Rust 二進位，沒有 IPC 伺服端，也不持有任何權威狀態。

## 2. systemd user unit（G1-PLAT-02）

G0 全部使用 `systemd-run` 的 transient scope。G1 改為安裝常駐 unit，理由是 transient scope 沒有 `Restart=`、`StartLimit*`、`WatchdogSec` 與 `OnFailure=`，而這四樣正是 REC-02 需要的。

| Unit | 內容 | 關鍵設定 |
| --- | --- | --- |
| `ditto-session.target` | 工作階段目標；登入 script 啟動它 | `BindsTo=graphical-session.target` |
| `ditto-core.service` | `ditto-core serve --compositor wayfire` | `Type=notify`、`WatchdogSec=10`、`Restart=on-failure`、`RestartSec=1`、`StartLimitIntervalSec=120`、`StartLimitBurst=5`、`OnFailure=ditto-rescue.service` |
| `ditto-supervisor.service` | Shell 回應性監看 | `Restart=always`；不依賴 `ditto-core.service` 的存活 |
| `ditto-rescue.service` | 救援介面（§3） | 由 `OnFailure=` 或 supervisor 啟動；`Conflicts=` 主 Shell 的 scope |
| hostd、Shell、鎖定客戶端 | 仍由 Core 的受控啟動器以 `systemd-run --scope` 啟動 | 身分綁定需要 Core 啟動它們（G0 的受控啟動器）；scope 名稱固定，量測工具可依 cgroup 分層 |

Wayfire 與 Fcitx 維持 G0 的登入 script 啟動方式（`ditto-g0-wayfire.scope` 等改名為 `ditto-wayfire.scope`），因為它們的存活與工作階段相同，重啟合成器屬於「工作階段重啟」等級。

`Type=notify` 需要 Core 呼叫 `sd_notify(READY=1)` 並定期送 `WATCHDOG=1`。watchdog 的送出點放在**協調器迴圈**而不是獨立執行緒，這樣協調器卡死時 watchdog 會真的逾時。

登入 script（`packaging/reference-image/session/`）由 `ditto-g0-session` 更名為 `ditto-session`，G0 的 GDM drop-in 與殘留工作階段清理邏輯沿用。

## 3. 救援介面（G1-PLAT-03 的 UI 部分，D-29）

NFR-08：Shell 退出或無回應後 **10 秒內**提供可操作介面。

| 情境 | 偵測 | 救援介面 |
| --- | --- | --- |
| Shell 退出 | Core 的受控啟動器看到子程序退出 | Core 重啟 Shell（退避）；10 分鐘內 3 次失敗 → 啟動救援介面 |
| Shell 無回應 | supervisor 每 2 秒 ping `shell.sock`，連續 3 次無回應（6 秒）。例外：每一代 Shell 第一次回應後 60 秒內是啟動寬限，要連續 10 次無回應（約 20 秒）才判定，所以啟動中卡死仍在約 21 秒內處理；寬限結束後回到 3 次規則（[D-53](../../.agents/notes/decisions/2026-10-27-d53-supervisor-startup-grace.md)） | `SIGKILL` Shell → 啟動救援介面，不先嘗試重啟（無回應的原因可能是某個供應者，重啟會再卡住） |
| Core 重啟風暴 | systemd `OnFailure=` | 啟動救援介面；此時 Core 不可用，救援介面進入離線模式（§4.3） |

救援介面是 `shell/rescue/` 的**獨立 Quickshell 設定**：

- 沒有角色、沒有供應者、沒有管理中心、不載入任何插件的 QML。
- 只有四件事：視窗清單（聚焦、關閉請求）、「停用最近變更的插件」、「恢復最近可用組合」、「顯示診斷」。
- 若 Quickshell 本身無法啟動（例如 Qt 函式庫損壞），fallback 為在 foot 中執行 `dittoctl rescue`（文字介面）。

救援介面的能力清單**刻意最小**。要增加任何一項都走決策程序（`ditto-failure-and-rescue` 刻度範例：「救援模式也能改主題」是反例）。

## 4. `dittoctl` 救援（G1-PLAT-03）

### 4.1 子命令

| 子命令 | 作用 | 需要 Core？ |
| --- | --- | --- |
| `dittoctl rescue status` | Core、hostd、Shell 的狀態；目前 revision；受保護版本 | 否（Core 不在時讀資料庫） |
| `dittoctl rescue history [--limit N]` | 最近的變更與結果類別 | 否 |
| `dittoctl rescue disable <entry\|package>` | 以 ChangeSet 停用插件 | 是；Core 不在時走離線模式 |
| `dittoctl rescue restore-last-good` | head 移到 `last_known_good` | 是；Core 不在時走離線模式 |
| `dittoctl rescue diag [--change <id>]` | REC-07 的診斷集合；日誌以 `change_id` 串聯 | 否 |
| `dittoctl rescue restart <core\|hostd\|shell>` | 經 systemd 或 Core 重啟 | 部分 |

`dittoctl` 以受控啟動器身分連線時主體為 `cli:rescue`。在一般工作階段中，使用者從 tty 或另一個登入工作階段執行 `dittoctl` 時沒有啟動器 token，這種情況下 `dittoctl` **只能**走 §4.3 的離線模式或唯讀查詢。唯讀查詢是否允許無 token 連線，屬於 D-29 的一部分；本計畫的預設是**不允許**（SEC-09），唯讀資訊改由離線模式直接讀資料庫。

### 4.2 G0 的 `dittoctl probe` 保留

`probe` 子命令保留並升級到協定 0.2；它仍是能力的第二個 Consumer。`rescue` 與 `probe` 分開，文件中不混稱。

### 4.3 離線模式與權威

Core 起不來時，救援仍要能「切回最近可用配置」與「停用故障插件」。這碰到原則 1（權威只有一份），所以設計要說清楚：

- **權威是 `ditto-store` 這段程式碼加上 `core.lock` 這把鎖，不是某個程序。** Core 執行時持有 `flock(core.lock)`；`dittoctl --offline` 只有在取得同一把鎖時才能開啟資料庫寫入。兩者不可能同時寫入。
- 離線模式只允許兩種寫入：`restore-last-good`（移動 head，產生 `origin_kind=rescue` 的 revision）與 `disable`（產生停用該 entry 的 revision）。兩者都**不執行**任何參與者的副作用，只改 Profile；Core 下次啟動時依新的 head 掛載。
- 離線寫入的 revision 在變更歷史中標示「救援時離線套用」，Core 啟動後照常以回讀驗證實際狀態。
- 這個設計是 D-29 要核定的內容；若被否決，備案是「Core 以 `--mode rescue` 最小啟動（不載入 Profile 中的任何插件）後由 `dittoctl` 線上操作」，代價是 Core 本身的故障會讓救援失效。

## 5. 無 Node 救援模式（G1-PLAT-04）

AT-23 與 RUN-01：Cordis 與 Agent 都停止時，只保證三件事——原生應用基本操作、讀取歷史、切回最近可用配置；依賴 Cordis 的功能明確標示不可用。

| 項目 | 做法 |
| --- | --- |
| 進入 | `ditto-core --mode rescue`，或正常模式下 hostd 進入重啟風暴後由 Core 自動轉入「hostd 不可用」狀態（兩者對使用者呈現相同） |
| Core 的行為 | 不啟動 hostd；Profile 中 `host: cordis` 的條目不掛載；對應能力 `availability` 為 `rescue_mode` |
| Shell 的行為 | 正常啟動（Shell 不依賴 Node）；tasks 面板與通知策略顯示「暫不可用」；通知照常顯示（策略失敗時預設顯示） |
| 切回最近可用配置 | 只套用其中 `qml` 與 `core_builtin` 的部分；`cordis` 的部分記錄為「待恢復正常模式後套用」 |
| 恢復正常模式 | Core 啟動 hostd，以 `origin=host_boot` 推送條目；tasks 資料因存在 Core 的插件資料區而完整 |
| 驗證 | 程序清單中沒有任何 Node 程序（EX1-05 ⑤）；資源報告另列一組（EX1-10 ①） |

不在 Node 之外重寫任何 Cordis 服務來讓救援模式「看起來更完整」。那會把依賴帶回救援路徑（`ditto-failure-and-rescue` 第 3 步最後一段）。

## 6. 布局策略與全域快捷鍵（G1-PLAT-05）

### 6.1 先探測

G0 差異表留下三個與 G1 直接相關的事實：C-05 是 Wayfire 自己 IPC 的固定 3×3 格線；已平鋪的視窗移動回 `unsupported`；C-06 的 scale 只能讀啟動設定。G1 的第一週要探測以下項目，結果寫回 `docs/platform/compositor-capability-matrix.md` 的新列（編號接續 C-15 起）：

| # | 能力 | 候選路徑 | 探測 |
| --- | --- | --- | --- |
| C-15 | 平鋪策略切換 | Wayfire `simple-tile` plugin；IPC 能否在執行期啟用／停用或切換視窗的平鋪狀態 | 切換後以 `desktop.windows.list` 回讀幾何 |
| C-16 | 全域快捷鍵綁定 | Wayfire `command` plugin 的綁定；IPC 能否執行期新增／移除綁定；或由 Shell 以 layer-shell 鍵盤獨占實作特定快捷鍵 | 新增綁定、觸發、移除後確認不再觸發 |
| C-17 | 輸出縮放與排列變更 | `wlr-output-management` 或 Wayfire IPC | 變更後回讀；供限時回復使用 |
| C-18 | 輸出熱插拔事件 | IPC 事件或 `wl_output` global 的增減 | 以第二螢幕實際拔插 |
| C-19 | 鎖定客戶端死亡時的行為 | `ext_session_lock_v1` | 鎖定後 `SIGKILL` 鎖定客戶端，檢查畫面是否仍被遮蔽 |

### 6.2 布局策略

- `layout.strategy` slot 的兩個 `core_builtin` 供應者：`wayfire-floating` 與 `wayfire-simple-tile`，由 `ditto-compositor` 實作。
- 切換屬於**受控交接**：候選策略先確認 Wayfire 端可用（prepare）→ 切換 → 以視窗幾何回讀（readback）。
- 若 C-15 探測顯示執行期無法切換，平鋪策略的切換降為「工作階段重啟」等級（下次登入套用），並如實標示；**不以重啟合成器的方式偷偷套用**。這會影響 EX1-01 ③，須在 W3 前依 [08 G1-R4](08-decisions-and-risks.md#3-g1-專屬風險) 決定處理方式。

### 6.3 快捷鍵

- 快捷鍵的權威在 Profile 的 `shortcuts`；Core 在 commit 時經 C-16 的路徑綁定，並在 readback 讀回綁定清單。
- 單一擁有者：同一組合鍵只能有一個命令；預檢第 10 項擋下衝突。替換 Dock 或啟動器時，舊供應者的快捷鍵在 commit 階段先解綁、再綁新的（CHG-03、AT-04）。
- 救援相關的快捷鍵（喚出救援、鎖定）由 Core 保留，插件不得宣告。

## 7. 雙螢幕、縮放與熱插拔（G1-PLAT-01）

| 項目 | G1 內容 |
| --- | --- |
| 硬體 | 參考機 `ditto-ref-ws-rtx4060-01` **需要第二台實體螢幕**；W1 取得並記錄進支援矩陣（型號、解析度、連接埠）。沒有第二螢幕時 EX1-13 ⑤ 無法判定 |
| 縮放 | 支援 1.0 與 1.25（或凍結清單中的兩個值）；縮放變更走限時回復 |
| 熱插拔 | Core 訂閱輸出事件；輸出消失時，以 `desktop.windows.move` 把該輸出上的視窗移到剩餘輸出的可見範圍，無法移動的（已平鋪、`unsupported`）記錄並以通知說明；角色由 Shell 移到主輸出 |
| 工作區 | 格線是每個輸出各一組（G0 C-05）；熱插拔後工作區指示依剩餘輸出重建 |
| 驗證 | `tests/g1/output-hotplug/run.sh`：實體拔插（腳本引導操作員）＋ `wlr-randr` 停用輸出的自動化版本；兩者都要通過 |

## 8. 驗證

| 驗證 | 對應門檻 |
| --- | --- |
| Shell `SIGSTOP` → 救援介面出現時間（30 次，報 p95） | EX1-12 ①、NFR-08 |
| Core 連續 `SIGKILL` 5 次 → `OnFailure` → 救援離線模式可恢復最近可用組合 | EX1-12 ③ |
| 故障插件連續崩潰 → 被停用、不再重啟 | EX1-12 ② |
| `--mode rescue` 的三項能力與程序清單 | EX1-05 |
| 鎖定客戶端死亡 → 仍鎖定 | EX1-12 ④（C-19） |
| 輸出熱插拔 | EX1-13 ⑤ |
