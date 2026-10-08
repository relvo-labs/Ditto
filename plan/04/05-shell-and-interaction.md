# 05｜對話介面與真實桌面互動

工作包：SHELL-01～06、PLAT-01、QA-06。必讀：`ditto-qml-shell`、`ditto-prose-standard`、`ditto-process-budget`、`ditto-agent-changeset`。依據：[互動研究](../../docs/research/RESEARCH-AND-INTERACTION.md)；網頁原型只供行為參考，不移植規則parser為正式Agent。

## 1. 一份對話模型，兩種表面

新增路徑提案：`shell/chat/ConversationState.qml`、`ChatPanel.qml`、`ChatWindow.qml`、`MessageList.qml`、`ContextChips.qml`、`ApprovalCard.qml`、`shell/settings/AISettings.qml`。整合現有`DittoClient.qml`、`shell/change/ChangeCard.qml`、avatar與i18n元件，不複製交易結果卡。

ConversationState保存選定session、未送草稿、scroll anchor、context refs、Core snapshot／watermark、stream buffer與active task。緊湊／完整視窗讀同一實例，切換只改呈現，不重啟Agent、不重送訊息、不建立第二subscription。草稿留Shell記憶體；只有使用者明確送出後由Core持久受理；若要crash後保存草稿，需另有Core-owned private draft設計，不能偷偷寫本地Profile。

訊息列表分頁，提案初次50筆、每頁50；長會話不全部灌QML記憶體。token每批更新而非每字觸發layout；hidden時停止動畫和非必要畫面工作，重新打開從Core snapshot補齊。已送訊息收到accepted watermark才顯示已保存，網路失敗保留文字與重試選項，重試仍用client_message_id。

快捷鍵與桌面入口在無角色模式存在。點avatar打開身旁panel，keyboard focus進輸入欄；展開視窗保留所有state，Escape收起不取消執行。Avatar透明區仍click-through，聊天surface只有自身可見區攔點擊；多螢幕與縮放時依output workarea放置，不令panel跑出畫面。

## 2. 任務與七態

PRD AVA-04列的是**七態**：待命、思考、執行、待確認、完成、失敗、離線。milestones/01/03的「六態」按PRD更正。狀態由Core／Agent事件導出：

| 角色態 | 真實來源 | 使用者文字 |
| --- | --- | --- |
| 待命 | ready且無active turn | 可以描述想調整的桌面 |
| 思考 | provider請求或規劃確實進行中 | 正在理解需求；可停止 |
| 執行 | Core change/job正在prepare／apply／verify | 按實際階段顯示準備、試用、套用、驗證 |
| 待確認 | Core有仍有效approval或target question | 說明要確認的資料／選項與原因 |
| 完成 | verified result terminal | 哪些項目生效，以及撤銷入口 |
| 失敗 | failed／partial／unknown terminal | 原因、已完成項、未回復項／待查結果 |
| 離線 | provider不可用／Agent停止且需要重連 | 模型尚未連接／連線中斷；桌面仍可操作 |

啟動中是Core lifecycle狀態，顯示「正在啟動對話」，不是假裝模型思考。部分與未知結果不能都寫「沒成功，可以重試」；scheduled明確「已排程，尚未套用」。完成／失敗動畫一次即可，無active任務不得持續旋轉。reduced motion以靜態圖與文字表達所有狀態，動画frame loop不發RPC。

## 3. 對話流程與管理

對話面板提供歷史、上下文可移除標籤、具體澄清選項、實際diff／影響、Core變更卡、job進度、取消、undo、Profile保存／比較／切換入口。輸出確認不另開第二套交易；試用／保留／回復倒數讀既有Corechange狀態。

同一時刻session只有一個active turn；使用者送新訊息可選排隊或停止當前後修正，UI不能宣稱已停止但Core仍受理新副作用。closepanel只收起；取消需要明確stop動作並顯示「正在停止」，直至Coreterminal。accepted變更不因UI／Agent消失中斷。

歷史按session與日期顯示，訊息可連變更卡與revision。刪對話先處理active任務並說「保留已套用桌面」，禁止刪聊天自動undo。Profile匯出與聊天匯出分開入口，私人上下文預設不含。

## 4. AI 設定與首次登入

