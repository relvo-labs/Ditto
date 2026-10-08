# D-09a｜G2 加入 Codex 個人訂閱與 app-server

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-07 |
| 狀態 | 已決定接入方向；帳號實測、版本、工具限制、資源與驗收細節尚待落地 |
| 決策者 | 使用者／專案 owner Lei-k |

## 結論

G2 必須提供 Codex 個人訂閱登入，透過 `codex app-server` 處理對話。優先完成這條真實垂直流程；保留一般 API provider 的可替換接線。此決策只確定登入與後端方向，不核定特定模型、額度、記憶體放寬或工期。

## 依據

- 使用者要求：「模型要加入可以使用codex 個人訂閱登入使用 app server 處理」。
- [官方 app-server 文件](https://learn.chatgpt.com/docs/app-server)提供帳號、thread／turn 與動態工具介面；[認證文件](https://learn.chatgpt.com/docs/auth)區分訂閱登入與 API key，以及 keyring 儲存。
- 本機唯讀盤點為 `codex-cli 0.160.0`；在 `/tmp` 產生該版 experimental JSON schema，核對登入、工具與取消欄位。沒有啟動登入、讀取既有憑證或執行模型請求，不構成帳號可用性與資源證據。

## 考慮過但沒選的方案

- 只接 API key provider：未包含使用者指定的訂閱入口。
- 把 app-server 當成無工具的單次 LLM HTTP adapter：它具有執行迴圈與工具，因此要另外界定接線、工具權限與恢復。
- 複製現有 CLI 憑證／對話當 Ditto 正式資料：會造成身份耦合與第二份會話權威。採專用登入範圍，Core 持有正式對話，provider 狀態可重建。

## 影響

- 更新 `plan/04` 模型後端、AI 設定、授權、生命週期、量測與驗收；詳細接線見 [10-codex-app-server.md](../../../plan/04/10-codex-app-server.md)。
- Codex 的桌面工具由 Ditto dispatcher／Core 授權與執行，完成以 Core 回讀為準；Codex 內建 shell／檔案／其他工具必須限制，不能旁路桌面配置。
- app-server 是額外後端程序，連同 Agent controller、子程序計入產品 PSS／CPU 與回收。D-44 記錄程序邊界的待評審提案；既有資源門檻不變。
- 工作包新增 AGENT-14、PLAT-04、QA-09，估算增 8 人週提案；D-42 仍待以實測校正，不承諾此估算。
- D-09 其餘模型選擇／帳號額度／API keyring／限額仍待定；D-05 三類上游取用仍須符合原驗收，不能因採 Codex 就將未使用的 Harness 模組寫成移植完成。
