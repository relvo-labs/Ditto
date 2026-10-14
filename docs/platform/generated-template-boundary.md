# 受限生成模板的執行邊界

G3 的生成輸入是 `Description`，不是 QML／JavaScript／原生程式碼。它產生新的插件 id、版本、manifest、描述、資料與配置 schema、依賴鎖及固定模板原始碼封裝。沒有任意 import、程式、命令、檔案路徑或網路端點欄位。兩種模板為待辦摘要與工作區動作；來源與所有限制以 `crates/ditto-protocol/src/generation.rs` 為準。

## 正式路徑與權威

`desktop.plugins.development.*` 的 Definition 是 Rust catalog，Provider 是 Core 的 `generation.rs`，Consumer 是 Agent 動態工具、管理中心與 dittoctl。Rust 匯出的 schema／TS 與契約向量共同驗證 wire；catalog revision 為 6，能力版本 1.0.0。Core 是生成紀錄、修復預算、套件發布與資料的唯一寫入者。

1. `create` 保存不可變來源與候選 hash；`get/list` 回讀。修改需 parent 與遞增版本；schema 欄位變更必須提高資料版本。
2. `validate` 提交 Core 全域工作池，再啟動獨立 systemd service 與固定 Qt runner，依序回報 syntax、contract、load、focus、interaction。前一關失敗，後續標 `not_run`。結果以 `jobs.get` 和 artifact 回讀。
3. `preview` 只接受已通過驗證的候選，開啟有「使用測試資料」標示的真實 Wayland 視窗。預覽不改 Profile；可透過 `jobs.cancel` 關閉，開啟／取消歷程持久保存在 artifact.previews。
4. `publish` 僅接受全部關卡通過、`generated-templates-v1/full` 且封裝完整的候選，發布內容定址唯讀套件。安裝與啟用分開。
5. `activate` 提出一般 ChangeSet，走預檢、prepare、apply、回讀與提交／回復。只有交易結果可判定完成。主 Shell 使用自己的固定模板解譯受限描述，**不載入套件提供的 QML**。一般未信任 QML、Node、原生入口仍被拒絕，沒有因驗證通過而升格為可信。

Agent 的 develop、data 與配置授權分開檢查；帶 resource 的授予由 Core 解析到 plugin id，只涵蓋該插件，無 resource 的授予才是明確全域授予，GUI／Agent 共用 Core 授權。一般 Agent 配置 ChangeSet 不可旁路資料升版；須使用有持久授權 intent 的 development.activate。data_write 另檢查現役 Profile 中的資料所有者與 expected_revision。候選不能自行提供身分、驗證報告或 policy。

