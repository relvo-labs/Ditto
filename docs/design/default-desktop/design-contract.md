# 視覺、動態與助理契約

狀態：規劃提案。基底 `39da297`；觀察、owner 指定和新提案分開。原圖見 [總規劃](README.md)，既有 NFR 不在本檔改寫。

## 1. 可見構圖與不可推測的部分

下列都是原生附圖的靜態觀察，位置和圓角只有目測近似，不當成精確 token。

| 圖中區域 | 必須保留的可見關係 | 尚無法從圖確定 |
| --- | --- | --- |
| 背景 | 淺薰衣草、右方大型 Ditto、泡泡與反光、左方留給工作視窗 | 乾淨桌布、分層原檔、授權、是否會動 |
| 左上標題／副標 | `01 — SOFT JELLY` 與 `A softer desktop for brighter days`，灰紫字、拉開字距 | 是 mockup caption、桌布字樣或 Profile／主題名稱 widget 尚未知；交 owner 決定，不能硬編或從圖裁切，也不能默默省略 |
| 頂部 | 中央小工作區膠囊，右側 Wi-Fi／音量／電池／時間／搜尋；不鋪厚重實底 bar | 圖中 1～4 不代表只允許四個工作區；時間不能寫死 |
| 左上雙窗 | Files 在後、Notes 在前，近白帶紫的表面、亮邊、淡而寬的柔影 | 真實應用選型、精確字體／半徑、是否首次登入自動開啟 |
| Files／Notes 內容 | 側欄與正文有層次，淡紫選中底，圖示與間距一致 | 示意檔名不是實際檔案；第三方 app 內部不能任意重繪 |
| 底部 Dock | 置中浮動膠囊，七個彩色柔亮圖示，有留白與近白半透明底 | hover 放大、彈跳、running 指示及排序行為皆未在圖中觀察到 |
| 右下入口 | 約 197×54 的小膠囊；左側圓形小 Ditto 頭像，中間 `Need a hand?`／`Ask anything…`，右側 sparkle | owner 已要求右下改助理，故這個小 Ditto 頭像要替換；助理用非 Ditto 頭像或中性符號待確認，不再把原圖小 Ditto 當交付選項。是否直接輸入也未知 |
| 天氣／手寫字樣 | 右側小天氣文字、手寫裝飾 | 是桌布還是 widget；不可硬編即時天氣或假狀態 |

## 2. 原生實作差距

以下引用都對固定基底，而不是 current deployed Profile：

