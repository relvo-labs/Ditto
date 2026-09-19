# Ditto 前端原型：研究與互動決策

日期：2026-09-19。互動原型建立時基線：Ditto PRD v0.2.0 與使用者提供的 Soft Jelly 桌面參考。正式架構以 [PRD v0.4.0](../product/Ditto-PRD-v0.4.0.md) 為準；研究紀錄不代表已實作原生核心、Cordis 或 LLM。

## 研究結論

### 1. 組合要有可觀察的結果

Harness 官方架構把能力拆為服務與插件，以 Profile／Bundle 決定組合。對 Ditto 的啟發是讓對話操作同一組桌面契約，而不是另外維護一份聊天專用狀態。這是本案的設計推論，不代表上游已提供 Linux 桌面。

[DeepSeek Harness Architecture](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md)

實作：engine.mjs 提供能力目錄、配置 schema、語意解析、差異與驗證；app.js 的 change／applyPlan／undo 共用同一配置與歷史。手動操作與對話都寫入變更紀錄，模組的必要依賴在同一入口檢查。

### 2. 讓使用者容易理解與修正

Microsoft 的 Human-AI Interaction 研究提出跨初次使用、日常互動、出錯與長期使用的指引；論文報告以 49 名設計從業者及 20 種產品驗證其指引。此原型將「能力邊界明確」「失敗可理解」「使用者能修正」作為設計方向。

[Guidelines for Human-AI Interaction — CHI 2019](https://www.microsoft.com/en-us/research/publication/guidelines-for-human-ai-interaction/)

實作：初次對話列出可試的操作；每項變更顯示前後值；先試看不寫入正式配置；保留才提交；取消回復快照；取消處理不修改桌面；過期計畫需重新提出；未知意圖不假裝理解；故障演練保留原配置。

### 3. 動畫表達真實狀態

Qt Quick 將 State、Transition 與屬性動畫作為明確概念，並支援讓位置變化可被視線追蹤。Ditto 的本機動畫應獨立於模型網路延遲。

[Qt Quick — States, Transitions and Animations](https://doc.qt.io/qt-6/qtquick-statesanimations-topic.html)

實作：呼吸與眨眼是待機；pointer move 驅動視線；點擊做壓縮回彈；正在解析需求才使用思考動作；取消後立即停止。視窗與 Dock 在布局改變時過渡；使用者拖曳時關閉位置過渡，避免追不上指標。減少動畫設定及系統偏好均有效。

### 4. 原生整合需明確區隔

Quickshell 提供 QML 桌面外殼元件與常見系統整合，其 Wayland API 包含 toplevel、layer shell 與鎖定等能力。產品應由原生轉接服務控制真正的視窗。本次為可在瀏覽器直接體驗的前端驗證，未實作原生控制。

[Quickshell About](https://quickshell.org/about/)

[Quickshell Wayland Types](https://quickshell.org/docs/v0.2.0/types/Quickshell.Wayland/)

## 參考形象到實作的對應

| 參考 | 實作 |
| --- | --- |
| 左側檔案與前景筆記 | 浮動、可拖曳、可縮放、可最小化的工作視窗 |
| 大型紫色果凍角色在右側 | 既有生成透明素材＋獨立眼睛、嘴巴與動畫；可被視窗覆蓋 |
| 淡紫半透明材質 | 淡紫背景、白色玻璃、圓角、低對比陰影，文字保持深色 |
| 底部中央 Dock | 可經對話或設定改為左右兩側；手機降級為底部 |
| 原圖角落聊天按鈕 | 直接點角色與角色旁文字，另保留 Dock／快捷鍵作為被遮住時的入口 |
| 新增的可組合能力 | 組合中心、模組中心、變更卡、歷史、模板元件與撤銷 |

## 真實、模擬與未實作邊界

| 類型 | 範圍 |
| --- | --- |
| 真實前端互動 | 配置切換、主題、Dock、模組啟停、依賴驗證、保存、歷史、撤銷、匯入匯出、工作區、視窗、筆記、待辦、計時器 |
| 本機模擬 | 自然語言規則解析、模型思考階段、插件目錄、故障演練、示範檔案與終端 |
| 模板組合 | 待辦、專案摘要、時鐘、每日一句，使用 schema 建立新實例；不是任意程式碼生成 |
| 未接入 | 真實 LLM／Harness／Cordis、Linux 應用、合成器、真實網路／電源服務與系統安全邊界 |

## Qt Quick／Quickshell 移植接點

- 視窗／工作區清單：將 browser window model 換成 desktop.windows/workspaces 的快照與事件。
- State 與 Transition：保留語意狀態，將 CSS transform／transition 對應為 QML 屬性動畫。
- Dock／通知／角色：分開 QML 元件，由 Profile 掛載；角色與聊天資料獨立。
- 對話：將 interpret 的回傳格式替換為 Harness 經 schema 驗證的 ChangeSet；不能把規則解析器包裝為模型。
- 持久化：將 localStorage 換成正式配置／會話服務；preview 不提交的行為保持不變。
- 安裝與生成：保留 preview、驗證及失敗回復互動，背後另接可信套件來源、受控建置與隔離宿主。

## 原型已知限制

此版本沒有 OS／GPU 效能驗證。瀏覽器內的原型模組停用不等同程序卸載；內建樣本檔案不代表使用者本機檔案。可預測意圖有明確範圍，不支援一般聊天推理。視覺試看修改短暫前端狀態，重新整理不保存尚未提交的候選。資料僅保存於目前瀏覽器；可匯出配置，但不跨裝置同步。

## 本次驗收

- 8 項配置與意圖測試通過，含多設定指令、配色保留、未知需求、無變更、依賴與非法匯入。
- 瀏覽器操作驗證：變更卡、試看取消、套用、撤銷、組合保存後重新載入、工作區視窗保留、待辦與進度同步、自訂標題元件、故障回復。
- 在桌面預覽尺寸檢查預設浮動布局與開發平鋪布局；修正三視窗重疊、元件相互遮擋與局部設定重設視窗位置。
- 行動版已實作響應式樣式，但本次未完成真實手機裝置驗收。
