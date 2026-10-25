# 首次開機建立帳號：原生 helper

這是 #212 的 PR A：建立第一個管理員帳號的 Rust helper、socket、開機復原與文字保底 units。協定在 [PROTOCOL.md](../../../crates/ditto-firstboot-account/PROTOCOL.md)；PR B 負責畫面、greeter、無 DRM 的啟動選擇及映像接線。本目錄尚未接入映像配方。

## 流程與安裝位置

沒有 UID_MIN..UID_MAX 內的人員帳號時，greeter 送一筆請求給 root helper。helper 回讀確認帳號與完成標記後回應成功；greeter 再用剛輸入的密碼走 greetd／PAM 正式登入。這不是自動登入，也不預埋帳號。不使用 `ConditionFirstBoot` 或 machine-id 判定。

| 來源 | 預期安裝位置／啟動 |
| --- | --- |
| `cargo build --release -p ditto-firstboot-account --locked` 的 binary | `/usr/lib/ditto/ditto-firstboot-account`，root 擁有、0755，放在唯讀 `/usr` |
| `units/*.service`、`units/*.socket` | `/usr/lib/systemd/system/` |
| `tmpfiles.d/ditto-firstboot.conf` | `/usr/lib/tmpfiles.d/ditto-firstboot.conf` |
| `ditto-firstboot-account.socket` | 映像階段啟用到 `sockets.target` |
| `ditto-firstboot-account-recover.service` | 映像階段啟用；建立 `sysinit.target.wants` 與 `greetd.service.requires` 連結 |
| `ditto-firstboot-account-tty.service` | 只在無 DRM 的 root 啟動路徑按需啟動，不預設啟用；與 greetd、getty@tty1 互斥 |

tmpfiles 建立 `/run/ditto`、root 擁有的 `/var/lib/ditto/firstboot`（0700）及 `/var/mail`。`/etc`、`/home`、`/var/lib/ditto`、`/var/mail` 必須位於可寫的共用狀態分割區；`/usr` 回退不刪除帳號。PR B 須保證 pristine 映像沒有 `pending` 或 `account-created`。

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

`--no-log-init` 避免寫入 `/var/log/lastlog`／faillog；HOME_MODE 固定為 0750。指定 YESCRYPT 讓 chpasswd 走 libcrypt 而非 PAM 密碼品質拒絕，符合 owner「弱密碼警告但允許」的政策；登入仍走 greetd／PAM。帳號工具採清空後的固定環境，stdout／stderr 不輸出。密碼只透過 chpasswd stdin 傳遞，不放 argv、環境、journal、pending 或完成標記。

helper 日誌只有 `phase=<階段> result=<結果>`，不包含帳號、顯示名稱、密碼或原始錯誤。請求與密碼配置用 volatile writes 清除完整 allocation，關閉 core dump。password 使用借用的 JSON RawValue，再解碼到可清零的緩衝，避免 serde_json 的 escape scratch 留下密碼；解析完即清除原始請求。這不能保證清除 kernel socket／pipe、swap、帳號工具、Qt／JS 或 CPU／allocator 之外的所有副本；正式 VM 仍須掃描 journal。

## 交易與復原

1. 取得 `/var/lib/ditto/firstboot/lock` 的排他 flock；檢查狀態目錄及其祖先由 root 擁有、沒有不安全的群組／其他人寫入權限，並拒絕符號連結。文字與 socket 入口共用這一條交易。
2. 若 `pending` 存在且沒有完成標記，先解析版本與安全帳號名稱，執行 userdel 並回讀移除。無法解析時不猜測、不刪除帳號，復原 unit 失敗並阻止 greetd 繼續。
3. 重查完成標記、UID 範圍、沒有任何人員帳號，以及輸入與名稱衝突。
4. 以暫存檔 → fsync → rename → 目錄 fsync 寫入 `pending`；只有這一步成功後才執行 useradd。
5. 建立帳號並設定密碼；回讀 passwd 的 UID、主要 GID、GECOS、固定 shell／home、shadow 的 `$y$` 前綴、同名主要群組、sudo 成員、家目錄的型態／0750／擁有者。同步帳號檔與父目錄後，才寫完成標記。
6. 完成標記同樣以暫存 → fsync → rename → 目錄 fsync 提交，再刪 pending 並同步目錄。提交後 pending 清理失敗會記為 deferred；已提交標記優先，不能刪除完成的帳號。
7. 提交前失敗則清除可能已 rename 的完成標記、呼叫 userdel -r，回讀 passwd、shadow、group、gshadow、subuid、subgid、home、mail。全部不存在並同步帳號檔與父目錄後，才清 pending 並回 `internal_rolled_back`；任何殘留或讀取失敗則保留 pending、回 `internal_rollback_failed`。

