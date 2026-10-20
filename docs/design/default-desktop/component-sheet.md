# 預設桌面元件表與偏離帳（#65 R1）

| 文件屬性 | 內容 |
| --- | --- |
| 狀態 | **R1 第一個 slice 的對照紀錄與提案，不是忠實還原完成宣告。** 色碼、尺寸與材質參數都待 owner 確認 |
| 基底 | `main@f582426`；分支 `hermes/g4-r1-material` |
| 參考圖 | [`reference/owner-desktop-reference.jpg`](reference/owner-desktop-reference.jpg)，1280×800，SHA-256 `ef4cc303…80d5d12`；owner 提供的需求圖，不是 Ditto 截圖，也不是可散布素材 |
| 證據類別 | 開發機 offscreen（Qt 6.10.2 software renderer）＋qmltestrunner。**不是**參考機、VM 或實體座位證據 |

位置與尺寸一律是「目測近似」：從 1280×800 JPEG 讀出，誤差數個像素，不當 token。色碼取樣是 JPEG 小區塊平均，受壓縮影響，不是設計原值。

## 1. 元件表

| 元件 | 原圖（目測近似） | 對應 QML | 狀態 |
| --- | --- | --- | --- |
| Canvas／桌布 | 全幅。淺薰衣草，左側偏飽和（≈`#ccc8fa`），右側偏亮（≈`#e6e1fb`）；右側大型 Ditto 約 x 690–1215、y 145–570，帶泡泡、反光與水面 | `shell/jelly/Backdrop.qml`（由 `shell.qml` 的背景 PanelWindow 掛載） | 漸層 canvas **已實作**；`soft-jelly-light` 預設桌布為 owner 2026-10-19 指定的 `shell/wallpapers/soft-jelly-default.jpg`（授權待 #51）；Profile 桌布欄位仍待 §5 H2 |
| 左上標題／副標 | x≈25、y≈8–38；`01 — SOFT JELLY`、`A softer desktop for brighter days` | 無 | **待 owner**：是 caption、桌布字樣還是 widget 尚未決定；本 slice 不畫、不裁切 |
| 頂部工作區 | 置中浮動膠囊，x≈570–715、y≈4–32（≈145×28），作用中 `1` 為紫色小膠囊 | `shell/providers/panel_top/qml/PanelTop.qml` | **淺色已實作**：四工作區 capture 為 `(568,4) 144×28`，中心 x=640；與目測寬差約 1 px。作用中 accent 小膠囊，非四個工作區時依清單伸縮，不硬編數目；窄寬先換成兩列（§4 D3、§6.5） |
| 頂部狀態 | 右側 x≈1020–1262：Wi-Fi、音量、電池圖示、日期時間、搜尋 | 同上 | **淺色已實作**：`(1020,4) 242×28`，靠右 18 px；主題 symbolic 網路／音量圖示＋Accessible 文字、依 Ditto 語系含星期的日期時間、原 `statusRegion`。網路圖示依有線／無線／其他裝置類型；不可用加 `!`、未知加 `?`、靜音加 `∕`，缺圖退現行文字並隨內容加寬。tooltip 為獨立 popup surface。完整狀態表見 §6.5。電池／搜尋沒有資料或命令，不畫（D3／D6） |
| 天氣／手寫字 | 右上 x≈1180–1255、y≈52–102；右側手寫字兩處 | 無 | **待 owner**：桌布還是 widget 未定；不做假天氣 |
| 後方視窗（Files） | x≈37、y≈63、643×455；圓角≈14–16；標題列≈36；側欄≈120 寬 | 第三方應用。Ditto 只提供材質樣本 `shell/jelly/Material.qml` 供自有表面使用 | **待 owner**：實際應用與首次登入是否開啟；不重繪第三方 app |
| 前方視窗（Notes） | x≈77、y≈465、535×230 | 同上 | 同上 |
| Dock | 置中浮動膠囊，x≈379–901、y≈717–787（≈522×70），離底≈13；7 個彩色圖示≈44 px，間距≈75 | `shell/providers/dock_pill/qml/DockPill.qml` | 淺色 recipe 下：膠囊、應用圖示、fallback、使用中／執行中標示**已實作**；其他主題維持原樣（§2.2）。預設 Profile 仍綁 `dock_bottom`（§5 H3）；圖示風格待素材 |
| 右下助理 | x≈1065–1260、y≈710–764（≈197×54） | `shell/assistant/`（R3／#67） | **owner 選定 D1／56／E1（2026-10-19）**：預設助理採小 Ditto FAB，展開約195×56；D1素材授權仍未釐清，見D11 |
| 留白 | 右半部留給桌布角色；視窗與 Dock 之間≈20 px；Dock 兩側大面積空白 | `Backdrop` 不放任何內容 | 已保留；無桌布時右側只有漸層（§4 D1） |

原生 capture 的實測幾何（offscreen，`capture.log` 的 `CAPTURE_META`）：淺色頂部視窗 0,0,1280×36，只有三個可見膠囊接收輸入，無全寬底色；legacy 頂部仍為 0,0,1280×34；Dock 膠囊 444,720,392×68（本機裝有 6 個對應應用）；兩個材質樣本由 harness 放在原圖視窗位置，不是產品行為。

## 2. 淺色 token recipe（`soft-jelly-light`）

`shell/jelly/Tokens.qml` 以 theme 名稱選 recipe：`soft-jelly` 與沒有 theme 的 Profile 維持原深色值，舊 Profile 外觀不變；`soft-jelly-light` 是本表的淺色 recipe。原因是 Core 的 `APPEARANCE_TOKENS`（`crates/ditto-protocol/src/profile.rs`）列有每個 token 的預設值，且有測試逐字比對 `Tokens.qml`；改預設值需要 Core 一起改，見 §5 H1。token 名稱與所有呼叫端不變；`appearance.tokens` 覆寫在兩種 recipe 都有效。

| token | 一般 | 降低透明度 | 低效能 | 參考圖取樣（JPEG） |
| --- | --- | --- | --- | --- |
| `background` | `#d3cff9` | 同 | 同 | canvas `#ccc8fa`～`#e9e6fc` |
| `surface` | `#fbfaff` α0.90，再乘 `surface_opacity` 0.94 | `#fbfaff` 不透明 | 同一般（低效能只關特效） | 視窗正文 `#faf9ff` |
| `surface_strong` | `#ece8fb` | `#e6e2f8` | 同一般 | 側欄 `#e9e6f9`、選取列 `#d8d3fc` |
| `foreground` | `#211e35` | 同 | 同 | 標題 `#2b2b43`、正文標題 `#151528` |
| `foreground_muted` | `#57536f` | `#46425e` | 同一般 | `#9695a3`（見 §4 D8） |
| `border` | `#b3abe0` α0.8 | `#7d75ad` 不透明 | 同一般 | 原圖是亮邊，不是暗線 |
| `focus` | `#4c3fb5` | 同 | 同 | 原圖未呈現焦點 |
| `accent` | `#9d8cf0`（預設 Profile 覆寫為 `#b9a4ff`） | 同 | 同 | 作用中工作區 `#9f96e8` |
| `warning`／`danger`／`success` | `#7a4a00`／`#a8231b`／`#17663a` | 同 | 同 | 原圖未呈現；保留各自色相，不染紫（測試要求與 accent 色相差 ≥60°） |
| `scrim`（啟動器網格的全螢幕底） | `#fbfaff` α0.86（近白霧面） | `background` 不透明 | 同一般 | 原圖沒有啟動器 |
| 衍生：`highlight`（內亮邊） | 白 α0.85 | 無 | 白 α0.85 | 視窗頂緣 `#f0efff` |
| 衍生：canvas | 由左往右疊白 α0.42，底部疊白 α0.12 | 同 | 同 | — |
| `blur_radius`／`shadow_radius` | 18／14 | 0／14 | 0／0 | — |
| 衍生：`effectsEnabled` | 是 | 否 | 否 | — |

### 對比（WCAG 2.x，實際計算）

由 `tests/g4/visual/unit/tst_tokens.qml` 計算，完整表在證據 `contrast.txt`。底色是**合成後**的顏色：半透明表面×`surface_opacity` 疊在 canvas 上，`material+shadow` 另把最深的陰影疊在下面。正文門檻 4.5:1，焦點環 3:1。

