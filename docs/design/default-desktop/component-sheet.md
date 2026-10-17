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
| Canvas／桌布 | 全幅。淺薰衣草，左側偏飽和（≈`#ccc8fa`），右側偏亮（≈`#e6e1fb`）；右側大型 Ditto 約 x 690–1215、y 145–570，帶泡泡、反光與水面 | `shell/jelly/Backdrop.qml`（由 `shell.qml` 的背景 PanelWindow 掛載） | 漸層 canvas **已實作**；桌布 Image 接點**已實作，待素材**（#51）與 Profile 欄位（§5 H2） |
| 左上標題／副標 | x≈25、y≈8–38；`01 — SOFT JELLY`、`A softer desktop for brighter days` | 無 | **待 owner**：是 caption、桌布字樣還是 widget 尚未決定；本 slice 不畫、不裁切 |
| 頂部工作區 | 置中浮動膠囊，x≈570–715、y≈4–32（≈145×28），作用中 `1` 為紫色小膠囊 | `shell/providers/panel_top`（不在 R1 寫入範圍） | **未改**：目前是全寬半透明列，工作區在左側（§4 D3） |
| 頂部狀態 | 右側 x≈1020–1262：Wi-Fi、音量、電池圖示、日期時間、搜尋 | 同上 | **未改**：目前是文字（「音量不可用」「網路未連線」）；狀態圖示待素材 |
| 天氣／手寫字 | 右上 x≈1180–1255、y≈52–102；右側手寫字兩處 | 無 | **待 owner**：桌布還是 widget 未定；不做假天氣 |
| 後方視窗（Files） | x≈37、y≈63、643×455；圓角≈14–16；標題列≈36；側欄≈120 寬 | 第三方應用。Ditto 只提供材質樣本 `shell/jelly/Material.qml` 供自有表面使用 | **待 owner**：實際應用與首次登入是否開啟；不重繪第三方 app |
| 前方視窗（Notes） | x≈77、y≈465、535×230 | 同上 | 同上 |
| Dock | 置中浮動膠囊，x≈379–901、y≈717–787（≈522×70），離底≈13；7 個彩色圖示≈44 px，間距≈75 | `shell/providers/dock_pill/qml/DockPill.qml` | 膠囊、應用圖示、fallback、使用中／執行中標示**已實作**；預設 Profile 仍綁 `dock_bottom`（§5 H3）；圖示風格待素材 |
| 右下助理 | x≈1065–1260、y≈710–764（≈197×54） | 無（R3／#67） | **不在 R1**：錨點保留空白，不畫假入口 |
| 留白 | 右半部留給桌布角色；視窗與 Dock 之間≈20 px；Dock 兩側大面積空白 | `Backdrop` 不放任何內容 | 已保留；無桌布時右側只有漸層（§4 D1） |

原生 capture 的實測幾何（offscreen，`capture.log` 的 `CAPTURE_META`）：頂部 0,0,1280×34；Dock 膠囊 444,720,392×68（本機裝有 6 個對應應用）；兩個材質樣本由 harness 放在原圖視窗位置，不是產品行為。

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

低效能模式的值與一般相同，但沒有陰影。限制：對比只對 canvas 計算；上了真實桌布後，半透明表面的實際底色會改變，要用桌布重算。降低透明度模式不受桌布影響。`on_accent` 實際是 `#000000`，見 §5 H5。

## 3. 柔光材質（`shell/jelly/Material.qml`）

