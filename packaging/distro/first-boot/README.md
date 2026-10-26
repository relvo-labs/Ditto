# 首次開機帳號整合（#212）

PR A 提供 root 帳號 helper、socket、復原與文字 units；PR B 提供原生 1A 畫面、
greeter、輸入法與 Ubuntu 映像接線。以下保留兩者的責任與驗證範圍。

## Greeter 與畫面（PR B）

本目錄提供 `_greetd` 的 wrapper、Wayfire 設定與 Chewing profile。
帳號與完成／pending 標記由 PR A 的 root helper 唯一寫入；QML 只保留輸入暫態，
不寫 `/etc`、Profile 或標記，也不負責回復交易。

## 接線與失敗路徑

wrapper 以 `/etc/login.defs` 的 UID_MIN／UID_MAX 查 `getent passwd`；查詢異常轉登入畫面，
已有一般帳號則 exec `/usr/sbin/agreety --cmd /usr/local/libexec/ditto-image-session`。
沒有帳號才啟動暫態 D-Bus session、Wayfire、fcitx5 與獨立 Quickshell config。
Quickshell 結束時 wrapper 嘗試終止並等待合成器及輸入法；Orca 經 `--orca` 啟動並記錄該次子程序 PID，清理時嘗試終止。AT-SPI／speech-dispatcher 等 D-Bus 啟動程序仍未逐一監督，不能保證沒有殘留。
圖形失敗只重試一次 `WLR_RENDERER=pixman QT_QUICK_BACKEND=software`；再失敗或沒有
DRM 時，wrapper 只以固定 `ditto-firstboot-tty --request` 送出 `tty\n`；不再以 `_greetd` 呼叫 root-only helper。
新 socket `/run/ditto/firstboot-tty.sock` 為 `root:_greetd 0660`，由 systemd `Accept=no` 啟動一次性 root dispatcher。
dispatcher 在讀內容前以 `SO_PEERCRED` 確認 `_greetd` UID，並將 peer 的實際 PPid ancestry 與 systemd 回讀的
`greetd.service MainPID` 比對；單有相同 UID、群組或自述欄位不夠。只接受 4 bytes 的固定請求及 EOF，
沒有帳密、參數、路徑或命令欄位；畸形、超長、逾時、非 greeter 或重播不會停止 greetd。

root 重新檢查本機 passwd、NSS 與 UID_MIN..UID_MAX；已有帳號或查詢不明時只回登入，不啟動 TTY。
無帳號時以 O_EXCL／O_NOFOLLOW 在 root 擁有、不可由 greeter 寫入的 `/run/ditto` 建立
`firstboot-tty-used`，然後只 queue `ditto-firstboot-account-tty.service`。這個本次開機 latch
不是 helper 的完成標記，保留到重開機，連 unit 啟動失敗也不自動再嘗試。

TTY unit 與 greetd／getty@tty1 Conflicts 並 After，等停止完成才取得 controlling `/dev/tty1`。
root prepare unit 固定 `loginctl terminate-user _greetd`，最多等待 5 秒確認 `_greetd` 程序退場，涵蓋 PAM
移出 greetd cgroup 的 session；仍有程序就拒絕 VT 接管。接著驗證 foreground controlling tty1，
以固定 VT_ACTIVATE／VT_WAITACTIVE(1)（5 秒 deadline）切換可見 VT。prepare unit 只持有
`CAP_SYS_TTY_CONFIG` 供此固定切換；帳號 TTY unit Requires／After prepare，但只 Wants recovery，維持原本三項 account capabilities，不讓 helper 繼承 VT capability。沒有授予 greeter capability／sudo／setuid／polkit 或一般 systemctl 權限。
帳號寫入與交易鎖仍只由未修改的 helper 負責。

