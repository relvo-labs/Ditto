# Codex app-server 的執行邊界（G2-PLAT-04／AGENT-14 最小範圍）

| 欄位 | 內容 |
| --- | --- |
| 狀態 | 開發機實作與自動測試完成；參考機資源量測、真實帳號矩陣（QA-09）與 D-44 裁定尚未完成 |
| 版本 | `codex-cli 0.160.0`，sha256 見 [tools/codex/pin.json](../../tools/codex/pin.json) |
| 依據 | [D-09a](../../.agents/notes/decisions/2026-10-07-d09a-codex-subscription-app-server.md)、[plan/04/10](../../plan/04/10-codex-app-server.md) |

## 1. 誰啟動、誰證明

Core 是唯一啟動者，也是唯一能把後端標成「已隔離」的一方：

1. Core 依 `--agent-backend "codex-app-server 0.160.0 <sha256> <path>"` 驗證二進位雜湊（依 path／size／mtime 快取），不符即拒絕（`backend_binary_mismatch`）。
2. Core 從同一個已驗證二進位抽出內建模型目錄，移除 §3 列出的欄位，寫成 `state/agent/codex-catalog-<hash>.json`；抽不出來就拒絕啟動（`backend_catalog_unavailable`）。
3. Core 以 `ditto-confine`（與 `ditto-core` 同目錄）啟動 app-server，stdio 接在一對 socketpair 的一端；另一端在啟動 Agent controller 時以 fd 4 交給它（`DITTO_BACKEND_FD`）。
4. `ditto-confine` 在 Landlock 與 seccomp 都套上、且收到 seccomp listener 後，才在 Core 給它的 status fd 寫一行 `{"confined":true,"pid":…}`。Core 再確認該 PID 的父程序是它剛啟動的 supervisor。
5. `agent.runtime.ready` 不再接受任何欄位。`isolation_verified` 只由 Core 自己的啟動結果決定；controller 的自述一律不採計。未隔離時，Agent 的寫入型桌面工具與 provider 登入能力都不可用（既有 router 規則）。

controller 不選擇二進位、參數、帳號儲存方式或 OS 邊界。後端退出時 Core 讓整個世代 drain；停止時清空後端私有目錄（`home`、`codex`、`work`），帳號只留在 keyring。

## 2. OS 邊界（`ditto-confine`）

參考平台的 AppArmor 禁止非特權 user namespace，bubblewrap 與 Codex 自帶 sandbox 都無法執行；本機 Landlock ABI 為 7。因此邊界不依賴 namespace：

| 機制 | 內容 |
| --- | --- |
| Landlock 檔案 | 只讀：Codex 二進位目錄、`/etc/ssl`、CA、`resolv.conf`、hosts、`/dev/urandom`、衍生模型目錄。可寫：後端私有目錄、`/dev/null`。家目錄、`/proc`、`/usr` 皆不可見 |
| Landlock 網路 | 不允許任何 TCP bind（登入用 device code，沒有回呼埠）；TCP connect 全交給下列代理 |
| Landlock scope | 抽象 Unix socket 與 signal 限於自身程序樹 |
| seccomp socket | 只能建立 IPv4、IPv6 與 **stream** Unix socket；netlink、packet、datagram Unix 一律 `EAFNOSUPPORT` |
| seccomp connect 代理 | 每個 `connect()` 交給 supervisor：以 `pidfd_getfd` 取得同一個 socket 物件、檢查**物件本身**的 family，由 supervisor 自己連到允許的端點；從不回覆 continue，因此改寫位址或替換 fd 的競態到不了別處 |
| 允許端點 | TCP 443（任一主機）、UDP 53、指定的 Unix 路徑（只有下列 proxy）；測試模式另加一個 loopback 埠 |
| 其他 seccomp | io_uring、ptrace、process_vm_*、pidfd_getfd、bpf、perf、userfaultfd、keyctl 類拒絕；x32 與非 x86_64 直接終止 |
| Session bus | `xdg-dbus-proxy --filter --talk=org.freedesktop.secrets`，是後端唯一能連的 Unix 端點 |

