# G3 實體座位驗收與最後功能修正

2026-10-14；實作 `bcc7264a65f8debfadba45a091f54c6b0f4775a1`，PR #40／主追蹤 #34。使用者已明確授權「使用既有登入執行真模型測試」及「安排可中斷的實體測試登入，繼續驗收」。本次已執行實體驗收，**不是 owner 的 G3 出口裁定**。逐 issue 狀態見 [完成盤點](../../../plan/05/07-completion-audit.md)，原始檔與實作 SHA256 見 [證據索引](G3-reference-seat-evidence-2026-10-14.json)。

## 實際環境與恢復

- 凍結參考機 `ditto-ref-ws-rtx4060-01` preflight 通過；Ubuntu 24.04.2、核心 `6.17.0-40-generic`、Landlock ABI 7、Qt 6.10.2、Wayfire、HDMI-A-3 1920×1080。logind 證據為 active／Wayland／seat0，並回讀已連接 DRM；不是巢狀或 headless Wayfire。
- 使用正式 release Core／worker／confine／native runner 及正式 Shell／hostd。OS 政策回讀為 `generated-templates-v1`，512 MiB、0 swap、1 CPU、64 tasks、驗證 15 秒／預覽 30 秒；診斷探針另為 `diagnostic-v1`，永遠沒有啟用資格。
- Core 單一寫入者改用既有私有訂閱測試 store；測試 Profile 由 Core 能力建立／切換／恢復，沒有直接編輯配置資料庫或複製憑證。模型與工具僅處理測試需求、測試桌面與固定模板。
- 每次測試前等待 CI 閒置並暫停 runner；獨立 user service 跨登入存活。結束後移除 runtime Core 覆寫，恢復正常資料目錄／原 GDM 設定／CI runner，以原 Profile ID 與 document SHA256 確認配置未變。最終 `recovery.json` 均為 test=0／restore=0，正常登入為 session 1368。
- 鍵盤輸入來自 Wayfire stipc，原生驗證另用 QTest；不聲稱有人操作實體鍵盤、中文輸入、人工錄影、雙螢幕或效能達標。

## 實體驗收結果

所有路徑相對本 checkout；原始 artifacts 為 gitignored，本次提交索引不會把測試 store 或登入秘密推到 GitHub。

| 出口／工作 | 原始 run | 實際結果 |
| --- | --- | --- |
| AT-06／#28 | `artifacts/g3/reference-20261014-physical-03/real-model.json` | 真實訂閱四回合 **19 項通過**：兩個原先未安裝的插件各建立、隔離五關、真預覽、啟用、對話再修改；要求的欄位及未要求欄位逐項比對，實際面板／服務／工作區按鈕回讀，最後恢復 Profile／設定並撤銷測試授權 |
| AT-22／#21／27 | 同 run `desktop.json`，及 `reference-20261014-final-desktop-01/desktop.json` | **45 項通過**：連續兩次 schema／外觀修改回第一版、快照資料、相容回退保留新值、不可逆回退拒絕、舊版不可讀不相容資料、移除保留資料、兩面板共存及原生應用存活 |
| GEN-05／#24 | 最終 desktop run 的 `visible-preview.*`、`preview-keyboard-cancellation.json`、`preview-cancel-*.png` | HDMI 上有標示測試資料的真原生預覽；Tab／Space 輸入後仍 mapped。兩個管理中心取消按鈕各由 Tab／Enter 操作，Core 回讀各自 job 已取消並完成清理；第三工作排隊／排隊取消亦通過 |
| AT-07／#30 | `artifacts/g3/reference-20261014-final-faults-01/summary.json`、`management.png` | **25 項通過**：真無效 QML、非法 import、忙碌逾時各在 syntax 失敗，其他四關未執行、不可發布。Core／Shell／hostd／Wayfire／foot 的 PID、starttime、cgroup 及 revision 前後不變；管理中心實際顯示失敗與建立修正版的下一步，診斷入口由 Tab 到達 |
| GEN-05 每關負例 | physical-03 下 `native-failures-*/summary.json` | **7 案例通過**：正控制及 syntax／contract／load／focus／interaction／非法 import；各自是真 Qt／cgroup／confine 執行，後續關卡未執行、exec 被拒絕、cgroup 清空，桌面／原生應用同 PID、revision 不變 |
| AT-26／#16／18／31 | physical-03 下 `host-*/summary.json` 與各探針 JSON | **10 項通過**：檔案、網路、signal、程序上限、偽造 stdout、OOM、忙碌、timeout、orphan、取消；先回讀硬限制才執行。保留 memory.events／pids.events／cpu.stat、整組清理及每項前後桌面／原生應用 PID／starttime／cgroup／revision |
| AT-29／#17／23／32 full | 最終 desktop run `summary.json`、`untrusted/` | 真 archive 的 QML／Node／原生 ELF 三格封鎖；Core 有 trust_policy 拒絕，無操作執行、revision 及檔案執行見證不變 |
| AT-29 partial | `artifacts/g3/reference-20261014-final-partial-01/summary.json` | **18 項通過**：私有安裝實際缺 Qt 允許目錄，回報 partial／inspect_only／五關未執行，禁止發布；同組三格未信任入口封鎖，桌面／revision 不變 |
| AT-29 unavailable | `artifacts/g3/reference-20261014-final-unavailable-01/summary.json` | **18 項通過**：私有安裝實際缺 native helper，正式能力回 unavailable 並保留可檢視候選、禁止發布；同組三格未信任入口封鎖，桌面／revision 不變 |