- [`shell/jelly/Tokens.qml`](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/shell/jelly/Tokens.qml#L23-L125)：已有語意色、spacing、motion 與降級 flags，但 fallback 偏深；`defaults.rs` 只改 accent。`soft-jelly` 名稱不等於已還原原圖。
- [`Material.qml`](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/shell/jelly/Material.qml#L16-L35)：矩形底、border、偏移矩形影；blur／shadow token 的存在不證明已渲染柔化效果。
- [`shell.qml` 背景](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/shell/shell.qml#L321-L334)：只有顏色，未接 wallpaper Image；不可在 Shell 偷存第二份正式配置。
- [`DockBottom.qml`](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/shell/providers/dock_bottom/qml/DockBottom.qml#L74-L110) 是 app ID 文字條，另一 [`DockPill.qml`](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/shell/providers/dock_pill/qml/DockPill.qml#L160-L180) 是縮寫圓球，尚非圖中的圖示 Dock。保留供應者可替換契約。
- [`AvatarSettings`](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/crates/ditto-protocol/src/profile.rs#L348-L399) 已有 enabled／hidden／scale／animations／output／corner；沒有自由拖曳座標，位置由 `output` 與 `corner` 兩個欄位共同定義。
- [`ConversationState`](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/shell/chat/ConversationState.qml#L57-L153) 是新助理必須重用的狀態來源，不能另造假進度。

## 3. 材質分層提案

- **桌布**承擔大型果凍立體感；**圖示**用柔亮凸面；**UI 框架**用近白半透明、細亮邊與柔影；正文底較穩定。不是整桌文字都折射。
- 建立 canvas／surface／foreground／muted／accent／focus／status 語意 token 對映；不將 warning／danger／success 全染紫。
- 精確色碼、間距、半徑、字型和動態參數先做取樣／原生對照，再凍結。小字不可為像 JPEG 而犧牲繁中可讀性或 200% 字體縮放。
- 分別驗證「同 QML source 的局部 effect」與「跨 surface 的 compositor backdrop blur」。MultiEffect 不是取得任意應用背後像素的 API。不得用模糊桌布冒充 live backdrop。
- 只有可見、需要的表面啟用 effect，限定取樣面積；收合後停止不必要的 effect／timer／訂閱。輸入命中區不隨模糊邊界擴張。
- reduced transparency 用不透明近白底；低效能／software renderer 用 non-shader 路徑。保留同一內容、焦點與可操作性，不把無 GPU 變成空白輸入框。機制參考見 [benchmark §2](benchmarks.md#2-固定版本的工程參考)。

## 4. 動態編排提案

**靜態圖無法證明動畫。** 以下是要製作原生動態樣本並交 owner 確認的方向；不指定未測過的 FPS 或把任意 spring 參數當 final。

| 情境 | 正常模式 | 中斷與降級 |
| --- | --- | --- |
| 桌面初次呈現 | 桌布先穩定，頂部／Dock／助理短過場，不以開場動畫擋操作 | 不等模型／網路；減少動畫時直接就位 |
| hover／press | 提亮邊緣與局部微小回彈，不重排鄰近 hit target | 離開、取消、失焦就回到合法終態，不累積 queue |
| 助理展開／收合 | 以實際右下錨點局部展開；focus 不等視覺 settle | latest intent wins；收合不取消 turn、不丟 approval |
| Dock／launcher | 真正啟動後才給回饋；選取與 running 可辨識 | 失敗顯示原因，不無限彈跳；鍵盤有等價回饋 |
| 視窗拖曳 | 直接跟手，關閉位置過場；不預設整窗扭曲 | 不逐幀 RPC；無合成器能力則明說 unsupported |
| thinking／executing | 僅在真實活動中做有界低強度進度，不捏造百分比 | cancelling 顯示正在停止，終態停止 working cue |
| 完成／失敗／未知 | 成功可一次短回饋；部分完成與未知各保留文字和操作 | 不把重連或未知演成成功；不用整窗 shake 催促 |

候選時長與 spring／damping 必須經原生樣本核定，尤其反向操作、掉幀、重新定位與 reduced motion；不能從 screenshot 推導一組確定的動畫。

## 5. 右下助理，不另造吉祥物或聊天系統

### 呈現與狀態

- 建議一個有標籤的 button 膠囊。**原圖是左側小 Ditto 頭像、右側 sparkle；owner 明確要求將右下 Ditto 改為助理，這是有需求依據的視覺差異，不是研究漏掉原圖。** 助理可用非 Ditto 小頭像或中性符號，兩者都只是候選，依 owner 決定的符號交付並記入 deviation ledger；不得預設採用中性符號或另造 Ditto 分身。「需要幫忙嗎？」是文案候選，不是確定品牌。右端 sparkle 初始視為裝飾，除非另有明確操作契約。
- 不把入口畫成假輸入框。點擊、Enter／Space 或既有 `Super+A` 才打開真實 editor；待機與通知不得搶焦點。
- compact 與完整視窗沿用同一會話、草稿、串流、pending turn 與完整歷史。面板定位改用入口真實幾何，不再依大型角色固定高度。
- 沿用七態：idle、thinking、executing、awaiting、done、failed、offline；starting 是生命週期提示，cancelling 是 turn 階段，reconnecting 是傳輸提示，不擅自擴充 PRD enum。
- completed／failed／partial／unknown／stopped 顯示 Core 真實結果；未知不得誘導重送有副作用操作。模型離線與 Core 斷線要區分。

### 互動與安全

- approval 仍用既有請求與拒絕預設，Escape 保留拒絕；preview 用原 Core 確認／倒數。助理只提示與導向，不自動核准或自動 commit。
- 收合不停止 turn；停止呼叫既有 cancel 並等真實終態；Undo 僅針對可撤銷的已生效變更。重連先回讀，不能重播副作用。
- **既有缺口**：[`ChatBody.qml:71`](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/shell/chat/ChatBody.qml#L67-L71) 的 Escape 直接觸發 closeRequested；來源中未見明確 preedit／inputMethodComposing guard。這是 R3／#47 要補驗證與修正的輸入法接點，尚未證明實際每種輸入法都會誤觸。[`ApprovalWindow.qml:73`](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/shell/chat/ApprovalWindow.qml#L69-L73) 的 Escape 則是拒絕，不能一併改成收合。
- IME composing 時 Enter／Escape／方向鍵先交輸入法；候選確認不誤送，候選取消不誤收合。沒有 preedit 時 Escape 收合並交還焦點。
- 螢幕／檔案／剪貼簿上下文仍需清楚範圍、授權與撤銷，不能為了助理順手而常駐偷讀。
- 保留快捷鍵／Dock 等無角色入口、AT-SPI／Orca、大字與可見 focus；多屏拔插沿用 output／corner fallback，不能硬編整張桌面的右下座標。

### 權威與舊資料

owner 這次要求會取代 PRD §11.1／AVA-03 與研究文件中「預設獨立 Ditto 角色入口」的對應選擇；R3 必須先補決策紀錄與精確 authority delta，再接實作。**本研究文件本身不悄悄改 PRD，也不把所有 AVA 要求取消。**

新預設助理與舊版可選 avatar 模式要有 Core 管理的呈現契約。先評估已註冊 entry config；不足才提 optional typed field／schema 遷移，不在本規劃假設欄位已存在。建議 absent 保留 legacy，明確選新預設才採新模式；測 digest、匯入匯出、切換、undo、重啟，不能全域改 `AvatarSettings::default()` 讓舊文件默默變意義。`AvatarSettings` 有 `deny_unknown_fields`：若新增 typed field，舊版程式讀新版文件會拒絕，必須明列前向相容限制、版本協商／遷移與降版政策；「新程式讀舊文件」通過不等於「舊程式可讀新文件」。

PRD §11.1 原先還把右側大型 Ditto 定義為可動角色層。R3 的 authority delta 也要交代桌布 Ditto 是靜態或分層動態（目前未知），以及 AVA-01／02／05／07 與 AT-12 哪些由 optional avatar 承接、哪些互動需求映射到助理。不得只換入口便默默刪掉可及性、遮擋與無角色能力。

既有 [`aboveWindows: true`](https://github.com/relvo-labs/Ditto/blob/39da2977fa1a819033b4a68a3cdf350e2b32f808/shell/shell.qml#L563) 與 AVA-05「應用可覆蓋角色」需實機核對；只看一個屬性不足以宣告 bug。由 #46／#56 接遮擋／喚回測試，若證實不符再追修正。