`xdg-dbus-proxy` 使用 [tools/dbus-proxy](../../tools/dbus-proxy/pin.json) 自建的 0.1.9（裝在 `ditto-core` 旁為 `ditto-dbus-proxy`）；Ubuntu 24.04 的 0.1.5 在認證後丟棄 sd-bus／zbus 用戶端，Core 拒用 0.1.6 以前的版本。

證據：`cargo test -p ditto-confine`（18 項檔案／socket／埠／signal／family 錯配探測、狀態行、proxy 過濾），以及 §4 的端到端測試。

## 3. 內建工具

0.160.0 對目前的模型族在目錄裡宣告 `tool_mode: code_mode_only` 與 `multi_agent_version`：所有工具被包進 JavaScript `exec` cell，並多出 `collaboration`（spawn_agent 等）命名空間。功能旗標**關不掉**這兩者（以 loopback 模型實際攔截模型請求確認）。Core 的衍生目錄移除 `tool_mode`、`multi_agent_version`、`multi_agent_reasoning_effort`、`apply_patch_tool_type`、`web_search_tool_type`，並把 `experimental_supported_tools` 設為空。再加上 `--strict-config` 與 28 個 `--disable` 旗標、`web_search="disabled"`、`cli_auth_credentials_store="keyring"`（不允許退回檔案）。

測試確認模型只看到 Ditto 的動態工具與 `request_user_input`／`request_user_input_async`；後兩者在 Ditto adapter 一律拒絕。模型硬叫 `exec_command`、`apply_patch`、`web_search` 時，Codex 回 `unsupported call`，沒有任何副作用。

## 4. 測試

| 測試 | 內容 | 證據類別 |
| --- | --- | --- |
| `node tests/g2/codex/run.mjs` | Core（fixture）→ controller → 隔離的 app-server → loopback 腳本模型 → Ditto 工具 → ChangeSet → 回讀 → undo → 停止；22 項檢查，含工具面、內建工具拒絕、canary 只在 Core 對話儲存 | development-host |
| `bash tests/g2/codex/desktop.sh` | headless Wayfire＋真 Shell＋hostd：開聊天、合成鍵盤輸入、Shell 顯示 Core 變更卡、Esc 不取消、undo、Agent 退出 Shell／hostd 存活；9 項 | development headless desktop |
| `node tests/g2/codex/subscription.mjs` | 真實 Codex 訂閱：本人以 device code 在瀏覽器登入、一個真模型 turn、Core 回讀與 undo | development-host-real-subscription |

腳本模型只證明接線與邊界，不證明模型品質或帳號可用性。

## 5. 已知限制（未宣稱完成）

- 刪除對話是 Core 權威紀錄的邏輯遮蔽，不是磁碟抹除。已刪除內容可能仍存在 SQLite 的舊頁／WAL、備份、先前匯出或其他副本；刪除不保證覆寫磁碟，也不自動撤銷已套用的組合。生成來源的刪除同樣沿用 [G3 已知限制第 4 項](../../.agents/notes/gate-reviews/G3-exit.md#4-已知限制與-g4-交接)。
- 允許 TCP 443 到任何主機與 UDP 任意目的地；以 IP 為準，不能限定 OpenAI 網域。
- Secret Service 對同一使用者不分應用：proxy 只限制到 `org.freedesktop.secrets`，無法限定只碰 Codex 自己的 keyring 項目。
- 後端沒有 cgroup 硬限制：設定 `DITTO_LAUNCH_SCOPE_PREFIX` 時它有自己的 `<prefix>-agent-backend` scope，但未設 MemoryMax；D-44 依參考機量測決定，不沿用 D-06b 的 256MiB。
- 僅 x86_64；Landlock ABI < 6 的核心直接拒絕啟動後端。
- Codex 仍會產生 skills 說明等開發者訊息；沒有對應工具，但會佔用模型 context。