| 文字 | 材質表面 | 材質＋陰影 | `surface_strong` | 直接在 canvas |
| --- | --- | --- | --- | --- |
| `foreground`（一般／降透明） | 14.73／15.53 | 14.00／15.53 | 13.44／12.75 | 10.80 |
| `foreground_muted`（一般／降透明） | 6.68／9.19 | 6.34／9.19 | 6.09／7.54 | 4.90／6.39 |
| `warning` | 6.83／7.20 | 6.49／7.20 | 6.24／5.91 | 5.01 |
| `danger` | 6.56／6.92 | 6.24／6.92 | 5.99／5.68 | 4.81 |
| `success` | 6.40／6.74 | 6.08／6.74 | 5.84／5.54 | **4.69**（最低值） |
| `focus` 環 | 7.14／7.53 | 6.78／7.53 | 6.52／6.18 | 5.24 |
| `on_accent` 在 accent 上 | 7.44（`#9d8cf0`）；預設 Profile 的 `#b9a4ff` 為 9.82 | | | |

各元件實際畫字的合成底色（`git grep scrim`，以及啟動器、通知、管理中心的全螢幕或疊層底）：

| 合成底色（疊在 canvas 上） | 畫在上面的 | 一般 | 降透明 |
| --- | --- | --- | --- |
| LauncherGrid：`scrim`（字直接畫在上面） | `foreground` 名稱／`foreground_muted` 提示／`focus` 框 | 14.80／6.71／7.17 | 10.80／6.39／5.24 |
| LauncherSearch：`surface` 疊在 `surface_strong` 面板 | `foreground`／`foreground_muted` | 15.31／6.94 | 15.53／9.19 |
| NotificationArea：`surface_strong`×`surface_opacity` 卡片 | `foreground`／`foreground_muted`／`warning` | 13.28／6.02／6.16 | 12.75／7.54／5.91 |
| 管理中心：視窗底色 `background`、`surface` 面板 | 全部文字色 | 見上表 canvas 欄；`surface` 上最低 6.52 | 最低 6.74 |

每格五種文字色與焦點環都在測試裡斷言（≥4.5、焦點 ≥3），完整數值見證據 `contrast.txt`；全部配對的最低值仍是 4.69。舊版深色 `scrim` 讓啟動器網格的提示文字只有 2.16:1（review I6），現改為近白霧面。

低效能模式的值與一般相同，但沒有陰影。限制：對比只對 canvas 計算；上了真實桌布後，半透明表面的實際底色會改變，要用桌布重算。降低透明度模式不受桌布影響。`on_accent` 實際是 `#000000`，見 §5 H5。

### 2.2 舊版呈現不變（review I1）

新外觀只在 `soft-jelly-light` 生效，由 `tokens.lightRecipe` 一個旗標決定。`soft-jelly` 與沒有 theme 的 Profile 必須與 `f582426` 逐像素相同；`tests/g4/visual/unit/tst_legacy.qml` 把 base 版檔案（由 `stage-providers.mjs` 從 git 取出）與現行檔案並排渲染比對。

| 變更 | 分類 | 舊版主題的結果 |
| --- | --- | --- |
| Tokens：淺色值、`scrim`、`shadowColor`、canvas／`highlight` 衍生值 | 只在淺色 | 深色值逐字不變（Core 契約測試也比對） |
| Tokens：`effectsEnabled`、`lightRecipe` | 中性，不是顏色 | 無畫面變化 |
| Material：柔影三路徑、光澤、內亮邊 | 只在淺色 | 原本的偏移矩形陰影＋填色，逐像素相同（三種模式 × raised 真偽） |
| Backdrop／`shell.qml` 背景 | 中性 | 漸層兩端同色、沒有光暈、沒有桌布：與原本純色逐像素相同 |
| Surface.qml | 未改 | — |
| DockPill：52 px 圖示格、厚度 84、浮動膠囊、圖示、底板／長條／圓點、尾段名稱比對 | 只在淺色 | 40 px 字母圓、厚度 60、原本的膠囊與圓點，逐像素相同（底部與左側） |
| PanelTop：中央工作區／右側狀態／左側功能膠囊、symbolic 圖示與文字 fallback、局部互動縮放 | 只在淺色 | 其餘主題保留原 34 px 全寬列與原有子元件；對照本 slice 基底 `b434c93` 的像素相同（無 theme／`soft-jelly`／其他 theme）。測試只將兩個替身時鐘固定為同一取樣時間，避免跨分鐘誤差；capture 仍用當下真實時間 |
| DockPill：輸入區＝可見膠囊（圓角） | 中性修正 | 不改像素；舊版膠囊外的透明邊與圓角外不再攔截點擊 |
| DockPill：無障礙名稱加「（使用中）」 | 中性修正 | 不改像素；使用中原本只靠 accent 顏色表達 |

## 3. 柔光材質（`shell/jelly/Material.qml`）

以下是淺色 recipe 的路徑；其他主題走 `legacy`，即原本的兩個矩形。

- **一般模式＋硬體 renderer（`effect`）**：MultiEffect 只模糊 Material **自己的**陰影形狀（隱藏的 Rectangle），寬而淡、向下偏移。它不取樣表面後方的像素，**不是** compositor backdrop blur；Wayfire 0.11 上沒有可用的背景模糊協定，`blur_radius` 仍只是 token。
- **降低透明度，或 software renderer（`layered`）**：四層半透明圓角矩形疊出柔影，不用 shader。表面不透明，沒有頂部光澤與內亮邊，邊線加深。
- **低效能（`none`）**：不建立 MultiEffect，也不畫陰影，維持既有「無模糊、無陰影」。
- 三條路徑下，Material 都不接收輸入，尺寸不變；上面的內容、點擊與鍵盤焦點也都一樣（`tst_material.qml`）。
- 頂部光澤是一般 Gradient，內亮邊是 1 px 邊線，兩者都不用 shader。
- 目前 Shell 裡沒有任何表面使用 `Material`（管理中心、對話、試看列各自畫 Rectangle）。換用屬共用 UI 一致性工作，見 §5 H7。
- Dock 供應者從套件庫載入，不能 import `shell/jelly`。它用同一組 token 自己畫三層疊影與內亮邊，不建立 shader。
- Dock 的輸入區用 Quickshell 0.3.1 的 `Region { item; radius }`（型別資訊與參考機 lock 同為 revision `1a4716c`）：`item` 是可見的膠囊，`radius` 等於膠囊圓角。圓角外、陰影與透明邊都不攔截點擊（`tst_dock.qml`、`tst_legacy.qml` 以替身的 `contains()` 斷言角落在外、中心在內）。實際 Wayfire 上的命中尚未在座位驗證。

## 4. 偏離帳

每一項都需要 owner 確認後才算定案。

| # | 元件 | 原圖 | 原生（本 slice） | 理由 | 狀態 |
| --- | --- | --- | --- | --- | --- |
| D1 | 桌布 | 插畫桌布：大型 Ditto、泡泡、水面 | owner 2026-10-19 指定的乾淨桌布（1280×800），淺色 recipe 預設顯示 | 散布授權待 #51；原檔 1280×800，更大輸出會放大 | 已接素材，授權待定 |
| D2 | 左上標題、天氣、手寫字 | 有 | 未畫 | 用途未定；不硬編、不做假天氣 | 待 owner |
| D3 | 頂部 | 中央浮動工作區膠囊，右側狀態圖示，沒有整條實底列 | 淺色：中央 `(568,4) 144×28`、右側 `(1020,4) 242×28`；新增左側 `(18,4) 360×28` 保留 Ditto 選單、作用中視窗標題與視窗數／離線文字；其餘透明 | 中央與右側接近原圖目測尺寸；左側功能是原有入口，不刪除。電池／搜尋沒有本 slice 的資料來源或命令，天氣仍依 D2 不做。供應者與預設綁定不變 | 開發證據通過；功能性偏離待 owner 確認，Wayfire 未驗證 |
| D4 | 雙窗 | Files、Notes 實際應用畫面 | harness 放兩塊空白材質樣本並標明「非應用視窗」 | 不做假 app；第三方應用內部外觀不歸 Ditto；應用選擇待 owner | 待 owner |
| D5 | 視窗材質 | 近白、亮邊、寬淡柔影 | capture 走 software 的 `layered` 路徑，陰影有階梯感；正文取樣 `#f2f0fa`，原圖 `#faf9ff` | 本機沒有 GPU renderer，`effect` 路徑**未擷取**（§6） | 部分 |
| D6 | Dock／頂部圖示 | 7 個柔亮彩色自繪 Dock 圖示，頂部 Wi-Fi／音量／電池／搜尋 | Dock 維持已安裝應用主題圖示（6 個）；頂部用 symbolic 主題圖示（本機 Yaru），沒有電池／搜尋 | 不複製原圖素材；圖示主題由系統解析，不新增隨包圖示。harness 記錄路徑與 SHA-256；#51 權利盤點與 H9 實機查找仍待驗證 | 頂部接點完成；原圖圖示風格待素材 |
| D7 | Dock 狀態 | 原圖看不出執行中／使用中 | 使用中：底板＋長條；執行中：圓點；鍵盤焦點：外框 | 提案；三者形狀不同，不只靠顏色 | 待 owner |
| D8 | 次要文字 | `#9695a3` 在 `#faf9ff` 上 = 2.82:1 | `#57536f`（6.68:1） | 原圖的值低於 WCAG AA，可讀性優先 | 刻意偏離 |
| D9 | 圓角 | 視窗≈14–16 | token `radiusLarge` 20、`radiusMedium` 12；樣本用 16 | 沒有「視窗圓角」token | 待凍結 |
| D10 | Canvas 方塊紋 | 平滑 | software renderer 的漸層有淡方塊紋 | renderer 產物，不是 recipe | 硬體 capture 重驗 |
| D11 | 右下 | 小 Ditto 頭像＋文字膠囊 | **owner 選定 D1／56／E1（2026-10-19）**；body.png＋QML臉、35 px符號；56 px收合，E1先展開195×56標籤、再開既有compact；click／Enter／Space，hover／focus僅回饋，Escape收合 | Shell只在assistant呈現選用；legacy avatar與capsule路徑保留。D1授權**未釐清**。符號加深、3× device-scale取樣與高對比外環；open加雙輪廓及Accessible文字。1280×800收合／標籤中心y=754，與預設Dock相同，右距32。compact範例文字限內容欄換行；無新增快捷動作。[重跑說明](../../../tests/g4/visual/README-assistant.md)；前後PNG及量測：`/data/hermes/ditto-runs/g4-impl/fab/evidence/repair1/repair1.md` | 已選定；視覺修正為offscreen開發證據，未代表owner最終視覺接受 |