- **一般模式＋硬體 renderer（`effect`）**：MultiEffect 只模糊 Material **自己的**陰影形狀（隱藏的 Rectangle），寬而淡、向下偏移。它不取樣表面後方的像素，**不是** compositor backdrop blur；Wayfire 0.11 上沒有可用的背景模糊協定，`blur_radius` 仍只是 token。
- **降低透明度，或 software renderer（`layered`）**：四層半透明圓角矩形疊出柔影，不用 shader。表面不透明，沒有頂部光澤與內亮邊，邊線加深。
- **低效能（`none`）**：不建立 MultiEffect，也不畫陰影，維持既有「無模糊、無陰影」。
- 三條路徑下，Material 都不接收輸入，尺寸不變；上面的內容、點擊與鍵盤焦點也都一樣（`tst_material.qml`）。
- 頂部光澤是一般 Gradient，內亮邊是 1 px 邊線，兩者都不用 shader。
- 目前 Shell 裡沒有任何表面使用 `Material`（管理中心、對話、試看列各自畫 Rectangle）。換用屬共用 UI 一致性工作，見 §5 H7。
- Dock 供應者從套件庫載入，不能 import `shell/jelly`。它用同一組 token 自己畫三層疊影與內亮邊，不建立 shader。

## 4. 偏離帳

每一項都需要 owner 確認後才算定案。

| # | 元件 | 原圖 | 原生（本 slice） | 理由 | 狀態 |
| --- | --- | --- | --- | --- | --- |
| D1 | 桌布 | 插畫桌布：大型 Ditto、泡泡、水面 | 兩段漸層 canvas | 沒有乾淨桌布原檔與散布授權（#51）；不從效果圖裁切或整張鋪底 | 待素材 |
| D2 | 左上標題、天氣、手寫字 | 有 | 未畫 | 用途未定；不硬編、不做假天氣 | 待 owner |
| D3 | 頂部 | 中央浮動工作區膠囊，右側狀態圖示，沒有整條實底列 | 全寬半透明列，左側「Ditto ▾」與工作區，中間視窗標題，右側文字狀態 | `panel_top` 不在 R1 寫入範圍；狀態圖示缺素材 | 未做，交後續 slice |
| D4 | 雙窗 | Files、Notes 實際應用畫面 | harness 放兩塊空白材質樣本並標明「非應用視窗」 | 不做假 app；第三方應用內部外觀不歸 Ditto；應用選擇待 owner | 待 owner |
| D5 | 視窗材質 | 近白、亮邊、寬淡柔影 | capture 走 software 的 `layered` 路徑，陰影有階梯感；正文取樣 `#f2f0fa`，原圖 `#faf9ff` | 本機沒有 GPU renderer，`effect` 路徑**未擷取**（§6） | 部分 |
| D6 | Dock 圖示 | 7 個柔亮彩色自繪圖示 | 本機已安裝應用的主題圖示（Yaru、Firefox snap）；沒有音樂應用，只有 6 個 | 圖示集的來源與權利未定（#51）；不用原圖的圖示 | 待素材 |
| D7 | Dock 狀態 | 原圖看不出執行中／使用中 | 使用中：底板＋長條；執行中：圓點；鍵盤焦點：外框 | 提案；三者形狀不同，不只靠顏色 | 待 owner |
| D8 | 次要文字 | `#9695a3` 在 `#faf9ff` 上 = 2.82:1 | `#57536f`（6.68:1） | 原圖的值低於 WCAG AA，可讀性優先 | 刻意偏離 |
| D9 | 圓角 | 視窗≈14–16 | token `radiusLarge` 20、`radiusMedium` 12；樣本用 16 | 沒有「視窗圓角」token | 待凍結 |
| D10 | Canvas 方塊紋 | 平滑 | software renderer 的漸層有淡方塊紋 | renderer 產物，不是 recipe | 硬體 capture 重驗 |
| D11 | 右下 | 小 Ditto 頭像＋文字膠囊 | 空白 | owner 已要求改成助理（R3／#67），不放假入口 | 交 #67 |

## 5. 交接需求（本 PR 不改 `crates/`、`schema/`、`defaults.rs`）