生成寫入與啟用在 coordinator 接受時重新檢查鎖定及 grant；排隊前的授權不保證撤銷後仍可寫入。同次一次性 approval 由 Core 內部維持，不新增可由 caller 聲明的參數。Shell 回讀固定模板實際掛載物件的 artifact id；entry id 相同但版本不符、或缺版本證據時，啟用失敗並回復。選用欄位的相容規則見 [協定 0.3 增補](../contracts/agent-0.3.md#5-g3-shell-掛載回讀的相容增補)。

管理中心每次開啟從 Core 讀回產物與工作，透過既有 jobs 事件顯示實際關卡、排隊、取消與清理狀態；同時開啟的預覽可各自取消。正常畫面以文字分辨通過、未通過與未執行，原始診斷保留在展開區。這些都是記憶體投影，不新增持久工作清單或輪詢服務。

固定 native runner 在每個實際關卡開始時回報 phase，結束時量測起訖與耗時。Core 保存於既有 `validation.diagnostics` 的 `stage_timing:` 前綴 JSON：`format_version:1`、`stage`、UTC ISO `started_at／finished_at`、單調時鐘量測的 `elapsed_ms`。未執行的關卡沒有時間紀錄；時間不加入錯誤指紋，也不授予 full 或發布資格。這是相容的診斷資料，不增加 wire 欄位或改動契約版本；與模型回合耗時分開記錄。

## 生產候選政策

宿主在啟動 native runner 前讀回 Landlock ABI（至少 6）、私有 confine status fd、實際 cgroup 與 RuntimeMaxUSec。固定額度：512 MiB、零 swap、1 CPU、64 tasks；驗證 service 15 秒，預覽 service 30 秒，內層預覽 20 秒自動關閉。工作池全產品至多兩項；Core 重啟先確認舊 worker scope 已清空才開放新工作；controller 以 PID／starttime 見證 Core，Core 退出即清理。worker scope 和候選 service 分開列入程序與資源統計，不能只計其中之一。

檔案只開放固定系統／Qt 執行檔與模組、該候選兩個輸入檔、私有暫存目錄；不開放真正 HOME、Core socket、session bus、授權或憑證。額外 seccomp 拒絕非 Unix socket；validate 採 offscreen，preview 僅開放 Core 指定的單一 Wayland socket。Qt 啟動後、載 QML 前以 TSYNC filter 禁止 exec／fork／非執行緒 clone，並在同執行緒實測 exec/fork 被拒。這是特定固定模板政策，不代表任意 QML／Node 已有完整沙箱。

完成後停止整個候選 service，讀 cgroup.procs 確認清空才可報 full。controller 中止時，runner 對照 launcher PID 與 starttime，停止子程序；service deadline 是最後清理界線。舊 ABI、缺 helper、缺 manager／私有 attestation／配額、未清空或不合格報告均不能發布。diagnostic-v1 的超限探針不能取得生產啟用資格。

systemd 控制連線使用登入者 `/run/user/<uid>/bus`；桌面的 session bus 可是另一個測試 bus，兩者不混用。所有啟動執行檔與 Qt metadata 固定在 Core 同目錄，metadata 包含 Qt 6.10.2 前綴與 runner sha256。

## 狀態、版本與資料

產物保留來源需求摘要、parent、變更欄位、封裝、驗證與啟用歷程。失敗不覆寫舊版本；同一需求最多三次修復，同錯兩次或未通過更多連續驗證關卡時提前停止。只改診斷文字不算進展，缺少報告也不算通過關卡；Core 從已保存的父版本報告比較，重新連線不重置。經 Core 綁定的明確新使用者回合可另啟預算。失敗 parent 只允許一個後繼修復，Agent turn 另有持久總預算，不能靠分支重置。取消排隊工作與重啟後中斷工作會對帳候選狀態，沒有自動重播。

資料只接受 bounded object 的 text／integer／boolean／text_list。遷移只可 rename、remove、defaults，不能執行任意腳本。資料升版／快照與 Profile revision 在同一 SQLite 交易；提交失敗全部回滾。回退可依快照或相容政策；不可逆或沒有匹配快照時在預檢拒絕，舊版本不可誤讀較新資料。

來源摘要屬私有紀錄，刪除對話時遮蔽摘要與 turn／model，保留插件本身和因果 id。worker 參數不複製對話來源。這是邏輯遮蔽，不宣稱可抹除已備份或底層媒體的歷史位元。

## 建置與驗證

`bash tools/generation-host/build.sh [debug|release]` 建置固定 C++ Qt runner；使用 Qt 6.10.2 Core／Gui／Qml／Quick／Test。`-fPIC` 避免 Qt metaobject 的 COPY relocation；QtTest 是 native runner 的執行期依賴。session 安裝器會建置 Rust generation-host 與 native runner；不是在執行生成請求時編譯程式。

`tests/g3/README.md` 列出單元、契約、真 Core／Shell、腳本模型、VM 超限與舊 ABI 入口。各輸出保留開發／VM／真模型分類；參考機及真實模型尚未執行時不得宣告 AT-06 或 G3 出口通過。固定模板程式升版會改 hash；舊產物不自動被新程式認定相容，須明確重新驗證與升版。
