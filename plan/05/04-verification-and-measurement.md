# G3 驗證與量測

本檔為驗證計畫，#28～#33；適用 `ditto-verification-evidence`。開發機即使硬體是參考機，巢狀／離座位的測試仍只算開發證據。

## 1. 驗證矩陣

| 對應 | 注入／操作 | 必須觀察的事實 | 證據環境 |
| --- | --- | --- | --- |
| AT-06／#28 | 兩個未安裝插件各生成→驗證→預覽→啟用→再修改 | 真模型的新 artifact、版本、可見資料／動作、Core 回讀、無人工改產物 | 開發 VM 練跑；參考機＋真實訂閱出口 |
| AT-07／#30 | 無效 QML、逾時、非法 imports | 在正確關卡停止，主 Shell／hostd 同 PID、失敗文字與下一步 | VM 與參考機 |
| AT-18／#29 | 固定模型／工具／會話各實際運行 | 九欄來源、逐檔 hash、四欄沿用對照、運行結果 | CI／VM；出口審查 |
| AT-22／#21 | 相容、可逆、不可逆 schema 升級後回退 | 舊版讀到正確 schema／資料，不能誤讀；不可回退明示 | 整合／VM，參考機確認 |
| AT-26／#18／31 | 忙碌迴圈、超量記憶體、fork、第三工作排隊、取消 | 只有候選 scope 被終止，memory.events／pids.events／cpu.stat、佇列與取消；revision 不變 | VM 與參考機 |
| AT-29／#17／23／32 | 任意 QML／Node／原生入口；full／partial／不可用 | 未信任候選不入 Core／主 Shell；原生一律拒絕；不能偽造 full | 契約＋VM＋參考機 |
| GEN-05／#24 | 每關一個負例 | 後續關卡未執行，真預覽明示測試資料、鍵盤焦點與基本動作 | 固定 Qt runner＋VM／實體座位 |
| GEN-06／#25 | load／health／readback 各失敗 | 原 revision／供應者與資料回讀，候選失敗且診斷保留 | 交易整合＋VM |
| GEN-08／#26 | 永遠修不好、重複同錯、重啟後繼續 | 三輪上限／同錯兩次停止，無第四次工作，持久診斷 | 決定性測試＋VM |

## 2. 隔離不能跳過的負例

越界讀與寫、symlink／hardlink、TCP／UDP／abstract socket、Core socket／session bus、signal 宿主、fork 超量、timeout、OOM；候選 stdout 偽造成功不得改變報告。cgroup 值缺失／無上限、Landlock ABI 不足、confine status 缺失／格式錯誤都不能得到 `full`。scope 清理後確認所有子孫退出，不只檢查父程序；保留 scope 外見證程序與桌面 PID、前後 revision。

忙碌迴圈／fork／OOM 僅在回讀硬限制後執行，無邊界時記 `not_run`，不得退回一般 shell 執行。D-25 的開發 VM 是自動化第一線；測試工具可在開發機跑輕量單元與拒絕路徑，但不能把它算成參考機出口。

## 3. 結果與量測格式

每次記 run ID、git commit／dirty diff hash、證據類別、OS／核心 ABI、工具版本、候選 hash／版本、全部 PID／cgroup、政策與回讀值、逐關結果、超限與清理、診斷檔位置。fixture／腳本模型明示，沒有資料的項目記未執行。任何 `full` 測試的政策名稱與實際能力須一併保存。

資源遵守冷登入→暖機 5 分鐘→採樣 10 分鐘、三次重複，報 PSS 中位數／p95／峰值，分列救援、完整桌面無 Agent、Agent 暖態、活動工作；宿主／proxy／worker 都納入程序清單，不把新增工具移到排除項。Agent 暖態 ≤150 MiB、全桌面無 Agent ≤600 MiB／暖態 ≤750 MiB 維持有效，G2 的 VM 超標警訊繼續追蹤。

真模型需記模型／effort／任務集版本、成本與帳號錯誤；兩類插件都保留原始產物，不以 SDK fixture 代替 AT-06。原生首幀、動畫與鍵盤／中文／雙螢幕證據按既有參考機方法跑，不以離屏 QML lint 冒充互動或效能。

## 4. 開發入口

第一批新增 `tests/g3/run.sh`（純函式／拒絕路徑）及 `tests/g3/host/run.sh`（OS 邊界），VM runner 自建 G3 測試工作階段，不登出目前使用中的桌面。OS prerequisites 不足退出 2 並保存 `not_run`；測試 assertion 失敗退出 1；不得以缺環境的成功 exit code 宣稱測試通過。後續新增真模型與 QML 測試後，再接到同一入口。