- **H1 預設主題（#45／Core）**：新的預設要不要用 `soft-jelly-light`，或改寫 `soft-jelly` 本身？`APPEARANCE_TOKENS` 每個 token 只有一個預設值，所以個人化中心與 Agent 看到的仍是深色預設。需要決定：要嘛依主題列出預設值，要嘛換掉預設值並同步更新 `appearance_tokens_match_the_shell` 測試。`defaults.rs` 目前把 accent 覆寫為 `#b9a4ff`，在淺色 recipe 下對比仍達標。
- **H2 桌布欄位（Core／#45／#51／#49）**：Profile `appearance` 需要一個由 Core 管理的桌布引用（素材 ID 或 Core 資料區內的資產，加 fit 方式，必要時分輸出），並經 ChangeSet 寫入。Shell 端只接 `Backdrop.wallpaperSource`，不讀環境變數或自訂設定檔。多螢幕的 crop／fit 由 #49 決定。素材與授權由 #51 決定。
- **H3 Dock 綁定（#45）**：預設 Profile 綁的是 `ditto.dock.bottom`（文字視窗列）。要對齊原圖，預設要改綁 `ditto.dock.pill`，並給一份實際存在的釘選清單（manifest 目前的預設是 firefox／foot／kate）。
- **H4 內建套件版本（#50）**：`ditto.dock.pill` 內容改了，但版本仍是 `1.1.0`。G1／G2 測試與語意任務集逐字引用 `1.1.0`。已有 store 的機器在 seed 時會記 `boot.builtin_refused`（同版本不同內容），保留舊內容，只有新 store 會拿到新 Dock。升版與升級路徑屬內建套件升版工作。
- **H5 `on_accent` 既有缺陷**：`Tokens.qml` 的 `onAccent` 屬性名稱以 `on`＋大寫開頭，被 QML 當成訊號處理器名稱，綁定沒有生效。實際值一律是 `#000000`，Profile 的 `on_accent` 覆寫也無效；`main` 上同樣如此。黑字在兩種 accent 上都達 AA。修正需要改名或另設 token，會影響所有呼叫端，本 PR 不動。
- **H6 頂部 slice**：浮動工作區膠囊與狀態圖示屬於 `panel_top` 供應者或新供應者，需要圖示素材，也要決定供應者 ID 與預設綁定（#45）。
- **H7 一致性**：管理中心、對話、試看列、通知、啟動器改用 `Material` 或同一組亮邊與陰影，需要逐一確認焦點與可讀性（#47）。
- **H8 硬體驗證（#52／#53／R4）**：`effect` 路徑的畫面、幀時（NFR-05），以及正常／降低透明度／低效能三種模式的 A/B，都要在實體參考機量測。本機只有 software renderer，未執行。
- **H9 圖示解析**：產品端用 `Quickshell.iconPath(name, true)`。harness 用 `capture/prepare.py` 模擬主題查找；實機選到的檔案可能不同，參考機要重驗。

## 6. 原生對照 capture

`tests/g4/visual/run.sh <證據目錄>` 依序執行：

1. 把 `dock_pill`、`panel_top` 複製到 `.staged/`。只移除 layer-shell 的三行，逐行記在 `staging.json`。
2. 跑 qmltestrunner 單元測試。
3. 讀本機的 desktop entry 與圖示主題。
4. 以 1280×800、scale 1 渲染四張圖：normal、reduced-transparency、low-power、dock-states。
5. 產出 side-by-side、50/50 疊圖（標出元件框）與逐元件取樣 `comparison.json`。

標明的測試資料：四個工作區（第一個作用中）、釘選清單、dock-states 圖中的兩筆視窗記錄。時鐘是執行當下的真實時間。不畫桌布、標題、天氣或助理。PNG 只放證據目錄，不進 git。

Quickshell 在本機無法執行（缺 `libcpptrace`、`libOpenGL`），offscreen 也只有 software renderer。因此 capture 用 `tests/g4/visual/stubs/` 的純 QML 替身代替 Quickshell 型別（PanelWindow 依 layer-shell 規則擺放）。這是開發證據：證明 QML 能建出這個畫面，但**不能**證明 Wayfire 上的實際合成、輸入區、焦點或效能。