## 5. 交接需求（#71 原交接，R3 更新 H1／H3）

- **H1 預設主題（#45／Core）**：R3 依 D-48 已把新「預設」文件改為 `soft-jelly-light`；agent 依 #71 交接實作，owner 可反悔，既有已儲存的文件不改寫；日後在既有 store 透過 `desktop.profiles.create {from: default}` 建立的新 Profile 也使用這份預設模板。依 #69 的共用 appearance 契約，新 store 的「開發」「簡報」也共用「預設」完整 appearance（含 `soft-jelly-light` 與 tokens）；三份內建組合中，助理呈現僅「預設」選用，兩份用途組合維持 legacy avatar。以下保留 token 層的後續問題：`APPEARANCE_TOKENS` 每個 token 只有一個預設值，所以個人化中心與 Agent 看到的仍是深色預設。需要決定：要嘛依主題列出預設值，要嘛換掉預設值並同步更新 `appearance_tokens_match_the_shell` 測試。`defaults.rs` 目前把 accent 覆寫為 `#b9a4ff`，在淺色 recipe 下對比仍達標。
- **H2 桌布欄位（Core／#45／#51／#49）**：Profile `appearance` 需要一個由 Core 管理的桌布引用（素材 ID 或 Core 資料區內的資產，加 fit 方式，必要時分輸出），並經 ChangeSet 寫入。Shell 端只接 `Backdrop.wallpaperSource`，不讀環境變數或自訂設定檔。多螢幕的 crop／fit 由 #49 決定。素材與授權由 #51 決定。
- **H3 Dock 綁定（#45）**：R3 依 D-48 已把新「預設」文件改綁已安裝的 `ditto.dock.pill`，缺套件時保留原供應者；agent 依 #71 交接實作，owner 可反悔。釘選清單沿用已註冊供應者設定（不捏造應用）；既有 store 與「簡報」不變。
- **H4 內建套件版本（#50）**：`ditto.dock.pill` 內容改了，但版本仍是 `1.1.0`。G1／G2 測試與語意任務集逐字引用 `1.1.0`。已有 store 的機器在 seed 時會記 `boot.builtin_refused`（同版本不同內容），保留舊內容，只有新 store 會拿到新 Dock。升版與升級路徑屬內建套件升版工作。
- **H5 `on_accent` 既有缺陷**：`Tokens.qml` 的 `onAccent` 屬性名稱以 `on`＋大寫開頭，被 QML 當成訊號處理器名稱，綁定沒有生效。實際值一律是 `#000000`，Profile 的 `on_accent` 覆寫也無效；`main` 上同樣如此。黑字在兩種 accent 上都達 AA。修正需要改名或另設 token，會影響所有呼叫端，本 PR 不動。
- **H6 頂部 slice（本次交付）**：沿用 `ditto.panel.top`，由 `tokens.lightRecipe === true` 選浮動呈現，其他主題不變；不需要新 token、供應者或預設綁定。工作區的滑鼠／Enter／Space／Accessible action 共用既有 capability 判斷；音量靜音／滾輪／右鍵設定、網路設定、選單四中心與電源、標題、時鐘和 `statusRegion` 均保留。輸入區為三個圓角膠囊的 Region 聯集，陰影／透明間隙不攔截；預設高度 28＋上下各 4 px，`exclusiveZone=36`；大字及窄寬度換行時，以最高膠囊＋8 px 更新保留高度（Repair 1，§6.3；分階與兩列上限見 §6.5）。hover／focus 0.96、press 0.90，120 ms OutCubic；命中與焦點框不縮放，reduced-motion／low-power／隱藏立即 settle。`ditto.panel.top` manifest 仍為 `1.1.0`；升版與已有 store 的同版不同內容處理交 #50（同 H4），本次沒有改版本。
- **H7 一致性**：管理中心、對話、試看列、通知、啟動器改用 `Material` 或同一組亮邊與陰影，需要逐一確認焦點與可讀性（#47）。
- **H8 硬體驗證（#52／#53／R4）**：`effect` 路徑的畫面、幀時（NFR-05），以及正常／降低透明度／低效能三種模式的 A/B，都要在實體參考機量測。本機只有 software renderer，未執行。
- **H9 圖示解析**：產品端用 `Quickshell.iconPath(name, true)`。harness 用 `capture/prepare.py` 模擬主題查找；實機選到的檔案可能不同，參考機要重驗。

## 6. 原生對照 capture

`tests/g4/visual/run.sh <證據目錄>` 依序執行：

1. 把 `dock_pill`、`panel_top` 複製到 `.staged/`。只移除 layer-shell 的三行，逐行記在 `staging.json`。
2. 跑 qmltestrunner 單元測試。
3. 讀本機的 desktop entry 與圖示主題。
4. 以 1280×800、scale 1 渲染六張既有桌面圖：normal、reduced-transparency、low-power、dock-states（淺色），以及 legacy-soft-jelly、legacy-no-theme（舊版主題）；另加三張明確標示服務 fixture 的頂部狀態圖：panel-muted-connected、panel-unknown、panel-offline；同目錄的既有控制項／助理場景亦執行。`run.sh` 先準備助理 staging，乾淨 checkout 不依賴另一 runner 的快取。
5. 產出 side-by-side、50/50 疊圖（標出元件框）與逐元件取樣 `comparison.json`。

標明的測試資料：四個工作區（第一個作用中）、釘選清單、dock-states 圖中的兩筆視窗記錄。時鐘是執行當下的真實時間。#65 的六個桌面場景不畫桌布、標題、天氣或助理；#67 的獨立助理場景與限制見下節。PNG 只放證據目錄，不進 git。

Quickshell 在本機無法執行（缺 `libcpptrace`、`libOpenGL`），offscreen 也只有 software renderer。因此 capture 用 `tests/g4/visual/stubs/` 的純 QML 替身代替 Quickshell 型別（PanelWindow 依 layer-shell 規則擺放）。這是開發證據：證明 QML 能建出這個畫面，但**不能**證明 Wayfire 上的實際合成、輸入區、焦點或效能。

## 6.1 D-48

新預設改右下助理的決策紀錄見 [D-48](../../../.agents/notes/decisions/2026-10-17-d48-default-assistant-entry.md)。

## 6.2 頂部列後續 slice（#65 D3／H6）

基底 `b434c93b7b739c053aabe70352aef211e7a4c268`；分支 `hermes/g4-65-topbar`。證據在 repo 外 `/data/hermes/ditto-runs/g4-impl/topbar/evidence/`，`manifest.json` 綁定 source hashes、commit、指令與結果；`visual/comparison.json` 記錄逐膠囊幾何及實際圖示來源，normal／reduced-transparency／low-power 幾何相同。離線 harness 沒有音訊／網路服務，所以 capture 顯示真實「不可用」文字與圖示，連線／靜音等由明確 fixture 的 QtTest 驗證。