helper `--tty` 每次結束後重查帳號；有帳號就結束 TTY，透過 unit 的 OnSuccess 回 greetd／agreety，使用者輸入
帳密走正式 PAM 登入，沒有 autologin。無法確認建立時保留說明，不宣稱 rollback 成功；最多三次嘗試，每次重試
都要按 Enter。EOF／中斷／次數用盡會停止，說明重開機重試或管理員復原，並回一般登入。TTYReset、TTYVHangup、
SendSIGHUP、KillMode=control-group 釋放終端；OnFailure 亦回 greetd。本次開機 latch 使後續 wrapper
只到一般登入，避免無帳號／無 DRM 時快速重生。若交易已留下有密碼帳號但 pending 不明，仍保留帳號與紀錄供 root 核對。
文字模式不承諾繁中輸入、中文 VT 顯示或 Orca。

`greetd.service` 的 `ExecStartPre=-/usr/lib/ditto/wait-drm` 保留最多 30 秒等待，
但失敗不再殺掉 greetd，故即使 tty1 getty 被 mask，wrapper 可送出上述固定 handoff；是否在真實 systemd／VT／shadow-utils／PAM 下成立，仍待可丟棄 VM 驗證。
不另開 root console，也不開第二個 getty。GPU、logind 座位、TTY 交接仍待 VM。

Quickshell 0.3.1 的本機 `quickshell-io.qmltypes` 已核對 `Socket.path/connected/write/flush`、
`SplitParser`；使用 `Quickshell.Io.Socket` 直接連 `/run/ditto/firstboot-account.sock`，
一個 UTF-8 JSON 請求（本體最多 4096 bytes，結尾 LF 不計）；回覆接受完整 JSON（可帶換行）。
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
膠囊全部移除；頁尾顯示實際綁定的 Super+Alt+S（wrapper `--orca` 執行固定 `orca --replace` 並記錄 PID）。

新增套件 `fcitx5-chewing`，預設 keyboard-us＋Chewing 注音；既有 chinese-addons 留下，
不把拼音當注音。Wayfire 啟用 input-method-v1，Qt 使用 Wayland text-input-v3，
`QT_IM_MODULE`／`QT_IM_MODULES` 留空。「你的名字」可使用 IM；帳號與密碼設定
`ImhNoPredictiveText | ImhLatinOnly`，密碼另帶 `ImhSensitiveData | ImhHiddenText`。
Hints 只是內容提示；帳號、密碼與確認欄每次取得焦點時，另以固定參數
`fcitx5-remote -c` 嘗試關閉輸入法，不帶使用者資料。帳號內層 TextInput 加上
RegularExpressionValidator，拒絕非格式文字的實際編輯／IM 提交。fcitx5 的實際停用狀態仍須 VM 回讀。

所有輸入與按鈕有 Accessible role／name／description，密碼為 passwordEdit，錯誤為
AlertMessage；密碼欄另有明確 `Accessible.labelledBy`（Qt 6.10 會遮蔽 Password 的直接 name getter）。Tab 順序是名字→帳號→密碼→確認→建立，Shift+Tab 反向，不能建立時跳過
停用按鈕。超出小螢幕高度可捲動，焦點自動捲入可視區。
新增 `at-spi2-core`、`orca`、`speech-dispatcher`，設定 `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`。
**Orca 讀取／發聲、greeter 的音訊服務、純鍵盤實機流程、中文實際提交均未在 VM 驗證。**

## 合併後映像接線與先決條件

PR A 已合併；正常 archive 必須走完整耦合路徑。`TODO_FIRSTBOOT_ACCOUNT_PR_A` 僅保留為舊 archive 全缺席時的明確狀態，recipe 測試會刻意移除整組來源與 runtime binary 才覆蓋此分支。
PR A 不在來源 archive 時仍可建置，greetd 維持舊 agreety 命令；映像內
`/usr/share/ditto/firstboot-integration.json` 記錄 `enabled:false` 與 TODO，不能當作首次設定可用。
只要 PR A 的 crate／任一 unit／tmpfiles 出現，就要求以下整套 artifacts，缺少即在建立
output 之前失敗；全部齊備才切到 `/usr/lib/ditto/ditto-greeter` 並啟用 socket：

