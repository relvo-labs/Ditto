# G3 遠端 CI 差異修正

PR #40 的 `9686390` 已推送。lifecycle 通過，G3 job 在 Core 原生整合 37 項與 lint 通過後，於 [不可用隔離負例](https://github.com/relvo-labs/Ditto/actions/runs/38524724843/job/115722266561) 失敗：`report["completion"]` 缺欄位。這是新的實際 CI 結果；先前 checkout 權限問題沒有重現。

原因是 runner checkout 路徑比開發機／VM 長；診斷宿主在建立 `denied.sock` 時超過 Unix socket `sun_path` 限制，進入早期錯誤分支。該分支原先回傳臨時 JSON，省略正式 Report 的 completion 等欄位。只把測試改成 `.get()` 會掩蓋格式與路徑問題，未採用。

修正內容：

- 診斷 listener 使用實際登入者 runtime 下、每次獨立且權限 0700 的短目錄，工作區只保留指向該 socket 的連結。runner 解析為短的實際 socket 路徑，避免網路負例因 ENAMETOOLONG 假通過；結束時移除本次私有目錄。正式候選政策／權限沒有擴張。
- 所有早期錯誤用同一 Report 型別，明列 unavailable、completion=null、cleanup_complete=false、無啟用資格；沒有執行或清理見證就不聲稱有。
- 拒絕 runner 新增真實「artifacts 是檔案」早期錯誤，以及超過 108 字元工作路徑中的 network probe。後者實測 full、exit 0、completion 0 與 cleanup_complete=true，仍無啟用資格；舊 ABI 執行時則要求 partial、不執行候選。
- 管理中心補上重疊 reload 的序號：晚到產物清單不能把新工作的取消入口藏掉。既有逐 job 事件保護仍保留。

本機受影響驗證：ditto-test-host 測試與 clippy 通過（新增 1 個早期報告 shape 測試）；上述真實早期錯誤與長路徑 network 通過；正式管理中心 **7 項 QtTest**、QML lint、569 字串雙語檢查、fmt／diff check 通過。這些增補在 [前一輪完整 VM／真模型](G3-functional-completion-2026-10-14.md) 之後，該輪 14 步／19 項數字不改寫成此增補的重跑結果。原始檔 hash 見 [CI 增補證據](G3-ci-followup-evidence-2026-10-14.json)。

修正更新同一 PR，等待新 commit 的遠端檢查。實體座位授權仍待使用者回覆，不中斷目前登入；G3 出口、D-17 與 owner 裁定維持未完成。
