# #190／PR #191 快捷鍵錄製計畫 v0.2

owner 已修正核心需求：**直接按組合鍵並自動辨識**。舊 A／B 文字表單不符合需求，撤回選型 gate；沒有任何視覺選擇已核准。舊紀錄／圖片／失敗留在原 evidence，歷史計畫見 `bca39e6`。本次沿用同一 writer、分支及交易基礎，T3；起點 `bca39e637d7d2fda34b06ed08c08151c2b6daaff`，原 base 不變。

## Design Read 與範圍

研究權威為 task `issue-body-recorder-v0.2.md`、`research/report-v0.2.md`、`pr-body-recorder-v0.2.md`。GNOME／KDE／macOS／PowerToys 的一手研究支持明確錄製態、實際按鍵、可取消、獨立清除與衝突說明；不移植其外觀／任意鍵盤政策。維持 Soft Jelly tokens、動作優先清單、繁中／英文及窄版，收斂成一條流程。

已驗本機 Quickshell 0.3.1 revision `1a4716cde794a59928d9d9fc15f2afc7a95de360` 及 installed ShortcutInhibitor；Qt 6.10.2 QQuickKeyEvent 有 nativeScanCode。固定來源／metadata 不當成 compositor grant 證據。採既有 window-scoped inhibition，不新增輸入服務、dependency 或 Core protocol。

## 順序與 checkpoint

1. 先做 task-owned 真 Wayfire＋同版 Quickshell 探針：已綁 chord 在錄製外執行、active 時被 recorder 收到但 counter 不變；取消／失焦／銷毀後恢復。記錄 build、protocol、focus、事件與計數。檢查 cancelled／refusal，以及保留救援／鎖定與 compositor break_grab。合成鍵盤／stipc 標為 compositor 證據，非實體鍵盤／RustDesk／完整 Ditto save。
2. 探針只用 `ditto-shortcut-probe-190-` 資源；容器 ≤2 CPU／4 GiB／512 pids，runtime network none、drop capabilities、no-new-privileges，software headless。只掛 task 工作／證據及固定工具鏈唯讀；無 host display、Docker socket、credentials、privileged 或 UAT 存取。啟動前保留 >10 GiB host available。
3. 依實測 Qt Wayland nativeScanCode／Linux KEY_* 對應實作 recorder state：requesting／active／provisional modifiers／release／captured／cancelled／unavailable。只有 active 才說正在錄製；不靠 event.text／IME，不把 Qt.Key 字串當實體鍵碼。僅既有 adapter 支援範圍；autorepeat、activation Enter/Space、pure modifier、多主鍵、AltGr／unsupported 有負例。
4. 選動作 → 點按鍵／設定 → focused recorder → 完整 release 後成為草稿 → 顯示新舊值／衝突 → 明確套用。Esc 保留原值；清除另列。失焦、切頁、關窗、銷毀、cancelled、拒絕／斷線釋放且不自動重抓。Core ChangeSet、限時試用、權威回讀及 failed-write draft retention 保持。
5. 若 compositor 安全逃生／reserved 可達性需新 policy，停在明確決策；不能把 QML Timer 稱作 fail-safe。可保留 fail-closed、可在獨立 probe 執行的 coherent preview，真實列出尚缺接受條件。
6. focused regression／native probe result、i18n／相關 lint／package witness，選新 personalization version（1.1.0 舊 private stores 不覆寫）。首個 coherent recorder commit 後寫 `recorder/evidence/checkpoint.json` 及本輪單一報告，立即停止；parent 推送／更新 Draft 後，同一 writer 才繼續 native Core save／完整 gates／獨立 review repair。不回到 A/B gate，不標 Ready、不部署。

本輪所有新證據只存 `recorder/evidence` 或 `work/recorder`。原 evidence/result.json 與原 RED 不覆寫。沒有新持久配置權威；Shell 只持草稿與錄製暫態，所有寫入仍由 Core。

## 本輪 checkpoint 實測（待 parent 備份／review）

- 原生 Quickshell revision 與上列相同；獨立 Ubuntu 26.04 映像的 Wayfire 為 **Wayfire package 0.10.0-1／installed wlroots library 0.19.2**（binary 自報 `0.10.0-unknown ... wlroots-0.19.1`），不是以 research snapshot 冒充安裝 build。headless pixman、network none，cgroup 回讀 CPU `200000 100000`、memory `4294967296`、pids `512`。既有桌面／UAT 未接觸。
- raw inhibitor 與實際 `ShortcutRecorder.qml` 各有可重跑腳本（`tests/g4/shortcuts/native`）。真 stipc 的 Super+Space 在外部產生一次 binding event，active 時 recorder 捕獲且 event 為零，release／cancel／失焦／銷毀後恢復；Ctrl+Alt+K、完整放開、modifier provisional、Esc、斷線、拒絕 grant／不重抓有原生結果。German layout 的實體 KEY_Y 是 scan 29，但 Qt logical key 是 Z；因此 canonical mapping 用已驗 Wayland XKB evdev+8，不用文字。
- 預設 break_grab=`none`，inhibition 也會擋 lock。探針暫設 **Super+Shift+Escape** 後，即使 SIGSTOP 凍結 Quickshell，compositor 仍可解除 inhibition，之後 lock counter 可觸發。這只證明 generic counter／compositor route；**尚未證明完整 Ditto rescue／lock／launcher 與 Core save**。
- 材料決策仍待 owner／parent：是否採既有 reserved **Super+Shift+Escape** 作 compositor `shortcuts-inhibit/break_grab`，並驗證目標 session 與 host 安全狀態接線？正式設定頁 `recordingSafetyConfirmed` 維持 false，顯示 unavailable；不猜測正式 compositor 安全狀態，不以 QML timer 當 fail-safe。此次沒有改正式 policy。
- 發現並重現 pinned inhibitor 在 focus-loss callback 內同步刪除 protocol object 的 reentrant failure。capture 同步停止後，延後釋放 native inhibitor；銷毀前的延遲 callback 也有 null guard。失敗 log 留存，最後原生失焦／銷毀重跑無該 warning／崩潰；不宣稱已對 upstream 做根因堆疊鑑定。
- focused QML：recorder state 21、交易 17、既有 regressions 5、render 3 項皆通過（含 init／cleanup）；24 張離屏交易 workflow 圖。真 compositor 另有繁中／英文及 360px recorder 圖，fixture 標記明確。shell extensions 46 項及五個真 archive 頁載入通過；i18n 712 strings／183 keys／雙語；qmllint 維持 228 warnings，無新增。這些不等同完整 G4／實體座位／Core-save 驗收。
- 舊 1.1.0 private archive／store 保持；新候選 personalization 使用 **1.2.0**，套件及共用 host source 分開記錄。第一個新 commit 是可執行但正式啟用仍 fail-closed 的 recorder checkpoint，parent 備份後才繼續上述決策及 native Core-save／完整 affected gates／獨立 review。
