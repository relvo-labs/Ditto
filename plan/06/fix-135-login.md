# 修復計畫 v0.3 — #135

- Base: `5687d4779eb5eb38205ce6ba749ec1b867c5288e`; M/T2；使用者授權平行修復。
- 先完整讀 skills manifest，再建立可重現症狀的 RED（不是缺 helper 的編譯錯誤）。
- 追蹤狀態來源與實際回傳，最小根因修正；保留安全與 unknown 語意。
- 聚焦測試 GREEN、受影響完整 gates、exact-head 獨立審查；VM 驗證另由 coordinator 串行執行。
- 首個實作 checkpoint commit 後 coordinator push Draft，後續 checkpoint 也 push；不 merge、不修改 live 登入／網路。
- 與 #134 共用翻譯／QML 檔需串行整合，候選不宣稱可直接互相合併。

## 範圍
Trace device-code auth at pinned Codex 0.160.0: account/login/start -> upstream polling -> account/login/completed(account success/error) -> account/read -> model/list/rateLimits -> Core status -> QML loginWatch. Check keyring namespace and child lifecycle without reading credentials; browser success alone is not proof local app-server accepted. Hypotheses include failed token exchange/keyring, status bundling quota/model failures, stopped UI timer on close, stale callbacks and events. Build exact seam regression before patch. Keep success/failure/cancel/expire/reconnect cases and unknown state distinct. Do not silently switch device auth to loopback auth or disable sandbox. Native protocol captures from the pin are preferred; synthetic fixtures must be labeled. Read source from openai/codex rust-v0.160.0 if needed, not floating main. Only report authenticated after authoritative account read; preserve any existing user session.
Allowed focus: packages/agent-runtime/src/codex.ts and runtime.ts + focused tests; QML ConversationState/AISettings/ChatBody and their tests only as necessary. QML/i18n overlap with active #134 must be listed, integration serialized by coordinator.

## Checkpoint4：owner 核准的結果回讀

新增獨立 Rust-first `agent.providers.login_result` 唯讀契約，以 login_id/generation 關聯封閉去敏結果；沿用 provider 管理權限，不改既有 closed status/login schema。Core 僅讀現有 controller，不啟動授權；adapter 只保留一筆短暫 attempt。Shell 同時以正式 account status 確認登入，未知／失敗／取消／過期分開，固定文案不含 native error。完成絕對期限、跨 generation/connection/settings callback 與舊 producer fallback 的行為 RED/GREEN；真實帳號、獨立審查由 coordinator 後續執行。

## #134／#140 main 序列整合

整合釘選 main `3f928983816b9962bea532c43bde15efa299a8c3`。#134 的 `providerRead/runtimeRead/settingsRead` 分別吸收為既有 `providerRequest/runtimeRequest/settingsRequest`；只保留一組 counter，保留 `connectionEpoch/providerEpoch/loginRequest` 各自的連線／取消／attempt 圍欄。保留 #134 `settingsReading`、`invalidateSettings`、`turnRead/sessionRead` 與斷線 `sending=false`；`runtimeGeneration` 統一為最高已見代次，未確認為 -1。

`refreshRuntime(then, failed)` 結合 #134 evidence pending/failure、設定與最高代次圍欄，以及 #137 login 前後驗證；讀取本身不取消自己的 start。外部 operation 的 `invalidateRuntime`、settings、disconnect、已確認 runtime failure／空 backend 統一走 `forgetLogin` 同步 finalizer，取消一次 exact id；舊連線不跨 controller 重播。代次變更保留既有 account readback 資料，但作廢在途回覆；只有 runtime 健康與當前帳號條件同時成立才可用。前置 read 更新 serving generation 可繼續，後置仍必須同代次。

保留 #134 `canLogin`、failure_reason/reason_code 文案、API credential-reference readback；登入入口與 start 前／後驗證都以可用性拒絕不安全的開始。保留 #137 account authority、絕對期限、unknown/舊 catalog fallback 及單一 in-flight polling。契約 main §6 保留，login_result 改 §7；main catalog revision6，故本分支保持7。翻譯保留雙方來源，JSON/QM 由 tooling 重建；#140 SDK budget 只沿 main 版本整合，不更改政策。