`unit/tst_panel.qml` 檢查幾何、Region 聯集與圓角／透明間隙、三種模式／2× 字級、狀態圖示與文字 fallback（含 Image.Error）、滑鼠／Enter／Space capability guard、Tab／Backtab、音量操作、狀態項掛載、選單與縮放生命週期，以及三種 legacy 主題的基底像素（含已掛載狀態項）。`statusRegion` 維持同一個 Row，切主題只移動它的呈現容器，既有狀態項不需宿主重新掛載；切換測試的 RED 見 `red/status-region.log`。RED 在 `red/panel.log`；選單縮放另有真實值 RED（1，預期 0.96）在 `red/menu-scale.log`。完整 gates、環境限制與通過數見證據索引；這些都是 **development**，不證明 Wayfire 真實 input region／work-area／焦點、Orca、IME、NFR 或 owner 忠實視覺接受。

## 6.3 PR #101 Repair 1（F1／F2／F3／F4／F8）

本節保留 Repair 1 當時的實作與量測；F2 的 alpha 恢復政策與對比表已由下節 Repair 2 取代，其他佈局／互動驗證仍適用。

修復基底 `9f5875578f955d4113106cb54d273f669fee88ac`，證據在 `/data/hermes/ditto-runs/g4-impl/topbar/evidence/repair1/`。這是開發機 offscreen/software 證據；原有實機／NFR 限制不變。

- **F1 佈局**：三膠囊保留左右各 18 px、相鄰 12 px 間隙。先縮短並省略左側視窗標題，再放寬右側 242 px 留白；必要時左側只剩選單，選單 tooltip／Accessible description 仍提供完整標題與視窗數／離線文字。工作區位置夾限於兩側膠囊之間，能在螢幕中心放下時仍真正置中。極端組合的單列內容總寬超過畫面，工作區 Grid 及狀態 Grid 換行，所有入口仍可見；沒有裁掉操作或縮小文字。`exclusiveZone` 跟隨最高膠囊＋8 px，避免遮窗。圓角取整且不超過單列半徑，換行後不把底部文字切到透明角落；Region 與可見表面一致。1280、字級 1、四工作區、無外掛狀態項時，原 `(568,4) 144×28`／`(1020,4) 242×28` **不變**。
- **F2 圖示**：改為 18×18、`tokens.foreground`（本 recipe `#211e35`）遮罩，局部 Canvas 僅在來源／尺寸／色彩改變時重畫，不逐幀處理。還原 symbolic SVG 內建 50% 透明度的圖形本體，保留邊緣覆蓋率；software／低效能不用 shader。靜音增加 `∕`，不可用 `!`、未知 `?`，並保留各狀態名稱和 hover／focus tooltip；缺圖繼續退文字。
- **F3／F4**：淺色選單 x=18，legacy 仍 x=8。capability 不可用時工作區 Item disabled，退出 Tab 路徑，立即停止 hover／press 縮放並回 1；啟用後仍為 0.96／0.90、120 ms OutCubic。
- **F8 測試**：`tst_panel.qml` 的 144 組矩陣涵蓋寬 1280／1024／800／640 × 字級 1／1.5／2 × 4／9／10 工作區 × 圖示有／無 × 0／2 狀態項，斷言膠囊與 Region 不重疊、內容不溢出、保留高度及預設幾何。另有 12 組 legacy（無主題／soft-jelly／其他 × 1／2 字級 × 1280／800）：固定同一取樣時鐘，逐像素比較選單開啟、鍵盤焦點、hover，並比對 Tab、34／隱藏 0 exclusive zone、無 mask、status region 位置與 Enter／點擊工作區啟用。

實際 PNG 的 WCAG sRGB 對比（`status-contrast.json`）：

| 場景／圖形 | 實際核心色／鄰近膠囊色 | 對比 |
| --- | --- | --- |
| normal／low-power、不可用圖示 | `#211e35`／`#f7f6fe` | 15.03:1 |
| reduced-transparency、不可用圖示 | `#211e35`／`#fbfaff` | 15.53:1 |
| panel-muted-connected、Yaru 靜音喇叭（原 SVG opacity=.5） | `#211e35`／`#f7f6fe` | 15.03:1 |
| panel-unknown、Yaru 未知網路 | `#211e35`／`#f7f6fe` | 15.03:1 |
| panel-offline、Yaru 未連線細線圖形 | `#29263c`／`#f7f6fe` | 13.62:1 |

量測比較的是實際圖形核心與相鄰平坦膠囊像素；反鋸齒輪廓邊緣不作核心最低值，細線圖形可能只有部分覆蓋。這不是宣稱每一個邊緣像素都 ≥4.5:1。QtTest 另用明確 50% opacity SVG，斷言中心最後畫成不透明 `foreground`；不是只檢查 tint 屬性。

`red/panel.log` 在 9f58755 上得到 42 pass／107 fail，包含重疊／溢出、disabled press=0.90、16 px 圖示與選單 x=8 的真實 RED。normal 新舊／原圖對照、最終 source hashes、HEAD、gates 及全部原始紀錄由 `repair1/manifest.json` 索引。F5 音量鍵盤靜音、F6 有線圖示、F7 時鐘 locale／星期依本輪範圍留 follow-up。`ditto.panel.top` manifest 仍為 `1.1.0`，升版交 #50。

## 6.4 PR #101 Repair 2（N1／N3 a11y）

修復基底 `dce0242bbcd20a428504f75d31ec6a4d1326abef`，證據在 `/data/hermes/ditto-runs/g4-impl/topbar/evidence/repair2/`。本輪只修圖示語意及重複 description；N2 窄版高度、N3 tooltip 位置、N4 置中／2× 銳利度仍為 follow-up。

**N1**：SymbolicIcon 現在以 `alpha / 255` 保留來源透明層次與抗鋸齒，不再把 Yaru 用 50% 聲波表達的音量等級拉滿。中性形狀使用 `tokens.foreground`；紅色主導的錯誤像素映射到既有 `tokens.danger`（本 recipe `#a8231b`），不將錯誤徽章染成深色。18 px 尺寸、圖示查找、fallback、標記、tooltip、命中區與幾何不變；沒有新增 token。

`capture/prepare.py` 另固定查找本機安裝的真實 Yaru SVG 作測試輸入，記錄路徑與 SHA-256；`run.sh` 在 unit import 前準備來源，乾淨 checkout 不依賴 capture 快取。音量 0%／40%／100%／muted 的 18×18 圖示，任兩者須有至少 6 個像素的任一 RGB 通道相差 ≥64/255。RED 的 low／medium 只有 4 個；GREEN 六對為 10、22、71、12、81、93 個。這個門檻排除只有抗鋸齒輪廓微變卻看起來一樣的結果。錯誤徽章另斷言至少 8 個不透明 danger 像素（實際 31 個）；50% opacity fixture 改驗證來源 alpha 的實際合成像素與 ≥3:1 圖形對比，不再要求變成全強度。

最終 PNG 的實測對比（與 §6.3 相同的 WCAG sRGB 方法，核心／標記分開；抗鋸齒邊緣不是最低值宣稱）：

| 部分 | 實際色／鄰近膠囊色 | 對比 |
| --- | --- | --- |
| 不透明喇叭核心（low／medium／high） | `#211e35`／`#f7f6fe` | 15.03:1 |
| 保留 50% 的 muted 圖形 | `#8c8a99`／`#f7f6fe` | 3.15:1 |
| muted 的不透明 `∕` 標記核心 | 實際字形核心像素 | 14.14:1 |
| 網路錯誤徽章 | `#a8231b`／`#f7f6fe` | 6.70:1（降低透明度 6.92:1） |
| 未知網路圖形／`?` 標記 | 50% 圖形與字形分別取樣 | 3.15:1／13.44:1 |
| 保留來源透明度的未連線細線圖形 | `#908d9c`／`#f7f6fe` | 3.02:1 |

不透明核心／標記仍超過 4.5:1；來源半透明形狀保留層次，按圖形門檻 ≥3:1 驗證。測試使用實際像素，沒有用 tint 屬性代替回讀。新增 low／medium／high 的明確服務 fixture capture，原 normal／legacy 場景仍用各次真實時間；1280 預設工作區 `(568,4) 144×28`、右側 `(1020,4) 242×28`、保留高度 36 px 不變。

**N3 a11y**：只將 StatusButton 的 `Accessible.description` 設空，避免重複讀取 name；tooltip 與 name 保留相同的狀態文字。Ditto 選單的補充視窗標題／數量 description 繼續保留。`red/panel.log`、`red/volume-levels.log`、最終 `visual/unit-tests.log`、capture 對照及 source／HEAD／gate 結果由 `repair2/manifest.json` 索引。全部仍為 offscreen development 證據；沒有新增實機或 NFR 宣稱。`ditto.panel.top` manifest 維持 `1.1.0`，升版交 #50。

