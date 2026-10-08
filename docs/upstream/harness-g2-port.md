# G2 移植紀錄（Agent 控制器、Codex 後端與其邊界）

| 欄位 | 內容 |
| --- | --- |
| 狀態 | G2 實作中（2026-10-08 工作樹，分支 `codex/g2-agent-foundation`）。取用與發行條款仍待 D-11／G4；本文只記事實 |
| 權威 | 逐檔雜湊以 [packages/agent-runtime/vendor/harness/upstream.json](../../packages/agent-runtime/vendor/harness/upstream.json)、[tools/codex/pin.json](../../tools/codex/pin.json)、[tools/dbus-proxy/pin.json](../../tools/dbus-proxy/pin.json) 為準 |
| 相關 | [plan/04/03](../../plan/04/03-agent-and-upstream-adoption.md)、[plan/04/10](../../plan/04/10-codex-app-server.md)、[codex-backend-boundary](../platform/codex-backend-boundary.md)、[cordis-port](cordis-port.md)、`ditto-upstream-port` |

G2 有三類外來程式碼，取用方式各不相同：Harness 的純值模組（原始碼進入 Ditto 的 bundle）、Codex CLI 的 app-server（Ditto 不打包，Core 驗雜湊後在邊界內啟動）、xdg-dbus-proxy（從釘選 tag 建置的外部程式）。Cordis 沿用 G1 的移植，G2 沒有改動它。

## 1. Harness（`packages/agent-runtime/vendor/harness`）

| 欄位 | 值 |
| --- | --- |
| upstream_repo／commit | deepseek-ai/deepseek-harness `477b4f420553e8a52c2fbccc464d7561b239c443`（`@deepseek-ai/dsh-llm` 0.1.7-rc.2 等） |
| port_kind | 薄轉接：選取的原始檔原樣保留，以模組別名解析；Ditto 修改集為空 |
| 取用的檔案 | `llm/{assembler,message,types,brand}.ts`、`brand/index.ts`、`values/index.ts`、`crypto/index.ts`、`attachment/{types,brand}.ts`（9 檔，各有 sha256） |
| 沒有取用 | `LlmRuntime`、`Agent`、PTC／`run_code`、provider adapters、Session 檔案儲存：模型迴圈由 Codex app-server 或 Ditto 的 direct-model 路徑負責，會話與工具紀錄的權威在 Core |
| host_contract | 一個 Agent 控制器程序（Node，`ditto-agentd.mjs`），由 Core 啟動並交給它一個已驗證的通道；持久狀態全部經 Core RPC |
| trust_level | 受信任的第一方轉接；assembler 只做值處理，不是沙箱 |
| license | MIT；`vendor/harness/LICENSE` 隨 bundle 提供 |

驗證（2026-10-08，開發機）：`scripts/check-upstream.mjs` 9 檔雜湊與紀錄相符；`tests/harness.test.ts` 3／3、`tests/session.test.ts` 2／2、`tests/codex.test.ts` 12／12、`tests/tools.test.ts` 含 `modelSchema`；經 assembler 的端到端 `tests/g2/codex/run.mjs` 40／40（腳本模型，不是模型品質證據）。

## 2. Codex app-server（`tools/codex/pin.json`）

| 欄位 | 值 |
| --- | --- |
| 元件 | Codex CLI standalone 0.160.0，`x86_64-unknown-linux-musl` |
| pin | sha256 `12eb3e81114588aca3b7998f4f19e8997b056aca08e57a7ca7c8a3ec8c652aad`；Core 每次啟動前比對，不符即拒絕（`agent.backend_refused binary_mismatch`） |
| port_kind | 不打包、不修改；以 `app-server` 子命令經 stdio 使用 |
| 啟動參數（Core 決定） | `--strict-config`、停用的功能旗標清單（`agent_backend.rs` 的 `DISABLED_FEATURES`）、`cli_auth_credentials_store="keyring"`、Core 衍生的 `model_catalog_json`（移除 `tool_mode`、`multi_agent_version`、`apply_patch_tool_type`、`web_search_tool_type`，清空 `experimental_supported_tools`） |
| 邊界 | `ditto-confine`：Landlock（ABI ≥6）、seccomp connect 代理、socket family 過濾；session bus 只經 §3 的 proxy 通到 Secret Service |
| license | Apache-2.0（openai/codex）；standalone 版的再散布條件待 D-11／G4 |

