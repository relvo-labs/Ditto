# G2 出口評審｜進度紀錄

| 欄位 | 內容 |
| --- | --- |
| 狀態 | **進行中，未評審。** 本檔記錄已取得的開發證據；十九項出口沒有任何一項已判定通過 |
| 計畫 | [plan/04](../../../plan/04/README.md) |
| 起點 | `main@787b44a`＋分支 `codex/g2-agent-foundation` 的未提交工作 |

證據類別沿用 G1：`development-host`（開發機、fixture compositor）、`development headless desktop`（開發機 headless Wayfire＋真 Shell）、`development-host-real-subscription`（開發機、真實訂閱）。開發機同時是參考機，但以下皆非參考機出口量測；資源、延遲與語意通過率尚未量測。

## 1. 里程點

| 點 | 現況 |
| --- | --- |
| M0 | 契約 0.3、Store 會話／turn／approval／偏好、Agent 生命週期與 controller 已有基礎（前一輪 foundation，`tests/g2/foundation` 兩組通過）。布局 spike（PLAT-01）、keyring 以外的 context probe（PLAT-02）尚未做 |
| M1 | 接線完成：Core 啟動隔離的 Codex app-server、動態工具經 Core、ChangeSet 回讀、Shell 對話入口與變更卡、撤銷。真實訂閱一個 turn 見 §2.4（需本人登入） |
| M2～M5 | 未開始 |

## 2. 2026-10-08 取得的證據

### 2.1 OS 邊界（PLAT-04 最小範圍）

`cargo test -p ditto-confine`：3 個測試通過。檔案／socket／埠／signal 共 18 項探測（家目錄 `EACCES`、真 session bus `EACCES`、抽象 socket 拒絕、netlink／packet／datagram Unix `EAFNOSUPPORT`、非允許 TCP 埠與 bind `EACCES`、socket family 與位址錯配 `EACCES`、signal supervisor `EPERM`），狀態行只在完整隔離後寫出，D-Bus proxy 只通 Secret Service。設計與限制見 [codex-backend-boundary](../../../docs/platform/codex-backend-boundary.md)。

發現：參考平台 AppArmor 禁止非特權 user namespace，bubblewrap 與 Codex 自帶 sandbox 都不能執行；Ubuntu 的 `xdg-dbus-proxy` 0.1.5 會斷開 zbus 用戶端（Codex keyring）。前者改用 Landlock＋seccomp connect 代理，後者改用自建 0.1.9。

### 2.2 Codex 工具面（AGENT-14、EX2-19 的一部分）

以 loopback 腳本模型攔截 0.160.0 實際送給模型的請求：目前模型族在內建目錄中為 `code_mode_only` 與 multi-agent v2，工具被包入 JavaScript `exec` 並出現 `spawn_agent` 等；功能旗標無法關閉。Core 改以衍生目錄啟動後，模型只見 Ditto 動態工具與 `request_user_input*`（adapter 拒絕）；硬叫 `exec_command`／`apply_patch`／`web_search` 均回 `unsupported call`，無副作用。

### 2.3 端到端（腳本模型）

| 測試 | 結果 | 類別 |
| --- | --- | --- |
| `tests/g2/codex/run.mjs` | 22／22：隔離由 Core 驗證、ChangeSet 歸屬 Agent turn 並 committed、回讀、`conversations` 事件不含文字、undo、後端整組停止、hostd 存活、canary 只在 Core 對話儲存 | development-host |
| `tests/g2/codex/desktop.sh` | 11／11：真 Shell 開聊天、合成鍵盤輸入、Shell 顯示 Core 變更卡與完成狀態、Esc 不取消、undo；approval 以鍵盤「允許這一次」後 Agent 才讀到視窗清單（期間聊天顯示待確認），Esc 拒絕則該呼叫被拒；Agent 停止後 Shell／hostd 同一 PID | development headless desktop |
| `tests/g2/codex/faults.mjs` | 11／11：模型呼叫中「停止」→ turn `cancelled`（約 107 ms），Codex 關閉模型串流，桌面 revision 不變；turn 中 SIGKILL app-server → turn `failed`／`interrupted`、整個 Agent 世代收掉（`backend_exited`）、無工具派送；下一次請求啟動新的已隔離世代 | development-host |

腳本模型不計入 EX2-11 語意通過率，也不是 EX2-19 的真實帳號證據。`run.mjs` 連跑三次皆 22／22。

### 2.4 真實訂閱

`tests/g2/codex/subscription.mjs`：**未完成。** 2026-10-08 執行時 Core 啟動隔離後端並經 `agent.providers.login` 取得官方授權網址（`auth.openai.com`，回呼 `127.0.0.1:1455`），等待 15 分鐘內沒有人完成登入，腳本依設計失敗於「signed in through the browser」。真實模型 turn、keyring 寫入與登入後無 `auth.json` 的檢查都尚未執行。

### 2.5 暖態 PSS 取樣（D-44 輸入，不是出口量測）

`run.mjs` 一個 turn 後讀 `smaps_rollup`，三次（KiB）：controller 15 681～15 707、`ditto-confine` 467～481、app-server 87 240～89 328、`xdg-dbus-proxy` 527～533；合計 103 953～106 021（約 102 MiB）。fixture compositor、腳本模型、非冷登入；EX2-14 仍需參考機三次冷登入四狀態量測。

## 3. 尚未做（節錄）

- EX2-19 其餘：取消／登出／切帳號、keyring 鎖定拒絕、配額耗盡、interrupt／crash 整組清理、ephemeral 重建無重播的真實帳號矩陣（QA-09）。
- D-44：controller＋app-server 的 PSS 與 cgroup 硬限制；目前後端無 MemoryMax。
- SHELL-01 完整範圍（分頁、緊湊／完整切換、context chips、approval）、SHELL-02 角色七態動畫、SHELL-04 完整 AI 設定頁、串流文字。
- 布局（PLAT-01）、上下文 broker（PLAT-02）、工作池、50＋50 題語意集、冷啟動與首幀量測。approval 已有最小 responder（§2.3），重連後補回待決請求、四結果完整矩陣與 GUI／Agent 一致性（EX2-06）未做。