## 6.5 頂部列 follow-up（#102／#105）

基底 `de8d6176690b472cc0cd101af9bf6d1a6a3b51e8`（#101 合併後）；分支 `hermes/g4-102-105-topbar-followup`。證據在 repo 外 `/data/hermes/ditto-runs/g4-impl/topbar-fu/evidence/`，由 `manifest.json` 綁定 commit、source hashes、指令與結果。全部是開發機 Qt 6.10.2 offscreen software 證據；Wayfire、Orca、實體 2× 螢幕與參考機**未執行**。`ditto.panel.top` manifest 維持 `1.1.0`，升版交 #50。Legacy 呈現（含 `HH:mm` 時鐘）不變，仍以既有逐像素測試對照。

**#102**

- **音量鍵盤靜音**：焦點在音量時，空白鍵切換靜音，Enter（含數字鍵盤）開音量設定（pavucontrol）；Accessible 的 toggle action 對應空白鍵、press action 對應 Enter。可靜音時以 `Accessible.checkable`／`checked` 公開靜音狀態，名稱仍為「音量 靜音」／「音量 N%」；description 維持空白（不重複名稱，N3）。音訊不可用時沒有可靜音的對象：空白鍵照舊開設定，toggle 不動作。滑鼠左鍵靜音、右鍵設定、滾輪調整不變。
- **網路圖示依裝置類型**：以 `Networking.devices` 的 `type` 決定。已連線的裝置優先（有線先於無線），都沒連線時先看無線網卡、再看有線。文字名稱不變；目前主題找不到圖示時沿用原本的文字 fallback，不改用其他類型的圖示。

  | 類型 | 已連線 | 未連線 | 狀態未知（加 `?`） |
  | --- | --- | --- | --- |
  | 有線 | `network-wired-symbolic` | `network-wired-disconnected-symbolic` | `network-wired-acquiring-symbolic` |
  | 無線 | `network-wireless-signal-excellent-symbolic` | `network-wireless-offline-symbolic` | `network-wireless-acquiring-symbolic` |
  | 其他／無裝置 | `network-transmit-receive-symbolic` | `network-offline-symbolic` | `network-idle-symbolic` |

  網路服務不可用時沒有裝置資訊，三種類型都用 `network-error-symbolic`＋`!`。狀態未知不用主題的 `*-no-route-*`：Yaru 與 Adwaita 都在圖形裡畫了 `?`，再加文字標記會出現兩個問號。
- **時鐘**：格式字串走翻譯目錄（`M月d日 ddd HH:mm`；en `ddd MMM d HH:mm`），星期與月份名稱用同一語系的 Qt locale：zh-TW「10月19日 週一 14:05」、en「Mon Oct 19 14:05」，語系即時切換。24 小時制、不顯示秒，沒有新增偏好設定。加寬後的時鐘一樣計入佈局寬度與狀態膠囊 Region；1280、有圖示時兩種語系都維持 `(1020,4) 242×28`。

**#105**

- **C1 窄版分階**：從最少列數開始找放得下的組合；同樣高度時狀態膠囊保留較多欄、工作區用較少列。結果是工作區先換成兩列，狀態膠囊再改兩欄，最後才一欄。換行後的狀態膠囊與內容同寬，不保留 242 px 留白。淺色選單開在 Ditto 膠囊下方 4 px，不再開在最高膠囊下方。1280 預設幾何、選單 y=36 不變。常見情況（寬 ≥800、字級 ≤1.5×，含 9／10 工作區、文字 fallback、0／2 狀態項）的最高膠囊都不超過兩列：審查記錄的最壞例（800、1×、10 工作區、文字 fallback、2 個狀態項）從 114 降到 62 px；800／1.5× 為 66 px，1024／1.5× 為 64 px。640 或 2× 字級等極端組合仍可能超過兩列，但不重疊、不溢出（原 144 組矩陣）。選單打開時會蓋住第二列工作區的一部分，這是暫時性的下拉選單，關閉後恢復。
- **C2 tooltip**：不再用 Qt Controls 的預設 ToolTip（畫在 36 px 面板視窗內，可能被裁切），改為 provider 自己的 `PopupWindow`。它是獨立 surface，主題沿用選單（`surface_strong` 底、`border` 框、`foreground` 字，13.44:1），放在所屬控制項下方 8 px，水平夾在螢幕內，寬度上限 360 px，超過就換行。`mask` 是空 Region，不攔截指標；不搶焦點（`grabFocus=false`）。hover 或鍵盤焦點 600 ms 後出現，離開、失焦或 release 時立即消失，沒有動畫。替身測試證明它的幾何完全在面板視窗之外且文字完整；實際 Quickshell／Wayfire 的 popup 定位**未執行**。
- **C3 置中與標記**：Qt Grid 會為空欄保留間距，所以沒有狀態項時隱藏它的容器，欄數也不超過實際成員數。修正前內容中心偏左 6 px（114.98 vs 121），修正後置中，音量與時鐘間距回到 12 px。所有狀態標記都外移 1 px，並加上與膠囊同色的 1 px 描邊。靜音 `∕` 的不透明核心與喇叭圖形距離從 2 px 增為 3 px，中間至少留 2 px 空白。
- **C3 2× 銳利度**：SymbolicIcon 以裝置像素大小載入 SVG（`loadImage(url, 寬×dpr)`），在裝置像素座標內逐點重新著色。修正前 2× 時讀到的只是左上四分之一、再放大兩倍；1× 也是 16 px 圖放大到 18 px。`run.sh` 會在 `QT_SCALE_FACTOR=2` 下再擷取一次狀態膠囊，`capture/check_hidpi.py` 逐裝置像素把覆蓋率和 Qt 直接點陣化的同一 SVG 比對。修正前 2× 平均誤差 0.47–0.70、1× 為 0.09–0.26；修正後 1×／2× 都在 0.001–0.005，實心像素數一致（例如 2× 有線 316／316）。這是 offscreen 替身縮放，實體 2× 螢幕**未執行**。
- **C4 symbolic 重新著色規則**：中性形狀用 `foreground`，紅色錯誤部分用 `danger`，保留來源 alpha（N1：音量等級的半透明聲波）。新增一條：整個圖形都沒有不透明部分（來源最高 alpha <0.75，例如 Yaru 整個 50% 的離線 Wi‑Fi、靜音、`network-idle`，Adwaita 的 0.35）時，依比例拉到最高 alpha 為 1，讓細線也清楚。有不透明部分的圖示（音量等級、錯誤徽章、有線未連線的 `×`）不受影響。

**完整狀態表**（真實 Yaru SVG，1× offscreen，`unit/tst_panel.qml` `test_status_state_table`，原始資料 `status-states.jsonl`）。像素數取整個 28 px 按鈕（圖示＋標記），對比為相對膠囊底色的 WCAG 值；墨水像素是對比 >1.1 的像素。測試要求每個狀態至少 24 個像素 ≥3:1，且至少 8 個像素 ≥4.5:1，代表有不透明部分或標記承載狀態。

| 狀態 | 圖示 | 標記 | 名稱 | 來源最高 alpha | 拉高 | 墨水 | ≥3:1 | ≥4.5:1 | 中位數 | 最高 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 音量不可用 | `audio-card-symbolic` | `!` | 音量不可用 | 1 | 否 | 165 | 86 | 76 | 3.80 | 15.63 |
| 音量 0% | `audio-volume-low-symbolic` | — | 音量 0% | 1 | 否 | 124 | 67 | 66 | 8.99 | 15.63 |
| 音量低（<1/3） | `audio-volume-low-symbolic` | — | 音量 20% | 1 | 否 | 124 | 67 | 66 | 8.99 | 15.63 |
| 音量中（<2/3） | `audio-volume-medium-symbolic` | — | 音量 50% | 1 | 否 | 124 | 76 | 72 | 10.33 | 15.63 |
| 音量高 | `audio-volume-high-symbolic` | — | 音量 100% | 1 | 否 | 125 | 89 | 83 | 11.30 | 15.63 |
| 靜音 | `audio-volume-muted-symbolic` | `∕` | 音量 靜音 | 0.50 | 是 | 175 | 119 | 109 | 6.79 | 15.63 |
| 網路不可用 | `network-error-symbolic` | `!` | 網路不可用 | 1 | 否 | 159 | 72 | 45 | 2.71 | 15.63 |
| 有線已連線 | `network-wired-symbolic` | — | 網路已連線 | 1 | 否 | 126 | 98 | 90 | 10.62 | 15.63 |
| 有線未連線 | `network-wired-disconnected-symbolic` | — | 網路未連線 | 0.97 | 否 | 115 | 28 | 11 | 1.96 | 14.35 |
| 有線狀態未知 | `network-wired-acquiring-symbolic` | `?` | 網路狀態未知 | 1 | 否 | 153 | 45 | 40 | 2.17 | 15.63 |
| 無線已連線 | `network-wireless-signal-excellent-symbolic` | — | 網路已連線 | 1 | 否 | 154 | 134 | 126 | 15.63 | 15.63 |
| 無線未連線 | `network-wireless-offline-symbolic` | — | 網路未連線 | 0.50 | 是 | 86 | 51 | 39 | 3.66 | 15.63 |
| 無線狀態未知 | `network-wireless-acquiring-symbolic` | `?` | 網路狀態未知 | 1 | 否 | 129 | 44 | 40 | 2.15 | 15.63 |
| 其他已連線 | `network-transmit-receive-symbolic` | — | 網路已連線 | 1 | 否 | 94 | 56 | 44 | 3.80 | 15.63 |
| 其他未連線 | `network-offline-symbolic` | — | 網路未連線 | 0.50 | 是 | 119 | 75 | 59 | 4.48 | 15.63 |
| 其他狀態未知 | `network-idle-symbolic` | `?` | 網路狀態未知 | 0.50 | 是 | 117 | 73 | 61 | 4.62 | 15.63 |