partial／unavailable 不是偽造 ABI 或報告。三態使用不同 run namespace 的真 archive，避免重用既有 idempotency key 而查到先前安裝。固定故障另用專門編譯的 `fault-injection` 宿主，只接受三個靜態 fixture 名稱；正式 release 沒有該讀取器，亦沒有提供任意原始碼的候選入口。

真模型為釘選 Codex app-server 0.160.0、`gpt-6.1-sol`；四回合分別 50.132／59.157／69.180／74.689 秒，工具 11／12／8／8 次。這是整回合耗時，不是模型首字或本機套用延遲。該輪原始 oracle 未直接保存 effort；補充檔只讀取已恢復的私有 Core preferences，記錄 `low`。依 runner 僅修改 enabled／工具上限／timeout 且完成全設定恢復回讀，effort 保持原值；不把補充檔稱為歷史設定快照。runner 現已直接保存有效模型設定供後續重跑。消耗既有訂閱額度，無帳單成本資料，不填零美元或零 token。

## 發現並修正的功能

1. **真正逾時曾被誤報為隔離不足／未執行。** native 的完整報告原本只在正常結束送出，逾時會遺失 exec 證據與關卡。現在先送出已實測 exec／fork 拒絕的 attestation，再持續保存有序關卡。controller 保留通過前綴、目前關卡失敗、後續未執行；缺最終 completion 永遠不能發布。OS 邊界與清理仍須逐項實證，沒有把 partial 改稱 full。實體 timeout 的診斷是 `native_runner_interrupted:timeout`。
2. **驗證失敗的已完成 job 曾顯示「工作已完成」。** 管理中心現依結果分辨失敗與 inspect_only，與候選／逐關文字一致；新增真 Qt 回歸並以實體截圖確認。
3. 實體 runner 保留登入恢復、真 Core 路徑檢查、可見預覽、雙預覽鍵盤取消、故障逐項桌面見證；可重用測試 store 的 plugin ID、套件 ID 與 idempotency key 均加 run namespace。

前述功能由真故障揭露再修正；沒有只改測試期待值或以靜態掃描取代 OS 邊界。

## 失敗歷史與回歸

- physical-01 的前兩個真模型回合成功；第三回合在 2.513 秒、0 工具時收到 `provider_unavailable`，整輪判失敗並恢復。沒有足夠診斷可把它指定為某種外部網路原因。physical-03 的獨立四回合全通過，舊失敗不刪除。
- physical-01 的恢復程序實際成功，但 EXIT trap 的裸 `return` 導致恢復狀態誤記 1；原始記錄保留，另有獨立正常 Profile SHA256 比對。修成明確 `return 0`，後續每輪恢復結果均為 0。
- faults-02 的測試覆寫遭較晚載入的 verification drop-in 蓋掉，沒有執行負例；改用 `zz-` 優先序並強制核對實際 Core exe。faults-03 揭露真正逾時報告缺口；faults-04 的只讀 GUI 觀測錯用 Window 的非視覺根節點，之後修正並重驗。這些均不算通過的負例。
- physical-02 重用舊啟用 idempotency key，正式 Core 正確拒絕另一 target；測試命名空間修正後 physical-03 及最終 desktop 通過。第一次 headless 故障管線與實體登出重疊，其 scope 被登入清理停止；保留失敗，改為實體流程全部完成後獨立重跑，**13 項通過**。
- 最後本機：Rust workspace **258 項**、Node **184 項**（另 2 項既有 skip）、Qt **13 項**（模板 5／管理中心 8），fmt／workspace clippy、型別、Rust schema／TS／模板新鮮度、i18n 569 字串／181 keys／2 語言、上游 9 檔與 vendor guard 通過。skills 0 error／1 個既有主文件長度警訊。正式四個 release 二進位故障入口 guard 通過，專用測試宿主正控制確實被 guard 拒絕。
- 乾淨新實作 `bcc7264` 的完整 G3 VM 回歸 **15 步全通過**，來源 SHA256 `b57f16c0c3ac4158b28924683a05cf332399d161297ff3443b788cd0c000fdd0`，含新增 Core 三種原生故障管線 13 項；VM 故障與實體結果分開保存。先前 `88507b7` 的 12 項 GitHub CI 全綠也保留，不能冒充新提交的 CI。

## 出口與後續

五項出口所需的功能、開發／VM／實體／真模型證據已整理供 owner 逐項評審；AT-18 的九欄／四欄來源與相容性矩陣見 [g3-adoption](../../../docs/upstream/g3-adoption.md)。#15～#33 的實作交付與驗證逐列完成盤點，GitHub issue 關閉與 G3 接受仍由 owner 裁定。

D-17 的兩類模板選型、估算核定及 AT-18 文件審查仍是 owner 決策；不是待補寫的生成程式。D-38／D-46 的人工中文、第二人重建、錄影、雙螢幕、nightly、D-06a、G4 shipping 權利與完整資源／呈現時間量測仍照原追蹤，不以這次功能故障測試取代三次冷登入、5 分鐘暖機、10 分鐘採樣或提高任何門檻。
