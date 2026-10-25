# 首次開機帳號畫面（#212，PR B）

本目錄提供 `_greetd` 的 wrapper、Wayfire 設定與 Chewing profile。
帳號與完成／pending 標記由 PR A 的 root helper 唯一寫入；QML 只保留輸入暫態，
不寫 `/etc`、Profile 或標記，也不負責回復交易。

## 接線與失敗路徑

wrapper 以 `/etc/login.defs` 的 UID_MIN／UID_MAX 查 `getent passwd`；查詢異常即退出，
已有一般帳號則 exec `/usr/sbin/agreety --cmd /usr/local/libexec/ditto-image-session`。
沒有帳號才啟動暫態 D-Bus session、Wayfire、fcitx5 與獨立 Quickshell config。
Quickshell 結束時 wrapper 終止並等待合成器及輸入法，不留下 greeter 背景程序。
圖形失敗只重試一次 `WLR_RENDERER=pixman QT_QUICK_BACKEND=software`；再失敗或沒有
DRM 時，以 `_greetd` 執行 helper `--tty`（須由 PR A 提供 socket client），之後走 agreety。
文字模式不承諾繁中輸入、中文 VT 顯示或 Orca。

`greetd.service` 的 `ExecStartPre=-/usr/lib/ditto/wait-drm` 保留最多 30 秒等待，
但失敗不再殺掉 greetd，故即使 tty1 getty 被 mask，wrapper 仍可抵達文字模式。
不另開 root console，也不開第二個 getty。GPU、logind 座位、TTY 交接仍待 VM。

Quickshell 0.3.1 的本機 `quickshell-io.qmltypes` 已核對 `Socket.path/connected/write/flush`、
`SplitParser`；使用 `Quickshell.Io.Socket` 直接連 `/run/ditto/firstboot-account.sock`，
一個 UTF-8 JSON 請求加換行，合計最多 4096 bytes；回覆接受完整 JSON（可帶換行）。
無 CLI bridge，密碼不進 argv、環境變數或日誌。Socket 回覆／失聯／逾時沒有自動重送。
失聯後顯示結果未知，要求重啟供 helper 檢查，不能宣稱已回復。

helper 回覆 `ok` 後依序 `Greetd.createSession(username)`、只對一次非回顯的 challenge
`respond(password)`、`launch(["/usr/local/libexec/ditto-image-session"])`。第二次提示、
PAM 失敗或逾時停止並清除密碼，提供回登入畫面的按鈕，不重跑建立帳號。
QML／JS 字串及 Qt socket 緩衝區無法保證原地清零；程式只縮短持有時間，成功交接後退出。

## 介面、輸入法與無障礙

使用現有 JellySurface、TextField、Button、Tokens、Backdrop；單卡採 owner 的 1A 參考。
提示字採深色、密碼最短長度放在密碼欄旁，管理員說明與相符提示分開。
只有真正的輸入焦點框；沒有靜態假焦點。未實作的放大文字／閱讀器開關／語言與鍵盤
膠囊全部移除；頁尾顯示實際綁定的 Super+Alt+S（`orca --replace`）。

新增套件 `fcitx5-chewing`，預設 keyboard-us＋Chewing 注音；既有 chinese-addons 留下，
不把拼音當注音。Wayfire 啟用 input-method-v1，Qt 使用 Wayland text-input-v3，
`QT_IM_MODULE`／`QT_IM_MODULES` 留空。「你的名字」可使用 IM；帳號與密碼設定
`ImhNoPredictiveText | ImhLatinOnly`，密碼另帶 `ImhSensitiveData | ImhHiddenText`。
這些提示在 fcitx5 實際候選／提交上的效果仍須 VM 回讀。

所有輸入與按鈕有 Accessible role／name／description，密碼為 passwordEdit，錯誤為
AlertMessage；密碼欄另有明確 `Accessible.labelledBy`（Qt 6.10 會遮蔽 Password 的直接 name getter）。Tab 順序是名字→帳號→密碼→確認→建立，Shift+Tab 反向，不能建立時跳過
停用按鈕。超出小螢幕高度可捲動，焦點自動捲入可視區。
新增 `at-spi2-core`、`orca`、`speech-dispatcher`，設定 `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`。
**Orca 讀取／發聲、greeter 的音訊服務、純鍵盤實機流程、中文實際提交均未在 VM 驗證。**

## PR A 暫接點

`TODO_FIRSTBOOT_ACCOUNT_PR_A` 明列於 generator／finalizer／recipe 測試。
PR A 不在來源 archive 時仍可建置，greetd 維持舊 agreety 命令；映像內
`/usr/share/ditto/firstboot-integration.json` 記錄 `enabled:false` 與 TODO，不能當作首次設定可用。
只要 PR A 的 crate／任一 unit／tmpfiles 出現，就要求以下整套 artifacts，缺少即在建立
output 之前失敗；全部齊備才切到 `/usr/lib/ditto/ditto-greeter` 並啟用 socket：

- 同 source runtime lock 的 `usr/lib/ditto/target/release/ditto-firstboot-account`；依既有 native
  工具鏈、path remap、來源與 NOTICE 規則建置。generator 以相對 symlink 提供契約路徑
  `/usr/lib/ditto/ditto-firstboot-account`，不從任意外部位置複製 executable。
- 來源 `packaging/distro/first-boot/units/ditto-firstboot-account.{socket,service}`。
- 來源 `packaging/distro/first-boot/tmpfiles.d/ditto-firstboot.conf`。

本 PR 不修改 PR A 的 crate／units。QML 的格式／長度只是 UX 鏡像；helper 的限制、
保留字、既有群組與帳號碰撞才是權威，整合時必須以 PR A 最終驗證表再次核對。

## 來源與尚未驗證項目

新程式為 Ditto 自有 MIT。桌布重用既有 `shell/wallpapers/SOURCES.md`，權利仍未釐清。
新增 Ubuntu 套件應從同 snapshot 取用並保留 `/usr/share/doc/*/copyright`；精確版本、
授權全文、傳遞依賴與 SBOM 留待實際新映像 dpkg manifest 回讀，尚無發行授權盤點完成聲明。
來源位置：Ubuntu archive 的 fcitx5-chewing、at-spi2-core、orca、speech-dispatcher source packages。
此 PR 沒有下載套件、重建映像或做 host／VM 設定。

VM 仍須驗：GPU／pixman／無 DRM、PAM 成功與失敗、中文名字、Orca／音訊、重開登入、
PR A pending 復原、getent／shadow yescrypt／sudo／家目錄與標記，以及 journal 密碼掃描。