O1 的無線未連線在修正前（同一測試，`red/panel.log`）只有 8 個像素 ≥3:1、0 個 ≥4.5:1，最高 3.04；修正後為 51／39，最高 15.63。中位數低於 3:1 的列（網路不可用、有線未連線／未知、無線未知）都是主題刻意畫成 50% 的次要部分，搭配不透明的徽章、`×`、進度點或文字標記，狀態不是只靠淡化的部分表達。0% 與低音量共用圖示，以名稱區分。低／中的界線從「只有 0% 算低、<0.67 算中」改為 1/3、2/3，讓低音量真的用低音量圖示。表中數字是 Yaru 的結果；Adwaita 等其他主題只套用同一規則，沒有逐一量測。

`red/panel.log`、`red/hidpi/` 保存修正前的失敗輸出；review 場景（窄版、選單、tooltip）由 `capture/tst_panel_scenes.qml` 產生 `panel-scene-*.png`，中間的虛線是 harness 標出的面板視窗底邊，不是產品內容。

## 7. R3 助理呈現與開發證據（#67）

Core 的 `avatar.presentation = "assistant"` 明確選擇新入口；absent／null 仍是 legacy，與 theme、hidden、enabled 分開。Schema、Rust／TS 與契約向量一起生成；輸出角落、顯示器消失 fallback、隱藏與停用沿用原 Core 投影。`AssistantSymbol.qml` 是可替換候選接點，未形成新角色品牌。

入口為可見膠囊命中區，文字「助理」和真實任務狀態並列，無假 editor、無獨立 sparkle 按鈕。點擊、Enter／Space 或 Super+A 開同一 ConversationState。compact 的位置來自實際入口矩形（output-local），完整視窗與收合保留草稿、串流、歷史與待決 turn。收合只移除表面；停止、撤銷、approval、preview 沿用既有路徑。登入前或設定尚未回讀時入口顯示中性「待命中」，只有 client 明確斷線才顯示桌面服務未連線；終態與已知離線／停用原因並列。若使用者已切換到其他應用，收合不會把焦點拉回原應用，延後回焦前會再次檢查。Escape composing guard 在 ChatBody／ChatInput；非 composing 才收合，Shell 保存先前應用並透過既有 focus 能力回焦。實際 Wayfire 回焦與輸入法尚未執行。

Legacy avatar 掛載區塊、Avatar.qml 與 ApprovalWindow.qml 對照 `25c0b72` 逐字相同；legacy compact 四角像素及幾何相同。共用 IME guard、重連回讀與保留已知 partial／unknown／stopped 結果的修正適用兩種呈現；這些修正不改已保存的 Profile。助理縮放後的命中區使用表面的實際尺寸，圓角外不攔截。

| Slice | 改動／oracle | 開發證據 | 限制 |
| --- | --- | --- | --- |
| S1 狀態／同一對話 | `shell/assistant/`、`shell/chat/`、shell 掛載；Core turn／工具事件推導狀態，不重播工具 | `tst_assistant.qml` 27 項；`assistant/tst_assistant_flow.qml` 12 項；12 張 normal／legacy 場景 | fixture，不是真實 Core／模型端到端；IPC 在 sandbox BLOCKED |
| S2 相容 | protocol optional 欄位、defaults、docops、projection、builtin_profiles；absent digest、全部既有 avatar 欄位、匯出匯入、undo／切換儲存操作、關閉 Store 後 Core 開機回讀 | protocol 29／store 51；Core 新增 assistant 4 項通過；舊 schema 拒絕新版、明確降版後接受；33 個 TS shape vectors | 完整參與者切換／undo 的 IPC gate BLOCKED；無自動降版 |
| A1 鍵盤／IME | 真實 Enter／Space／Escape、composing policy、approval Escape 拒絕；四角定位、縮放與隱藏 | QtTest、legacy 逐像素／結構比對 | 未注入真正 QInputMethodEvent；實體 IME、回焦、Orca、大字、多屏熱插拔未執行，交 #47／#49 |

執行入口與完整 gate 限制見 `tests/g4/visual/README-assistant.md`。證據目錄為 `/data/hermes/ditto-runs/g4-impl/r3-assistant/evidence/`。沒有 Quickshell／Wayfire／實體座位；PNG 是 Qt 6.10.2 offscreen software 與 layer-shell／FloatingWindow 替身的 **development** 證據。沒有乾淨桌布素材，不宣稱忠實還原或 G4／NFR 通過。

## 8. #116 Soft Jelly 應用風格（已定案：三種可選、預設 J1）

**狀態：已定案。** owner 2026-10-20：「三種風格都要有，讓我可以選，預設用果凍玻璃」。J1 果凍玻璃、J2 軟糖、J3 泡泡都是正式、可由使用者在個人化中心選擇的外觀，**預設 J1**；先前的淺色外觀不再是選項。同日稍早的指示仍有效：主題是 soft jelly、要原創，macOS 只當品質標準，不複製紅黃綠視窗鈕、系統藍、SF Symbols 或系統設定版面。分支 `hermes/g4-116-apps-macos`（基底 `87a2462`，PR #115）。證據在 repo 外 `/data/hermes/ditto-runs/g4-impl/b10/l116/evidence3/`，是 Qt 6.10.2 offscreen software＋Quickshell 替身的開發證據；VM 實機截圖由 coordinator 另行執行。正式的 D 編號決策紀錄（`.agents/notes/decisions/`、`milestones/01/05`）尚未建立。

### 8.1 設定方式與範圍

- **持久化**：Profile 的外觀 token `appearance.tokens.ui_style`（`crates/ditto-protocol/src/profile.rs` 的 `APPEARANCE_TOKENS`，Text，`choices` 為 `j1`／`j2`／`j3`，預設 `j1`）。和其他 token 一樣經 ChangeSet 寫入（個人化中心 `desktop.appearance.set`、`dittoctl appearance set token.ui_style=j2`），有預檢、回讀、歷史與撤銷；預檢拒絕其他值（`token_not_a_choice`）。`desktop.appearance.get` 的 `tokens_available` 列出它與 `choices`。沒有值＝J1，所以既有 Profile 不改寫，Core 的預設 Profile 不變。
- **Shell**：`Tokens.uiStyle` 在淺色主題（`soft-jelly-light`）時取 Profile 值（無值或非法值＝J1）；`soft-jelly`（深色）與沒有主題的 Profile 一律是原外觀，與基底逐像素相同（`tests/g4/visual/unit/tst_ui_style_off.qml`：深色、深色且設了 `ui_style`、深色降低透明度／低效能、無主題，共用控制項、五個中心頁、對話完整／compact、確認視窗、Dock）。變更提交後 Core 推送新的外觀，已開的視窗立即換樣式，不必登出。開發開關 `DITTO_UI_STYLE` 已移除：Profile 是唯一來源，沒有可以蓋過使用者選擇的覆寫。
- **個人化中心**：「外觀」最上方的「外觀風格」（`StylePicker`），只在淺色主題顯示（其他主題選了也不會有變化）；下方說明套用範圍，並說明其他應用的標題列與終端機目前維持果凍玻璃。
- **範圍**：Shell 自有的組合中心、插件中心、變更紀錄、個人化、AI 設定、對話（完整視窗與 compact）、確認視窗、`dock_pill` 的備援圖示與指示。資訊架構、Core 呼叫、確認的預設拒絕與 Escape＝拒絕都不變。`shell/change/`（變更卡、試看列）、頂部列、啟動器、通知、助理 FAB 不在本輪。
- **強調色**：個人化中心的強調色 token 仍作用於頂部列等原元件；三種風格的自有視窗使用各自固定的薰衣草色（沒有隨強調色換色），是已知限制。