AI頁面顯示provider、model、endpoint可信範圍、credential連線狀態、context grants、token／request／費用預算、保留與清除、off toggle。更改Core settings CAS，表單衝突提示重讀，不整份覆寫其他頁的修改。key欄位屬秘密建立操作，不以星號假值存回設定；測試連線進度和provider錯誤去敏。費用未有來源時寫「尚無費率資料」，不顯示0。

第一入口是「使用 Codex 訂閱登入」：開官方 auth URL → 顯示登入中／取消 → 收到有效登入結果 → 列出可用模型與 effort → 測試連線。此路徑沒有 API key 欄位；帳號摘要、配額使用率與重設時間可查看，查不到寫「尚無配額資料」，不能承諾無限用量。API 連線另有 provider／endpoint／key 表單。配額耗盡提示等待或切換使用者已設定的連線，切換必須明確操作，不自動引入 API 費用。登出後模型停止接新請求、保留本機對話與手動桌面。

Codex turn 完成訊息只能呈現回答；「桌面已完成」卡仍以 Core verified result 建立。停止按鈕同時對應 backend interrupt 與 Ditto turn／Core operation 取消，兩者結果分清。登入等待算有限活動，不能讓登入頁一直開著就永久保活；設定頁展示 expiry／重試。完整事件映射與界線見 [10](10-codex-app-server.md)。

CON-06／07的正常畫面用產品語言；capability_id、operation_id、schema／closed error、PID與model fingerprint放可展開診斷，不要求使用者理解契約才能授權、取消或撤銷。

首次登入可略過模型設定，手動桌面與現有設定中心照常使用。連線成功且catalog真的available後提供三例：

1. 「把 Dock 移到左邊」：現有dock_pill的位置schema；如果現役bottom provider沒left，組合／替換到已安裝pill，不捏造config。
2. 「幫我做專注工作區，通知安靜一點」：透過workspace／layout與notification policy的真實配置。
3. 「把現在的桌面保存成一個新組合」：現有Profile與ChangeSet／duplicate能力，顯示真實名稱與revision。

例句按capability availability啟用，沒有支持的路徑不能呈現可點成功demo。D-09尚未連線時可顯示例子說明，但動作必須引導設定且不假執行。

## 5. 可保存布局補洞（PLAT-01）

AT-02需要真實左專案／右終端，AT-03需要最近目標變窄，現有LayoutRule只指定workspace不夠。D-40提案擴充LayoutIntent：穩定rule_id、app-id matcher、workspace／output selector、normalized region（x/y/width/height 0..1）或明確split ratio；M0 spike選一種表示，不同時保存兩份相同幾何權威。

M0在參考Wayfire測試「現役floating＋move/resize」與simple-tile比例是否可控制、是否會被tiler覆蓋。最小可落地候選是Core-managed floating region規則：ChangeSet參與者prepare保存當前幾何、resolve視窗與workarea，commit設定策略及region，verify原生幾何；不能把浮動region說成持久tiling tree。若選simple-tile，必須有實際ratio寫入／回讀／回復契約。

單output先完成，但selector與縮放必須定义；不用持久window session ID。當下同app多視窗需明確target選擇／matcher，不默默移動全部。不存在的視窗可以留下rule以後套用，同時結果標scheduled／pending，不宣稱現在左右布局完成；50題驗收的布局題提供真實fixture視窗。禁止未經要求自動讀專案路徑或close app。

Core負責projections與apply-on-window-created，規則event-driven且可撤；Agent退出仍有效。rule對後開視窗、workspace grid、應用重啟與output失去如何重定位均有policy；超出supported形態回unsupported。持久意圖與暫時觀察分離，window手動移動不每frame反覆拉回；建議僅新窗口、顯式apply、配置變更觸發，GUI之後移動保留直到下一次明確套用。

回讀允許窗口邊框／workarea的預宣告容差（提案≤2 logical px）；ratio與DPI換算用同一端規則。rollback恢復saved geometry；視窗已關閉列not_restored，不能假成功。舊Profile layout提供schema migration，匯入缺新字段使用原行為，undo／revert不讓舊binary誤讀新格式。

## 6. 真機驗證

SHELL各包完成時驗證鍵盤Tab、Escape、focus、中文實體鍵盤preedit／commit、貼上、selection、緊湊↔完整20次、model斷線中切surface、角色disable後shortcut、100%／fractional scale與低動畫。原有click mask與應用存活回歸。QA-06在30次真正Agent冷啟動及聊天／launcher各200次暖態首幀測試取QML和呈現證據；Core回讀耗時不能替代首幀可見。