發現與處置：

- 目前的模型族在內建目錄中是 `code_mode_only` 與 multi-agent v2，工具被包進 JavaScript `exec` 並出現 `spawn_agent`；功能旗標關不掉。Core 改用衍生目錄後，模型只看到 Ditto 動態工具與 `request_user_input*`（adapter 拒絕）；硬叫 `exec_command`／`apply_patch`／`web_search` 回 `unsupported call`，無副作用（`run.mjs` 檢查）。
- Codex 把無型別的動態工具 schema（`true`、`{}`）改寫成 `{"type":"string"}`、無型別陣列的 items 也補成 string；真實模型因此把物件與清單寫成 JSON 字串。controller 的 `modelSchema` 把它們展開為明確的任意 JSON 值後才交給 Codex；Core 仍以原 schema 驗證。
- 登入用 `account/login/start` 的 `chatgptDeviceCode`：回傳驗證網址與一次性代碼，不開本機回呼埠。
- 參考平台的 AppArmor 禁止非特權 user namespace，bubblewrap 與 Codex 自帶 sandbox 都無法使用，因此邊界由 `ditto-confine` 提供。
- 模型服務失敗時，Codex 自己會重試約 24 秒才結束 turn（HTTP 500、連線中斷皆然）；Ditto 據 `codexErrorInfo` 回報 `provider_unavailable` 或 `rate_limited`。

## 3. xdg-dbus-proxy（`tools/dbus-proxy/pin.json`）

| 欄位 | 值 |
| --- | --- |
| upstream | flatpak/xdg-dbus-proxy 0.1.9，commit `72b40c8f6d9d585cfbdb249690724f740d207087` |
| port_kind | 未修改的外部程式，由 `tools/dbus-proxy/build.sh` 從釘選 tag 建置為 `target/<profile>/ditto-dbus-proxy` |
| 為何不用發行版 | Ubuntu 24.04 的 0.1.5 在認證後斷開 sd-bus／zbus 用戶端（`Invalid message header read`），Codex 的 keyring 存取正是 zbus |
| 用途 | 給受限的 app-server 一個只能與 `org.freedesktop.secrets` 對話的 session bus socket |
| license | LGPL-2.1-or-later；發行時須附原始碼與授權（D-11／G4） |

## 4. 依賴與可重建性

- `packages/agent-runtime` 只依賴 workspace 內的 `@ditto/protocol` 型別與 vendored Harness 原始檔；bundle 由 `pnpm --filter @ditto/agent-runtime build` 產生。
- 乾淨 checkout 可建置：`tools/dev-vm/run-g2.sh` 在還原快照的 VM 中從 rsync 的原始碼建置 Core、Agent、hostd、`ditto-confine`、`ditto-dbus-proxy` 並跑完所有 G2 套件（2026-10-08，HWE 7.0 核心快照 `ditto-g2`，17／17 通過）。
- `packaging/reference-image/install-session.sh` 只有在釘選的 Codex binary 存在時才寫入後端參數；不存在時 Agent 以「後端不可用」誠實拒絕。

## 5. 未完成

- 真實訂閱已於 2026-10-09 以 device code 登入執行（瀏覽器 OAuth 對 originator `ditto` 回 `invalid_client`）：帳號矩陣 10／10（切帳號、配額耗盡無法產生）；語意集固定集 42／50、保留集 41／50，見 [G2 評審](../../.agents/notes/gate-reviews/G2-exit.md) §3.4。
- Codex binary 與 xdg-dbus-proxy 的發行條款、隨附原始碼與授權文字屬 D-11／G4。