- 同 source runtime lock 的 `usr/lib/ditto/target/release/ditto-firstboot-account`；依既有 native
  工具鏈、path remap、來源與 NOTICE 規則建置。generator 以相對 symlink 提供契約路徑
  `/usr/lib/ditto/ditto-firstboot-account`，不從任意外部位置複製 executable。
- 來源 `packaging/distro/first-boot/units/` 的 account socket／service、recovery、TTY，以及新的 dispatch socket／service、prepare service，共七個 unit。TTY unit 由 PR B 接上 root session；helper src/* 與其餘 PR A units 保留。
- 來源 `crates/ditto-firstboot-account/UNICODE-NOTICE.txt` 原文安裝到 `/usr/share/doc/ditto-firstboot-account/UNICODE-NOTICE.txt`。
- 來源 `packaging/distro/first-boot/tmpfiles.d/ditto-firstboot.conf`。

generator 為 account 與 dispatch socket 建立 `sockets.target.wants`，並建立 recovery 的 `sysinit.target.wants`、`greetd.service.wants`；finalizer 啟用兩個 socket／recovery 並移除舊 `greetd.service.requires` recovery link。recovery 維持 `Before=greetd.service`，其失敗不以 Requires 阻止既有登入。TTY unit 安裝但不預設啟用。

必須從整合來源重建 helper，重新產生 runtime lock，確認 lock 包含
`usr/lib/ditto/target/release/ditto-firstboot-account`；沿用沒有該檔案的舊 lock 會被拒絕。`runtime_policy.py`／`lock-runtime.py` 已接受該路徑，但 repo 沒有端到端 runtime producer；本次沒有重建 helper／runtime、產生真實 lock 或映像。D04 producer 的同來源建置、path remap、NOTICE 與新 lock 是實映像接受的先決條件。

本 PR 不修改 PR A 的 crate／units。QML 的格式／長度只是 UX 鏡像；helper 的限制、
保留字、既有群組與帳號碰撞才是權威。已依 PR A 修復後的 PROTOCOL.md 對齊：密碼至少
8 個 Unicode scalar、最多 511 UTF-8 bytes；少於 12 scalar 或 Unicode 四類中不足兩類只警告。
`bubble42!` 會警告。Qt 6.10.2 的 Array.from(QString)／Unicode property regexp 不符這項需要，
所以手動計數 surrogate pair，並從本機 ICU 的 Unicode 17.0.0 屬性產生唯讀範圍表；
Lowercase／Uppercase／Number／Alphabetic 與 Rust char 分類定義相同，沒有額外 blocklist。
產生器在 tests/firstboot/generate_unicode.py，資料授權／來源在 shell/firstboot/UNICODE-NOTICE.txt；
沒有新增 greeter 常駐程序或 runtime 相依。helper 的 weak_password 回覆仍驗證型別，但不再存入
未使用欄位：建立前已顯示相同規則的警告，成功後立即走 PAM，不新增確認步驟。
標記已對照 PR A transaction.rs：`/var/lib/ditto/firstboot/{account-created,pending}`。

共用 TextField 不對 null 設 labelledBy，只在完成建立且 label 非 null 時關聯；passwordEdit 為
首開密碼欄明確 opt-in，既有 API-key／secret 欄保留可存取名稱。可重試錯誤把焦點移到可聚焦的
AlertMessage，PAM 資訊與真實階段透過 Accessible.announce 宣告；Orca 的實際讀取仍待 VM。

## 來源與尚未驗證項目

新程式為 Ditto 自有 MIT。桌布重用既有 `shell/wallpapers/SOURCES.md`，權利仍未釐清。
新增 Ubuntu 套件應從同 snapshot 取用並保留 `/usr/share/doc/*/copyright`；精確版本、
授權全文、傳遞依賴與 SBOM 留待實際新映像 dpkg manifest 回讀，尚無發行授權盤點完成聲明。
來源位置：Ubuntu archive 的 fcitx5-chewing、at-spi2-core、orca、speech-dispatcher source packages。
此 PR 沒有下載套件、重建映像或做 host／VM 設定。

VM 仍須驗：GPU／pixman／無 DRM、PAM 成功與失敗、中文名字、Orca／音訊、重開登入、
PR A pending 復原、getent／shadow yescrypt／sudo（新帳號以自己的密碼 `sudo -v` 成功提權）／家目錄與標記，以及 journal 密碼掃描、登入後沒有殘留 `_greetd` 程序（含 Orca／AT-SPI／speech-dispatcher）。


## 原生 helper（PR A）

這是 #212 的 PR A：建立第一個管理員帳號的 Rust helper、socket、開機復原與文字保底 units。協定在 [PROTOCOL.md](../../../crates/ditto-firstboot-account/PROTOCOL.md)；PR B 負責畫面、greeter、無 DRM 的啟動選擇及映像接線。本次已接入 Ubuntu generator／finalizer 的靜態安裝路徑；runtime 產物與真實 root TTY／VT 交接驗證仍是上述先決條件，沒有宣稱已重建或接受實映像。

## 流程與安裝位置

沒有 UID_MIN..UID_MAX 內的人員帳號時，greeter 送一筆請求給 root helper。helper 回讀確認帳號與完成標記後回應成功；greeter 再用剛輸入的密碼走 greetd／PAM 正式登入。這不是自動登入，也不預埋帳號。不使用 `ConditionFirstBoot` 或 machine-id 判定。

| 來源 | 預期安裝位置／啟動 |
| --- | --- |
| `cargo build --release -p ditto-firstboot-account --locked` 的 binary | `/usr/lib/ditto/ditto-firstboot-account`，root 擁有、0755，放在唯讀 `/usr` |
| `crates/ditto-firstboot-account/UNICODE-NOTICE.txt` | `/usr/share/doc/ditto-firstboot-account/UNICODE-NOTICE.txt`，隨 binary 保留資料授權通知 |
| `units/*.service`、`units/*.socket` | `/usr/lib/systemd/system/` |
| `tmpfiles.d/ditto-firstboot.conf` | `/usr/lib/tmpfiles.d/ditto-firstboot.conf` |
| `ditto-firstboot-account.socket` | 映像階段啟用到 `sockets.target` |
| `ditto-firstboot-account-recover.service` | 映像階段啟用；建立 `sysinit.target.wants` 與 `greetd.service.wants` 連結 |
| `ditto-firstboot-account-tty.service` | 只在無 DRM 的 root 啟動路徑按需啟動，不預設啟用；與 greetd、getty@tty1 互斥 |

tmpfiles 建立 `/run/ditto`、root 擁有的 `/var/lib/ditto/firstboot`（0700）及 `/var/mail`（root:mail、2775，保留 setgid）。`/etc`、`/home`、`/var/lib/ditto`、`/var/mail` 必須位於可寫的共用狀態分割區；`/usr` 回退不刪除帳號。PR B 須保證 pristine 映像沒有 `pending` 或 `account-created`。

`Accept=no` 傳入 listener fd 3。helper 驗證 `LISTEN_PID`、`LISTEN_FDS=1`、AF_UNIX、SOCK_STREAM 與 SO_ACCEPTCONN，設定 CLOEXEC，一次處理一條連線後退出；不自行 bind、unlink 或 shutdown 共享 listener。socket 佇列中的下一個請求會啟動下一次服務。

## 信任邊界

OS 帳號由固定的 root helper 與系統帳號資料庫持有；這不是 Desktop Profile，也沒有新增 Agent 權限入口。一般桌面與畫面不以 root 執行。請求不可選擇 UID、路徑、shell、群組或命令。

socket 為 `root:_greetd 0660`，再以 `SO_PEERCRED` 核對 runtime `_greetd` UID；群組權限與請求自述身分都不能代替 UID 核對。`--tty`、`--recover` 只接受 root 啟動；`_greetd` 不可自行執行這些模式取得權限。文字保底必須由 root unit 啟動，不能把 greeter 包成 sudo 呼叫。

授權條件是持鎖後重查「尚無人員帳號」。UID 範圍取自 `/etc/login.defs`，缺少、重複或不合理的範圍均拒絕。檢查本機 passwd 與 NSS 列舉，並檢查使用者、群組與相關既有資料衝突。完成標記只是一道額外防線；標記被刪除也不能建立第二個人員帳號。

帳號工具與路徑寫死為：

```text
/usr/sbin/useradd -m --no-log-init -U -G sudo -s /bin/bash -K HOME_MODE=0750 -c <gecos> <name>
/usr/sbin/chpasswd --crypt-method YESCRYPT
/usr/sbin/userdel -r <name>
/usr/bin/getent passwd
/usr/bin/getent passwd|group <name>
```

`-G sudo` 只有在映像真的有 sudo 時才代表管理權限。#221 VM 驗收（`VM221-B-001`）發現：帳號已加入 `sudo` 群組，映像卻沒有 sudo，root 又是鎖定的。Ubuntu 配方因此在 normal 映像加入 `sudo` 套件，使用 Ubuntu 預設的 `%sudo ALL=(ALL:ALL) ALL`（需要密碼，沒有 NOPASSWD）；recipe 測試會從這裡的 useradd 參數讀出群組，要求每個群組都有對應的工具套件。helper 本身沒有修改。映像尚未重建，sudo 的實際提權仍待 VM 驗證。

`--no-log-init` 避免寫入 `/var/log/lastlog`／faillog；HOME_MODE 固定為 0750。指定 YESCRYPT 讓 chpasswd 走 libcrypt 而非 PAM 密碼品質拒絕，符合 owner「弱密碼警告但允許」的政策；登入仍走 greetd／PAM。帳號工具採清空後的固定環境，stdout／stderr 不輸出。密碼只透過 chpasswd stdin 傳遞，不放 argv、環境、journal、pending 或完成標記。

helper 日誌只有 `phase=<階段> result=<結果>`，不包含帳號、顯示名稱、密碼或原始錯誤。請求與密碼配置用 volatile writes 清除完整 allocation，關閉 core dump。password 使用借用的 JSON RawValue，再解碼到可清零的緩衝，避免 serde_json 的 escape scratch 留下密碼；解析完即清除原始請求。這不能保證清除 kernel socket／pipe、swap、帳號工具、Qt／JS 或 CPU／allocator 之外的所有副本；正式 VM 仍須掃描 journal。

## 交易與復原

1. 取得 `/var/lib/ditto/firstboot/lock` 的排他 flock；檢查狀態目錄及其祖先由 root 擁有、沒有不安全的群組／其他人寫入權限，並拒絕符號連結。文字與 socket 入口共用這一條交易。
2. 完成標記存在時，只補清 pending 並同步目錄，絕不 userdel。`--recover` 在任何鎖、目錄安全、login.defs、NSS 或 pending 解析等可能失敗的檢查前先走已完成路徑：以非阻塞鎖嘗試補清，失敗不等待、不傳回錯誤，不讓已配置機器的登入依賴 firstboot 清理成功。
3. 若 pending 存在且沒有完成標記，解析版本與安全帳號名稱，再檢查本機／NSS 人員帳號。只有 pending 指定帳號仍為固定 useradd 初始狀態，才可 userdel：passwd 為 `x`、UID 在 UID_MIN..UID_MAX、固定 `/home/<name>` 與 `/bin/bash`、唯一 shadow 密碼欄恰為 `!`，且沒有其他人員帳號。待建帳號尚不存在也可嘗試清理。缺資料、身分不明或其他狀態皆拒絕刪除並保留 pending。
4. 重查完成標記、UID 範圍、沒有任何人員帳號，以及輸入與名稱衝突。
5. 以暫存檔 → fsync → rename → 目錄 fsync 寫入 `pending`；只有這一步成功後才執行 useradd。
6. 建立帳號並設定密碼；回讀 passwd 的 UID、主要 GID、GECOS、固定 shell／home、shadow 的 `$y$` 前綴、同名主要群組、sudo 成員、家目錄的型態／0750／擁有者。同步帳號檔與父目錄後，才寫完成標記。
7. 完成標記同樣以暫存 → fsync → rename → 目錄 fsync 提交，再刪 pending 並同步目錄。提交後持鎖清理 pending，失敗立即再試一次（包含重新 fsync）；兩次仍失敗則記為 deferred，下次復原再補清。已提交標記優先，不能刪除完成的帳號。
8. 同一次交易提交前失敗則清除可能已 rename 的完成標記、呼叫 userdel -r，回讀 passwd、shadow、group、gshadow、subuid、subgid、home、mail。全部不存在並同步帳號檔與父目錄後，才清 pending 並回 `internal_rolled_back`；任何殘留或讀取失敗則保留 pending、回 `internal_rollback_failed`。

兩種紀錄的 v1 格式相同；沒有密碼或顯示名稱：

```json
{"version":1,"username":"alice","timestamp":1792960000}
```

`timestamp` 是 Unix seconds。未知 pending 版本會停止復原；任何完成標記存在都會阻止新交易。A/B 兩邊須維持這個格式，不能以切換 `/usr` 當作帳號回復方式。root 修復前應保留紀錄；不能只刪 pending／完成標記來掩蓋殘留。

已設定密碼的帳號一律不由啟動復原刪除，即使是鎖定的 hash、非 yescrypt hash，或 home 權限／sudo 成員後來改變。這比只檢查完整的成功快照更保守，也避免刪除標記後把既有管理員當成 pending 回復。遇到「chpasswd 已完成、標記尚未提交」的中斷，也會保留帳號、家目錄與 pending：`--recover` 回 `internal_rollback_failed`，新建請求回 `already_provisioned`；須由 root 核對後解決模糊狀態。既有 useradd 後、chpasswd 前中斷的自動回復仍保留。同一次、持鎖且確知由自己建立的未提交交易發生錯誤時，仍照第 8 步回復。

復原 unit 使用 `DefaultDependencies=no`，在 local-fs 與 tmpfiles 後、sysinit／sockets／greetd 前完成，避免「socket 等待 recovery，而 recovery 等待 basic.target」的排序循環。socket 維持 Requires recovery，確保待建交易先完成復原；greetd 則採 Wants 與 Before 排序，不再使用 RequiredBy。即使 helper 的已完成路徑保證成功，systemd 仍可能在 ExecStart 前因 mount／namespace／tmpfiles 設定而失敗，不能讓這類失敗阻止已配置機器登入。PR B 安裝時須建立 `greetd.service.wants`，不能沿用舊的 `.requires` 連結；升級時須移除那個舊連結。首次設定的復原失敗仍須由 PR B／#152 提供 tty1 說明與救援入口，這項接線沒有在 PR A 宣稱完成。每次交易還會再次檢查 pending，因此同一次開機的重試也會先復原。

## systemd 259 限制與理由

已核對 [systemd.exec(259)](https://www.freedesktop.org/software/systemd/man/259/systemd.exec.html)、[systemd.socket(259)](https://www.freedesktop.org/software/systemd/man/259/systemd.socket.html) 與 [systemd.service(259)](https://www.freedesktop.org/software/systemd/man/259/systemd.service.html)。原始碼核對採 [shadow 4.17.4 useradd](https://github.com/shadow-maint/shadow/blob/4.17.4/src/useradd.c)、[chpasswd](https://github.com/shadow-maint/shadow/blob/4.17.4/src/chpasswd.c)、[userdel](https://github.com/shadow-maint/shadow/blob/4.17.4/src/userdel.c)；Ubuntu 的實際 patch 與配置仍須 VM 驗證。

| 設定 | 理由／相容條件 |
| --- | --- |
| `ProtectSystem=strict` 與四個 `ReadWritePaths` | 只為帳號資料、home、交易紀錄與 mail 開放寫入；不開放 `/usr`、`/var/log`。不能讓唯讀 superblock 變可寫。未設 ProtectHome，因為工具必須寫入家目錄。 |
| `PrivateNetwork=yes`、`RestrictAddressFamilies=AF_UNIX` | 接收 systemd 傳入的 socket；新網路／netlink sockets 不開放。此版本預期本機 files NSS，不能宣稱支援 LDAP／網路 NSS 或額外 audit netlink。 |
| `NoNewPrivileges=yes` | helper 已由 root 啟動；不依賴 setuid 提權。chpasswd 指定 crypt 方法，不呼叫 PAM 密碼更換 hooks。 |
| `CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER` | 分別供家目錄／骨架檔擁有者、受限帳號檔、變更屬於新帳號的檔案模式；沒有 SYS_ADMIN、SETUID、SETGID、SYS_CHROOT 或 AUDIT_WRITE。 |
| `PrivateDevices=yes` | socket／復原只需要基本虛擬裝置；TTY unit 改用 `no`，才能開啟真正 controlling tty。 |
| `PrivateTmp=yes` | socket 與 TTY 的暫存隔離；復原 unit 不使用，避免增加早期開機 mount 排序。 |
| kernel／module／log／cgroup／clock 保護 | 帳號工具不需要變更這些資源。 |
| `RestrictNamespaces`、`RestrictRealtime`、`RestrictSUIDSGID`、`LockPersonality`、`MemoryDenyWriteExecute` | 固定原生工具不需要建立 namespace、即時排程、設定 setid bits、改 personality 或 JIT。 |
| `UMask=0077`、`LimitCORE=0` | 限制新增檔案與 core；家目錄另由固定 HOME_MODE 與回讀控制。 |
| socket 交易 `TimeoutStartSec=120s` | 包含讀取與交易。強制終止後依 pending 在下一次啟動／開機復原；不能把逾時當作已回復。TTY 等待人類輸入則不限時。 |

本地 systemd 259.5 的 staged-root verify 只驗證 unit 語法、依賴與執行路徑，沒有啟動服務。user-mode verify 因正式 binary 尚未安裝而回傳 1；staged-root verify 回傳 0，另有拷入的 host dracut symlink 缺少目標警告。**尚未證明 Ubuntu 實際 useradd／chpasswd／userdel 在這組 namespace、capabilities 與映像設定下成功運作**；不能據此宣稱 VM 驗收通過。

## 文字保底

`--tty` 在 controlling `/dev/tty` 顯示英文提示，英文是研究允許的無 DRM 保底限制；不宣稱 Linux console 能顯示中文或提供 fcitx5／Orca。密碼與確認欄停用 ECHO／ECHONL，完成、讀取錯誤與可處理的 INT／QUIT／TERM／HUP 會恢復終端狀態；SIGKILL／斷電只能依 unit 的 TTYReset 與重啟復原。

帳號工具（含 getent）各自離開 tty 前景程序群組，標準 IO 只用 null／pipe，helper 等待並收回工具。pending 寫入後收到終端中斷，交易觀察旗標並延後至一致結束：工具成功則回讀提交、清 pending；工具失敗走既有回復。中斷本身不觸發刪除有密碼帳號；細節見協定的「文字模式的終端中斷」。這不改變 systemd cgroup 停止或強制終止後的保守復原。

已知限制：helper 等待 flock 時，Ctrl-C／Ctrl-\ 不會強制跳出；持鎖的 account／recovery service 仍受既有 120 秒期限約束，systemctl stop 維持可用。本項只記錄，沒有更改鎖或期限。

弱密碼先顯示警告但繼續交易。文字模式目前每次啟動處理一組輸入；驗證失敗後可重啟這個 unit 重試。成功後提示使用新帳密登入。PR B 現以固定 dispatcher／TTY root session 接上無 DRM、失敗重試及後續正式登入入口，靜態／隔離測試不等同 VM 接受；helper 不自行呼叫 login 或啟動工作階段。

## 驗證與已知限制

測試使用 task 自有暫存 root 與注入工具，沒有執行主機 useradd／chpasswd／userdel。故障測試會回讀 passwd／shadow／group 等檔案、家目錄與標記，而不是只相信 helper 回應。另有真 SO_PEERCRED、fd 3 listener、兩個同時的 socket 請求、程序在 useradd 後退出，以及 pseudo-tty 無回顯測試。

```sh
cargo fmt --check
cargo clippy -p ditto-firstboot-account --offline --locked --all-targets -- -D warnings
cargo test -p ditto-firstboot-account --offline --locked
```

顯示名稱採拒絕（不 strip）：除 GECOS 分隔字元與 Cc，亦拒絕 Unicode 17.0 的 Cf／Zl／Zp。分類取自固定的 [UnicodeData.txt](https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt)，僅轉成 21 個範圍；來源雜湊與 Unicode-3.0 散布義務保留在 [UNICODE-NOTICE.txt](../../../crates/ditto-firstboot-account/UNICODE-NOTICE.txt)。沒有新增 crate。系統名稱保留 `systemd-*`、`_*` 前綴與常見系統使用者／群組；密碼 scalar 計數與警告規則詳見協定，PR B 不可用 UTF-16 `length` 取代。

`/var/mail` 保留 tmpfiles 行並採 2775，而不是移除 setgid。測試把正式設定中的 owner IDs 換成 runner 可使用的 UID／GID，在 task 自有 root 以真實 `systemd-tmpfiles --root --create` 套用，再讀回 2775；沒有變更主機的 mail 目錄或帳號。

自有程式碼授權沿用 workspace MIT；上述 Unicode 分類資料保留自己的授權。直接依賴是既有鎖定的 serde 1.0.229、serde_json 1.0.151（只加 raw_value feature）、libc 0.2.189；沒有新增 registry 套件或修改第三方程式碼。libc 用於 peer credentials、flock、termios、signal、啟動 fd 與 process 保護。發行時仍須保留這些依賴及傳遞依賴的 LICENSE／NOTICE。

helper 的鎖只協調自身兩種入口，不能阻止 root 管理員或其他帳號工具同時修改 `/etc`。首次設定期間應禁止其他 root provisioning；不承諾跨帳號工具的分散式原子交易。userdel 若只刪掉 passwd 而留下孤立群組或 home，會回 `internal_rollback_failed` 並保留 pending；不以猜測的 rm／groupdel 擴大刪除範圍。新加入的帳號 hooks、網路 NSS、SELinux 政策或非預設骨架檔可能不符合這組限制。

PR A 的原始碼證據對應 #212 的輸入、交易、協定與日誌驗收；沿用 SEC-01／07／09、REC-04／05 與 AT-14／15／20 的信任、秘密及復原原則，沒有宣稱整個 AT 情境完成。尚待兩個 PR 合併後，在另外準備的可丟棄 VM 驗證：

- socket 交易中途故障時，由真實 userdel 在沙箱內回復並回讀；真實 systemd sandbox 與 shadow-utils、`getent`、yescrypt、sudo、home 0750、完成標記及 journal 密碼掃描。
- GPU、pixman、無 DRM／TTY 的啟動與失敗重試；真 greetd 的 `_greetd` peer 與 socket 拒絕一般使用者。
- 純鍵盤建立後經 PAM 直接進桌面、中文顯示名稱／fcitx5、Orca 每個欄位與錯誤。
- 重開機改走登入；useradd 後、chpasswd 前強制斷電，下一次開機先復原、再重新呈現建立畫面；chpasswd 後、標記前斷電則確認保留帳號並拒絕新建；標記後、pending unlink 前斷電則補清 pending，之後刪標記仍不能替換管理員。
- 復原 unit 的 namespace／tmpfiles 啟動失敗仍不阻止既有 greetd 登入；首次設定失敗則需在 tty1 提供可理解說明。
- F7 後續強化：`SystemCallArchitectures=native`、`SystemCallFilter=@system-service`、`ProtectHostname=yes` 暫不加入；須先在 VM 驗證 useradd、chpasswd、userdel 及回復仍可運作。
