# 修復計畫 v0.1 — #135

- Base: `5687d4779eb5eb38205ce6ba749ec1b867c5288e`; M/T2；使用者授權平行修復。
- 先完整讀 skills manifest，再建立可重現症狀的 RED（不是缺 helper 的編譯錯誤）。
- 追蹤狀態來源與實際回傳，最小根因修正；保留安全與 unknown 語意。
- 聚焦測試 GREEN、受影響完整 gates、exact-head 獨立審查；VM 驗證另由 coordinator 串行執行。
- 首個實作 checkpoint commit 後 coordinator push Draft，後續 checkpoint 也 push；不 merge、不修改 live 登入／網路。
- 與 #134 共用翻譯／QML 檔需串行整合，候選不宣稱可直接互相合併。

## 範圍
Trace device-code auth at pinned Codex 0.160.0: account/login/start -> upstream polling -> account/login/completed(account success/error) -> account/read -> model/list/rateLimits -> Core status -> QML loginWatch. Check keyring namespace and child lifecycle without reading credentials; browser success alone is not proof local app-server accepted. Hypotheses include failed token exchange/keyring, status bundling quota/model failures, stopped UI timer on close, stale callbacks and events. Build exact seam regression before patch. Keep success/failure/cancel/expire/reconnect cases and unknown state distinct. Do not silently switch device auth to loopback auth or disable sandbox. Native protocol captures from the pin are preferred; synthetic fixtures must be labeled. Read source from openai/codex rust-v0.160.0 if needed, not floating main. Only report authenticated after authoritative account read; preserve any existing user session.
Allowed focus: packages/agent-runtime/src/codex.ts and runtime.ts + focused tests; QML ConversationState/AISettings/ChatBody and their tests only as necessary. QML/i18n overlap with active #134 must be listed, integration serialized by coordinator.
