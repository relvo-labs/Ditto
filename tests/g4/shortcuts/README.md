# #190 快捷鍵 UX 開發證據

先 source runner 提供的 env.sh，再執行 `timeout 140 bash tests/g4/shortcuts/run.sh <evidence-dir>`。此 runner 不接 VM，不啟動 Core；`ShortcutFixture.qml` 是可控制回覆／讀回的 protocol double。只有真實 QML 的呈現、輸入、focus 及 UI 回讀判斷受測，不能稱為全域鍵擷取或實體座位驗收。

`staging.json` 記錄來源 hash 及 offscreen 的 root:/／layer-shell 轉換。每次產生 zh-TW/en × 1280/900 viewport × list/edit/conflict/reserved/failure/pending，共 24 張完整設定視窗圖片。窄版是 760 寬設定視窗，使用相同 fixture 與 J1 tokens。原版沒有 Edit，baseline 的 edit 圖實際展示現有新增表單；conflict/reserved 圖展示輸入時尚無提示。failure 圖以非同步拒絕重現原輸入遺失；圖片不證明 save。

`run.sh <evidence-dir> <clean-base-source> baseline` 保留三個 behavioral RED，仍產生 24 張原版圖，最後非零 exit；不刪除／跳過失敗測試。候選 A／B 跑同一組回歸及 workflow assertions：create/edit/cancel、精確字串 duplicate/reserved、pending interlock、confirmation/revert、unknown 不重送、readback 失敗／mismatch 保留與重新讀取、stale snapshot、remove、locale／窄版及 provider/legacy 共用元件。

B 的源碼只在 task evidence/prototypes，不是另一套出貨架構；以第三參數 b 標示。原版、A、B 可由同一 runner 重現。選擇候選仍歸 owner；測試成功不代表視覺接受。現有全頁 legacy Section 自身的 width binding warnings 與 StylePicker teardown warnings 原樣記錄，選定前不得將這些開發測試當成全套 G4 通過。