### 8.2 三種風格（同結構，只變材質與性格）

| | J1 果凍玻璃 | J2 軟糖 | J3 泡泡 |
| --- | --- | --- | --- |
| 視窗底 | 近白薰衣草，α0.95 磨砂 | 偏粉暖的薰衣草，幾乎不透明 | 冷白帶水色漸層，α0.94；角落淡泡泡 |
| 卡片 | 白 α0.74、亮內緣、淡柔影，圓角 16 | 不透明、底部實心「軟糖唇」＋柔影，圓角 20 | 白 α0.60、四邊虹彩細邊（粉→紫→水藍），圓角 26，留白多（內距 24、列高 56） |
| 選取 | 白色凸珠＋實心小珠標記 | 淡紫軟糖填色＋唇＋實心標記 | 半透明泡泡＋虹彩邊＋空心泡泡環標記 |
| 按鈕 | 圓角矩形（10） | 膠囊、主要動作有深紫唇，按下壓扁最多（x1.03／y0.90） | 膠囊、tonal 帶虹彩邊 |
| 視窗鈕 | 三顆不同深淺的薰衣草果凍珠 | 同左，較飽和 | 中空泡泡、`#7f74c9` 外環（≥3:1）；hover／focus 才填色 |
| 頁標題 | 24 | 26 | 24 |

共通：頁標題 24–26 semibold、群組標題 13 semibold、列標籤 14、說明 12；8 pt 間距；列高 ≥48；卡片內距 ≥16。選取（凸珠＋標記）與主要動作（實心紫＋白字）不同樣式；唯一選項是靜態值＋「唯一可用」小籤，停用是灰字；不用 ✓。危險動作有獨立樣式且在 `⋯` 選單中以分隔線隔開。按下時只壓扁外觀，命中區不縮放；減少動畫／低效能不壓扁，改為按下色。降低透明度：全部不透明、邊線加深、無光澤；低效能：無陰影與光澤。語意色（成功／警告／危險／資訊）是柔和底＋可讀深色字，不染成紫色。

文字對比：`tst_ui_style.qml` 檢查不透明配對（≥4.5，焦點與停用 ≥3）；`capture/ui_contrast.py` 把各風格的半透明層疊在**桌布每個像素與黑色**上計算最小值（`ui-contrast.json`）。J3 在 VM 上對比最弱，第二階段加深灰字（`#48456a`）與停用字（`#6c6788`，≥4.5）、側欄改為淡水色底＋邊線、卡片邊與選取珠邊加深（`tst_ui_style_layout.qml`）。

### 8.3 元件與頁面

| 元件（`shell/ui/`） | 用途 | 鍵盤／無障礙 |
| --- | --- | --- |
| `JellySurface` | 果凍面：填色、亮內緣、頂部光澤、J2 唇、J3 虹彩邊與泡泡、柔影；無 shader | 不接收輸入 |
| `SegmentedControl` | 互斥選項；`Choice` 在候選下改用它 | 一個 Tab 停點，方向鍵／Home／End 移動，Enter／Space 選；移動焦點不等於選擇；RadioButton＋checked |
| `GroupedList`／`ListRow` | 成組設定列，水面般的分隔線，放不下時控制項換到下一行 | Grouping＋列名 |
| `OverflowMenu` | 卡片的 `⋯`，最多兩個主要動作以外的動作 | Enter／Space／↓ 開啟，↑↓ 循環並略過不可用項，Escape／Tab 關閉並回到按鈕；Escape 不會再關掉外層視窗；不可用項說明原因 |
| `WindowControls`／`WindowHeader` | 自有視窗的單一標題列與三顆果凍珠；拖曳移動、雙擊放大 | 每顆都是有文字名稱的 Button，Tab／Enter／Space，命中區 28 px |
| `EmptyState` | 單一空狀態：角色、標題、說明、主要動作、範例；不會畫出自己的框；矮於 470 px 時改用精簡版（44 px 角色、泡泡貼近角色、兩則範例、說明可占兩行），仍放不下（放大文字）就在框內捲動 | 範例是靜態引述，不是按鈕，但每則是可讀出的 Tab 停點；焦點移入會捲到可見（`FocusReveal.js`，與中心頁共用），PageUp／PageDown 翻頁 |
| `StylePicker` | 個人化中心的「外觀風格」：三張卡片，各有該風格自己的 Tokens 畫的即時小預覽、名稱與一句說明 | 一個 Tab 停點，方向鍵／Home／End 移動焦點但不選，Enter／Space／點擊才選；RadioButton＋名稱＋描述；預覽跟著降低透明度／低效能 |

既有 `Button`（primary／secondary＝tonal／subtle＝ghost／danger／`dangerQuiet`，另加 `checked`、`jellyPad`）、`Badge`、`Section`、`Toggle`、`TextField`、`TextArea`、`Diagnostics`、`ChatInput` 只在有風格時換外觀（`SegmentedControl` 另有 `segmentPad`）。頁面：組合中心的元件列改成成組清單；每張組合卡最多「試看」「使用這個組合」，其餘（版本與差異、比較、複製、重新命名、匯出、刪除）在固定位置的 `⋯`；使用中的卡刪除項停用並說明；版本的起點／終點以已選凸珠表示。側欄不再重複「Ditto」，選中頁是泡泡。視窗高度在已知螢幕高度時留出 `uiWindowClearance`（228 px），讓 Wayfire 置中（工作區或輸出）時標題列在頂部列與待辦面板之下、底部在 Dock 之上；頁面有捲動條，Tab 到畫面外的控制項會捲進來，PageUp／PageDown 翻頁。對話：完整視窗只有一個標題；「對話／歷史」是分頁，「新對話／AI 設定／收合」是工具鈕（一行放不下時換到分頁下方，不重疊）；AI 關閉時沒有「新對話」，且沒有訊息時是一個空狀態（D1 小 Ditto、說明、「開啟 AI 對話」走同一個 `setEnabled`、三則範例），狀態徽章不再重複；輸入框停用時說明原因。確認視窗只換外觀，唯一的視窗鈕是「拒絕並關閉」。`tst_ui_style_pages.qml` 在基底上 10／12 失敗、目前 12／12 通過。

### 8.4 視窗裝飾、foot 與 Dock

- **誰畫標題列**：Ditto 自有視窗由 `WindowHeader` 畫唯一標題與果凍珠；Qt 不畫自己的標題列（`FramelessWindowHint`）由視窗本身的 `WindowFrameless` 決定，只在視窗未顯示時改（見 §8.5.2）。其他應用（foot）的標題列由 Wayfire `decoration` 外掛畫（server-side）。
- **安裝的預設＝J1**：`packaging/reference-image/session/wayfire.ini` 有 J1 的 `[decoration]`（深色標題字，在標題列上 11:1），`ditto-session` 把 `session/xdg`（`foot/foot.ini` → `styles/j1/foot.ini`）放在 `XDG_CONFIG_DIRS` 前面，Wayfire（Super＋Enter 的終端機）與經 `session.env` 的 Core 及其啟動的應用都看得到；使用者自己的 `~/.config/foot/foot.ini` 仍優先。`install-session.sh` 在有 foot 時以 `foot --check-config` 檢查。
- **單一標題列**：三份 `styles/<j1|j2|j3>/foot.ini` 都是 `[csd] preferred=server`，foot 不再自己畫標題列，只剩 Wayfire 那一條（coordinator 依推薦的可逆決定，2026-10-20）。代價：hover 時按鈕是 `libdecoration.so` 編譯內建的紅／綠／黃，設定檔改不掉。
- **VM 上 J1 標題字看不見**：c9df5eb 的 J1 設定本身是 9.2:1；推斷是 `apply.sh` 以 IPC 即時改色時，已畫好的標題字仍是 Wayfire 預設的白色（標題變更或重開視窗才重畫）。現在 J1 從登入就寫在 `wayfire.ini`，不靠即時改色。真 Wayfire 上**未驗證**。
- **三種風格的 foot 與標題列**：J1 淡薰衣草白（α0.97）、J2 暖粉紫且不透明、J3 冷水藍（α0.96）；標題列顏色三者不同。`tools/ui-candidates/check-styles.py` 檢查：session＝J1、單一標題列、只用 Wayfire 0.11 的選項、標題字在作用中／非作用中標題列上（疊在白與黑上）≥4.5、foot 前景／16 色／網址 ≥4.5、選取 ≥4.5、游標 ≥3、三種風格彼此不同。
- **跟隨切換（follow-up，未做）**：使用者改風格後，Wayfire 標題列與 foot 不會跟著換，仍是 J1。Core 已有經 Wayfire IPC 設定選項的路徑（布局策略的 `core/plugins`），可在合成器參與者的投影加入標題列選項並回讀、開機時重新套用；foot 只在啟動時讀設定，需另由啟動器帶入對應設定。這會改到交易的參與者與回讀，依本輪指示不硬做，列為 follow-up。
- **預覽工具**：`tools/ui-candidates/apply.sh j1|j2|j3|off|status [--restart-core]` 只預覽標題列與 foot（IPC 即時設定、`$XDG_RUNTIME_DIR/ditto/ui-candidate/` 的 foot.ini、`session.env` 的標記區塊只放 `XDG_CONFIG_DIRS`），不設 Shell 風格、不碰 Profile，`off` 逐位元還原。Shell 風格用個人化中心或 `dittoctl`。`selftest.sh` 以假 IPC 驗證 j1→j3→off 與 check-styles；真 Wayfire **未執行**。
- **Dock（`dock_pill`）**：缺圖示的應用是薰衣草家族漸層的 squircle＋白色大寫首字（中心對比 ≥4.5），執行中與使用中共用一種膠囊指示（使用中較長、選取色）；無障礙名稱不變。淺色主題預設即此外觀（`tst_dock.qml`、`tst_ui_style_dock.qml`、`tests/g4/motion` 的按壓回饋都改看實際畫出的 squircle）。

