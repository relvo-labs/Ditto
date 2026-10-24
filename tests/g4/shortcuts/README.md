# #190／PR #191 快捷鍵錄製開發證據

owner 已撤回舊 A／B 文字表單選型；目前只有「選用途 → 點按鍵 → 實際按組合 → 放開 → 草稿 → 套用」流程。舊證據與 RED 留存，不是 recorder 證據。

先 source runner 的 env.sh，再執行 `timeout 150 bash tests/g4/shortcuts/run.sh <evidence-dir>`。這組離屏測試不接 VM 或 Core。`ShortcutFixture.qml` 是可控制回覆／回讀的 protocol double；交易測試在 `acceptCaptured` 邊界注入錄製結果，**不證明全域擷取或真實持久化**。沒有 chord TextField 作為主路徑或失敗 fallback。

`tst_recorder.qml` 測暫態 reducer：授權前忽略按鍵、實體 native code 對應、放開全部才捕獲、修飾鍵暫態、autorepeat、開啟按鍵殘留、既有 held modifiers、AltGr／未知鍵／多主鍵拒絕、reserved metadata、取消／失焦／關閉／斷線不重抓。`recorder-stubs` 的 inhibitor 永遠不 grant；不能當 compositor 證據。實際 QML 開窗測試走 unavailable，再關閉，保留鍵盤 focus。

交易回歸涵蓋 create/edit/cancel、衝突／reserved、pending interlock、限時確認／還原、unknown 不重送、readback 失敗／mismatch 保留與對帳、stale snapshot、remove、provider／legacy 共用元件。`staging.json` 記錄 source hash 與離屏轉換。產生 zh-TW/en × 1280/900 viewport × list/edit/conflict/reserved/failure/pending 共 24 張完整設定視窗圖；窄設定視窗為 760 寬。圖片是合成 protocol 資料，失敗／成功圖片均不證明寫入。

`run.sh <evidence-dir> <clean-base-source> baseline` 保留原版三個 behavioral RED，仍產生原版 24 張圖並非零退出；不刪除或跳過失敗。基準控制須用獨立 clean source，不覆蓋現有修改。既有 legacy Section width warnings 原樣保留。

## 真實獨立 Wayfire 探針

`native/run.sh <new-evidence-dir> <task-owned-work-dir> <immutable-image-sha256>` 使用現有固定 Qt／Quickshell 工具鏈及已建好的專用映像。它只掛指定工作、證據及工具鏈，不掛 host display、Docker socket、家目錄或 render node。CPU 2、memory 4 GiB、pids 512、network none、cap-drop ALL、no-new-privileges；host available 必須 >10 GiB。Wayfire 用 headless pixman；每次在容器內建立自己的 Wayland socket，結束清理自己的子程序及容器。

映像來源是 Ubuntu 26.04 `ubuntu@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944`，從已驗簽 Ubuntu archive 安裝 Wayfire、Python、grim、fonts-noto-cjk、mesa software EGL，以及固定 Qt 的 runtime libraries。映像建置不是測試 runner 的隱含動作；實測 image id、完整 dpkg inventory、build logs 與工具鏈版本在 phase evidence。日後不同映像須重新檢查版本，不能視為相同 runtime。Quickshell 預期 revision `1a4716cde794a59928d9d9fc15f2afc7a95de360`；實測 Wayfire 0.10.0，不假稱 research snapshot 就是已安裝來源。

`safety_probe.py` 以 raw inhibitor 做 counter 控制、focus／destroy recovery、German Y/Z 物理鍵語義、拒絕 grant，以及 **SIGSTOP 凍結 Quickshell 後由 compositor break_grab 恢復快捷鍵**。`recorder_probe.py` 使用實際 `ShortcutRecorder.qml`，驗證正常綁定在外部執行、active 時不執行但錄製成功、release 後恢復；另測 modifier provisional／release、Esc、拒絕、斷線、失焦與銷毀。native 圖由 grim 擷取獨立 headless compositor，並標明 fixture；不是 VM／實體鍵盤／RustDesk 驗收。

探針僅設定暫時的 `break_grab=<super> <shift> KEY_ESC`，讀回後才對 recorder 提供 safetyReady。正式設定頁預設 fail closed，**沒有核准或修改正式 compositor policy**。預設 `break_grab=none` 下 inhibition 連 lock binding 都會抑制。此 checkpoint 需要明確的逃脫鍵決策及 host 安全狀態接線，不能以 QML timeout 取代 compositor fail-safe，也不能以 generic counter 證明 Ditto launcher／Core save 整合。剩餘 native Core-save、完整 affected gates 與獨立 review 在 parent 備份此 checkpoint 後由同一 writer 繼續。
