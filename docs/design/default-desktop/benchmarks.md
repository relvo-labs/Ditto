# 桌面設計與工程 benchmark

研究日 2026-10-17。這是依 Ditto 任務策展的比較，**不是全球排名，也沒有人體實驗證明誰最易用**。官方文件／固定原始碼是本輪依據；未操作外部產品，未採用品牌圖示或程式碼。

## 1. 八個一手對照

| 對象與官方來源 | 借用的具體方法 | 不複製的部分 |
| --- | --- | --- |
| [Apple HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)、[Motion](https://developer.apple.com/design/human-interface-guidelines/motion) | 材質分層、內容辨識、避免動態阻擋下一操作；輔助偏好是設計變體 | 不搬 Liquid Glass shader、Apple 圖示／品牌；原圖仍是視覺權威 |
| [Microsoft Fluent／WinUI Materials](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/materials)、[Acrylic](https://learn.microsoft.com/en-us/windows/apps/design/style/acrylic) | 區分常駐基底、短暫面板與不透明 fallback；in-app 與桌面背板不同 | WinUI 的系統自動降級不等於 Qt 已有；不把每層都玻璃化 |
| [GNOME HIG Keyboard](https://developer.gnome.org/hig/guidelines/keyboard.html)、[libadwaita SpringAnimation](https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.SpringAnimation.html)／[父類別 AdwAnimation.skip](https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/method.Animation.skip.html) | 鍵盤可到達、焦點順序、動畫 skip 的有效終態 | 不引入 GTK widget；應用的 Super 限制不能原樣套給 desktop shell |
| [KDE HIG Accessibility](https://develop.kde.org/hig/accessibility)、[Plasma](https://kde.org/plasma-desktop/) | 鍵盤／pointer／reader 分別測；focus 與 selection 不混淆，進階設定與主線分開 | 不複製整個 System Settings 選項量或 widget 生態 |
| [System76 COSMIC 快捷鍵](https://www.system76.com/support/pop-cosmic-keyboard-shortcuts) | 搜尋應用與已開視窗；模式提示可被發現，先回到工作再另開工作 | 不自動執行模糊命中的命令，不更換 Wayfire |
| [elementary HIG Undo](https://docs.elementary.io/hig/user-workflow/always-provide-an-undo) | 可逆操作、錯誤保留上下文與下一步 | 不將外部不可逆動作包成假 Undo；不搬 Pantheon |
| [Qt Quick MultiEffect](https://doc.qt.io/qt-6.10/qml-qtquick-effects-multieffect.html)、[SpringAnimation](https://doc.qt.io/qt-6.10/qml-qtquick-springanimation.html)、[TextInput composing](https://doc.qt.io/qt-6.10/qml-qtquick-textinput.html#inputMethodComposing-prop)、[software adaptation](https://doc.qt.io/qt-6/qtquick-visualcanvas-adaptations-software.html) | 原生 effect 範圍／成本、spring／retarget、IME composing、software 降級 | 一般 Qt 6 文件不等於 pinned 版本；MultiEffect 不是跨程序 backdrop blur |
| [Quickshell](https://quickshell.org)、[固定版 layer-shell focus](https://github.com/quickshell-mirror/quickshell/blob/2b4501a282689792b62e94f3fb30d8f512324fe6/src/wayland/wlr_layershell/wlr_layershell.hpp#L45-L76) | 常駐面板、明確喚出、鍵盤取得與歸還分開；專注於原生 Shell 接點 | Exclusive 不等於安全鎖屏；不照搬社群 showcase 當預設 |

前六項是桌面規範／產品參考（COSMIC 引用的是官方快捷鍵支援頁，不是 HIG），後兩項是工程能力基準，**不是八個完整桌面產品的 usability 排名**。Qt 6.10 的線上頁面目前標 6.10.3，repo 仍釘 6.10.2；任何 API 選型要再核對實際映像，沒有升級授權。文件圖片的版本與素材權利未逐一核實，不能直接納入發行包。

## 2. 固定版本的工程參考

SHA 是本輪研究快照，不表示最新 release，也不建議升級目標堆疊。

### Quickshell — 層級與焦點

- 固定 commit：[`2b4501a282689792b62e94f3fb30d8f512324fe6`](https://github.com/quickshell-mirror/quickshell/commit/2b4501a282689792b62e94f3fb30d8f512324fe6)。官方 README 明列 GitHub mirror 與自託管位置。
- [`wlr_layershell.hpp:45–76`](https://github.com/quickshell-mirror/quickshell/blob/2b4501a282689792b62e94f3fb30d8f512324fe6/src/wayland/wlr_layershell/wlr_layershell.hpp#L45-L76) 明列 None／Exclusive／OnDemand 及警告。助理待機不拿鍵盤、明確開啟才輸入、關閉後回焦要各自測，不用常駐 Exclusive 換取方便。
- README 宣告 LGPL 3；任何程式碼採用仍須檢查實際檔案與通知義務，不包括 showcase 的資產授權。

### Wayfire — 真背景模糊與整窗變形不是同一效果

- 固定 commit：[`fdf8832e4263db54e2fef2abf30326e16877b8a2`](https://github.com/WayfireWM/wayfire/commit/fdf8832e4263db54e2fef2abf30326e16877b8a2)。
- [`blur.cpp:112–168`](https://github.com/WayfireWM/wayfire/blob/fdf8832e4263db54e2fef2abf30326e16877b8a2/plugins/blur/blur.cpp#L112-L168) 處理擴張 damage、render target 邊界與像素保存；[`wobbly.cpp:59–110`](https://github.com/WayfireWM/wayfire/blob/fdf8832e4263db54e2fef2abf30326e16877b8a2/plugins/wobbly/wobbly.cpp#L59-L110) 這段顯示網格三角化與 model 頂點；spring 物理另見同目錄 `wobbly.c`，不是一般 easing。
- Ditto 提案：分開測 compositor backdrop、局部 QML 材質、整窗變形；不預設開啟全視窗 wobble。根 LICENSE 為 MIT，但 `wobbly.c` 有獨立來源／檔頭署名，採用前逐檔審查。

### niri — spring 的中斷與終止

- 固定 commit：[`45739bc072f9875a674d335ae724f10d3b35c665`](https://github.com/niri-wm/niri/commit/45739bc072f9875a674d335ae724f10d3b35c665)。
- [`spring.rs:140–176`](https://github.com/niri-wm/niri/blob/45739bc072f9875a674d335ae724f10d3b35c665/src/animation/spring.rs#L140-L176) 保留初速度、epsilon 並處理阻尼；來源註記有 libadwaita／RBBAnimation。
- 借用 retarget／settle／skip／長幀測試方法，不複製一組參數、不換 scrolling-tiling 模型。根 GPL-3.0 與檔內衍生來源要分別審查，不批准直接搬 Rust 檔進 Ditto。

### DankMaterialShell — 能力判定與 QML 動態

- 固定 commit：[`d8a87a8e13693b4e0a2a627e5e7ef6bb7248b311`](https://github.com/AvengeMedia/DankMaterialShell/commit/d8a87a8e13693b4e0a2a627e5e7ef6bb7248b311)。
- [`RectSpringMotion.qml:26–64`](https://github.com/AvengeMedia/DankMaterialShell/blob/d8a87a8e13693b4e0a2a627e5e7ef6bb7248b311/quickshell/Common/RectSpringMotion.qml#L26-L64) 是 retarget／速度與終止處理；[`BlurService.qml`](https://github.com/AvengeMedia/DankMaterialShell/blob/d8a87a8e13693b4e0a2a627e5e7ef6bb7248b311/quickshell/Services/BlurService.qml) 的 compositor probe 與 [`BackdropBlur.qml`](https://github.com/AvengeMedia/DankMaterialShell/blob/d8a87a8e13693b4e0a2a627e5e7ef6bb7248b311/quickshell/Widgets/BackdropBlur.qml#L6-L42) 的 sourceItem 局部效果不同。
- 借用 capability 狀態與停止更新的方法，不引入其 daemon 或整套 Shell；不推定目前 Wayfire 支援其 probe protocol。MIT 根 LICENSE 不自動覆蓋歷史版本、插件、字型、音效與圖示。

[Noctalia](https://noctalia.dev) 留為後續候選：本輪只核對官方入口與 repo metadata，沒有讀其機制，**不宣稱可直接移用**。

## 3. 對 Ditto 的選擇

1. 圖片決定預設外觀；Apple／Fluent 提供材質分層方法，不變成另一個品牌風格。
2. KDE／GNOME 提供鍵盤與可及性流程；COSMIC／elementary 提供找回工作、可逆操作與失敗復原的方法。
3. Quickshell／Qt／Wayfire 是原生可行性主線；niri／DMS 只作機制研究，不升級、不移植、不引入新常駐服務。
4. 「易用性做到極致」先轉成任務、誤操作、焦點、恢復與可讀性證據，沒有數據前不宣稱比外部產品更好用。

固定原始碼與官方文件可支持機制研究，但不是授權相容性結論，也不是 runtime 測試結果。