兩種紀錄的 v1 格式相同；沒有密碼或顯示名稱：

```json
{"version":1,"username":"alice","timestamp":1792960000}
```

`timestamp` 是 Unix seconds。未知 pending 版本會停止復原；任何完成標記存在都會阻止新交易。A/B 兩邊須維持這個格式，不能以切換 `/usr` 當作帳號回復方式。root 修復前應保留紀錄；不能只刪 pending／完成標記來掩蓋殘留。

復原 unit 使用 `DefaultDependencies=no`，在 local-fs 與 tmpfiles 後、sysinit／sockets／greetd 前完成，避免「socket 等待 recovery，而 recovery 等待 basic.target」的排序循環。socket Requires recovery；啟用 recovery 後 greetd 也 Requires 它。每次交易還會再次檢查 pending，因此同一次開機的重試也會先復原。

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

`--tty` 在 controlling `/dev/tty` 顯示英文提示，英文是研究允許的無 DRM 保底限制；不宣稱 Linux console 能顯示中文或提供 fcitx5／Orca。密碼與確認欄停用 ECHO／ECHONL，完成、讀取錯誤與可處理的 INT／TERM／HUP 會恢復終端狀態；SIGKILL／斷電只能依 unit 的 TTYReset 與重啟復原。

弱密碼先顯示警告但繼續交易。文字模式目前每次啟動處理一組輸入；驗證失敗後可重啟這個 unit 重試。成功後提示使用新帳密登入。PR B 仍須接上無 DRM 偵測、失敗重試及後續正式登入入口；helper 不自行呼叫 login 或啟動工作階段。

## 驗證與已知限制

測試使用 task 自有暫存 root 與注入工具，沒有執行主機 useradd／chpasswd／userdel。故障測試會回讀 passwd／shadow／group 等檔案、家目錄與標記，而不是只相信 helper 回應。另有真 SO_PEERCRED、fd 3 listener、兩個同時的 socket 請求、程序在 useradd 後退出，以及 pseudo-tty 無回顯測試。

```sh
cargo fmt --check
cargo clippy -p ditto-firstboot-account --offline --locked --all-targets -- -D warnings
cargo test -p ditto-firstboot-account --offline --locked
```

授權沿用 workspace MIT。直接依賴是既有鎖定的 serde 1.0.229、serde_json 1.0.151（只加 raw_value feature）、libc 0.2.189；沒有新增 registry 套件或修改第三方程式碼。libc 用於 peer credentials、flock、termios、signal、啟動 fd 與 process 保護。發行時仍須保留這些依賴及傳遞依賴的 LICENSE／NOTICE。

helper 的鎖只協調自身兩種入口，不能阻止 root 管理員或其他帳號工具同時修改 `/etc`。首次設定期間應禁止其他 root provisioning；不承諾跨帳號工具的分散式原子交易。userdel 若只刪掉 passwd 而留下孤立群組或 home，會回 `internal_rollback_failed` 並保留 pending；不以猜測的 rm／groupdel 擴大刪除範圍。新加入的帳號 hooks、網路 NSS、SELinux 政策或非預設骨架檔可能不符合這組限制。

PR A 的原始碼證據對應 #212 的輸入、交易、協定與日誌驗收；沿用 SEC-01／07／09、REC-04／05 與 AT-14／15／20 的信任、秘密及復原原則，沒有宣稱整個 AT 情境完成。尚待兩個 PR 合併後，在另外準備的可丟棄 VM 驗證：

- 真實 systemd sandbox 與 shadow-utils、`getent`、yescrypt、sudo、home 0750、完成標記及 journal 密碼掃描。
- GPU、pixman、無 DRM／TTY 的啟動與失敗重試；真 greetd 的 `_greetd` peer 與 socket 拒絕一般使用者。
- 純鍵盤建立後經 PAM 直接進桌面、中文顯示名稱／fcitx5、Orca 每個欄位與錯誤。
- 重開機改走登入；useradd 後、標記前強制斷電，下一次開機先復原、再重新呈現建立畫面。