### 8.5 第二階段修正（VM 實機，c9df5eb）

| VM 發現 | 修正 | 測試 |
| --- | --- | --- |
| 「Ditto 設定」標題上緣被切 | 標題列被頂部左側的待辦面板蓋住：視窗高留 228 px，置中時標題列在 90 px 以下 | `tst_ui_style_layout.qml` 標題列與置中幾何 |
| 底部「已存的組合」被截 | 捲動條、Tab 捲入、PageUp／PageDown；捲到底時頁面內容完整（offscreen 未重現「捲不到底」本身） | 同上，捲到底與鍵盤捲入 |
| foot 雙標題列、J1 標題字看不見 | `[csd] preferred=server`；J1 寫入安裝的 `wayfire.ini` | `check-styles.py` |
| 小 Ditto 壓住分頁、範例被輸入框切、泡泡像殘影 | `EmptyState` 不越界、精簡版；泡泡貼近角色；J1／J3 視窗底不透明度提高（無模糊時桌布圖案不再透出） | `tst_ui_style_layout.qml` compact 幾何 |
| AI 關閉仍有「新對話」 | AI 關閉時隱藏 | 同上 |
| J3 視窗鈕、邊界、灰字太淡；J3 分頁與工具重疊 | 見 §8.2；工具鈕放不下時換行、compact 工具列內距 14 | 同上 |
| 三種 foot 幾乎一樣 | 三組色盤與標題列色 | `check-styles.py` |

### 8.5.1 修正輪 1（獨立審查 R1–R3、VM @b0dc73b）

- 個人化中心的選取標記與「已是目前值」判斷改看已提交投影（`tokens.appearance`），重同步／重連（`capabilitiesReloaded`）後重讀；組合中心、變更紀錄同樣重讀。
- 只移除 Ditto 自己加上的 `FramelessWindowHint`，切到深色／無主題或撤銷時原生標題列回來（offscreen 斷言旗標值，真實 Wayfire 由 VM 驗證）。修正輪 2 起改由 `WindowFrameless` 負責，見 §8.5.2。
- 對話面板、對話視窗與確認視窗用 `uiSheet`（α0.99，降低透明度時不透明），不再透出後方設定視窗。compact 對話面板依設計沒有視窗鈕：它是角色旁的 layer-shell 面板，不是一般視窗，以 Escape 或助理入口關閉，「展開」開啟有視窗鈕的完整視窗。
- 測試：`tests/g4/visual/unit/tst_ui_style_repair1.qml`。offscreen 文字比 VM 窄約 4%，所以 compact 案例另以 `font_scale` 1.05 重現 VM 的兩行說明。
- Follow-up（本輪不修）：J2 說明「色／彩」斷在詞中；對話輸入框 placeholder 截斷；灰字偏淡但已達 4.5:1；對話訊息清單（ListView）中變更卡的按鈕 Tab 到畫面外時不會捲入（基底即有）；`TextArea` 游標移出可見範圍時不跟隨（基底即有）。

### 8.5.2 修正輪 2（Shell 崩潰，VM @74a19c9）

- **現象**：2026-10-20 13:03 UTC，J2、開了 foot 與對話視窗後主 Shell segfault，堆疊在 render thread 的 `QWaylandGLContext::swapBuffers → DecorationsBlitter::blit → QOpenGLFramebufferObject::texture()`。
- **原因**（Qt 6.10.2 wayland-egl 原始碼）：在已顯示的視窗上改 `FramelessWindowHint`，`QWaylandWindow::setWindowFlags` 會在 GUI 執行緒立即建立或移除 Qt 標題列；render thread 每幀在 `makeCurrent`（有標題列才建 content FBO）與 `swapBuffers`（有標題列就從 content FBO blit）各讀一次。兩者之間出現的標題列會從沒建立的 FBO 讀取。修正前 `WindowHeader` 在建立、銷毀與風格切換時都會改旗標；Quickshell 關閉視窗時以 `deleteLater` 刪除後端視窗，所以關閉或收合有風格的視窗時，header 的 `Component.onDestruction` 也在仍顯示的視窗上移除旗標。owner 這次沒有切換主題，最符合紀錄的觸發點是關閉或收合有風格的對話視窗；未在 VM 重現，屬推斷。
- **修正**：`WindowHeader` 不再碰旗標。`shell/ui/WindowFrameless.qml` 由 Centers、ChatWindow、ApprovalWindow 各自宣告，只在視窗未顯示時改旗標：第一次開啟時 Quickshell 先把內容接上後端視窗再顯示，旗標在顯示前就定好；J1／J2／J3 之間不改旗標；風格開↔關（淺色↔深色、撤銷到無主題、Agent 改主題）時先經 FloatingWindow 的 `visible` 隱藏（不是關閉，確認視窗不會因此拒絕）、改旗標、再顯示；關閉視窗不改旗標。只移除自己加上的旗標。
- **可見的代價**：視窗開著時切換有風格／無風格，該視窗會短暫消失再出現，合成器可能重新擺放它的位置。J1／J2／J3 之間切換沒有這個現象。
- **測試**：`tests/g4/visual/unit/tst_ui_style_frameless.qml`。`DittoStub.StubFloatingWindow` 依 Quickshell 0.3.1 的接上與顯示順序建模，後端是真的 offscreen 視窗，會記錄每次旗標變更時視窗是否顯示中；`stage-ui116.mjs` 把三個視窗的根型別換成它（只改這一行，記在 `staging.json`）。涵蓋：第一次顯示、J1→J2→J3→關→J1、撤銷、主題切換、他處設的旗標保留、關閉視窗，以及隱藏再顯示後頁面、未送出的草稿、待確認的請求與焦點都還在（offscreen；真實合成器上的焦點與位置由 VM 驗證）。修正前 `74a19c9` 上 36 列中 21 列失敗，修正後 36／36 通過。修正輪 1 的旗標測試移到這裡，改在真實視窗上跑。

### 8.6 待 owner 決定

1. Wayfire 標題列與 foot 是否要跟隨個人化中心的選擇（見 8.4 follow-up）。
2. 強調色是否也要套用到三種風格的自有視窗。
3. 空狀態使用 D1 小 Ditto（素材授權仍未釐清，同 D11）。
4. `shell/change/`、頂部列、啟動器、通知是否一起套用風格。
5. 是否同時處理新視窗不 cascade（Wayfire `place` 模式），本輪未改。
6. Ditto 自有視窗無邊框後，邊緣拖曳調整大小消失（Super＋右鍵仍可）是否接受。
7. 視窗開著時切換有風格／無風格，視窗會短暫消失再出現（§8.5.2）是否接受；替代做法是固定無邊框並在無風格時也畫 Ditto 標題列，但會改變深色主題的外觀。

未執行：VM／參考機實機截圖與操作、Wayfire 真實裝飾與 FramelessWindowHint、foot 1.16 實際 `--check-config`、Orca、繁中輸入法、2× 實體螢幕、NFR 量測。
