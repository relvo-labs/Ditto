# 整碟安裝器（#221）

這是 #221 ISO 預覽版安裝器的原始碼：寫入核心、root 後端服務與協定、繁中圖形畫面與英文文字畫面、installer 映像設定（`generate.py --profile installer`）、payload 抽取與 builder 專用的 `assemble-iso`。**目前還沒有建出任何 ISO 或 installer 映像，也沒有在 builder、VM 或實體機執行過**；下文的「組裝」與「待驗證」是計畫。使用者安裝說明見 [docs/install/iso-preview.md](../../../docs/install/iso-preview.md)。

範圍依 owner 2026-10-26 決定（[#152 留言](https://github.com/relvo-labs/Ditto/issues/152#issuecomment-6414217695)）：選一整顆磁碟、二次確認、寫入隨附且驗過 hash 的 Ditto 映像、讀回核對、拔除媒體後重開機，首次開機走 #212 的建帳號畫面。不做 live 桌面、雙系統、保留分割區或 LUKS；Secure Boot 須由使用者關閉。

## 安裝器做什麼、不做什麼

安裝器只把 [Ubuntu 配方](../ubuntu/README.md) 產出、已通過 finish 與 pristine scan 的 `out/ditto.raw` 各分割區位元組寫到目標磁碟，再寫一份新的 GPT。它**不掛載、不修改**目標上的檔案系統，不建立帳號、不寫 machine-id、SSH host key 或 random seed。因此安裝結果的 OEM 身分狀態，等於 payload 來源映像的 pristine scan 結果；GPT 的 disk／partition GUID 每次安裝隨機產生。

`ditto-state` 分割區設成填滿磁碟剩餘空間，裡面仍是 8 GiB 的 ext4；首次開機由映像 `/etc/fstab` 的 growfs 項目線上擴展（見 Ubuntu 配方 #221 一節）。ESP、`/usr` 槽與空槽維持映像原大小與順序。

## 開機鏈與安裝環境

- ISO 是 UEFI-only 的 hybrid 映像。El Torito EFI 映像同時以 GPT 分割區 2（ESP）附在 ISO 後面，所以同一個檔案可以燒光碟，也可以 `dd` 到隨身碟。ESP 只有 `EFI/BOOT/BOOTX64.EFI`，就是 installer UKI；沒有 systemd-boot、loader 設定或 BIOS 開機路徑。
- installer 映像以 mkosi `Format=uki` 建置：整個系統是這個 UKI 的 initrd，從 RAM 執行，不做 switch-root（finalize 拒絕含 `etc/initrd-release` 的結果）。選它而不是「initrd 找到媒體上的 erofs 再掛為 root」，是因為後者要在 initrd 自訂以 label 找 iso9660、loop 掛載 root 檔案與 overlay 的步驟，無法在本機測試。
- 媒體只用來讀 payload：後端等待 `/dev/disk/by-label/<ISO label>`，以固定 argv 唯讀掛載 iso9660，並把該裝置排除為安裝目標。
- 與已安裝系統的差異：同一 snapshot、kernel、Mesa、Quickshell／Wayfire runtime；installer 只帶顯示相關 firmware 分包（AMD／Intel／NVIDIA graphics 與 AMD／Intel misc），不帶完整 `linux-firmware`、greetd、首次帳號流程、SSH、音效、portal 或 Orca。
- 身分：machine-id 為空、root 鎖定、沒有 SSH；只有 sysusers 建立的鎖定系統使用者 `ditto-installer`（前端身分，沒有密碼與登入 shell）。

## 程序與權限

| 程序 | 身分 | 內容 |
| --- | --- | --- |
| `ditto-installer-backend.service` | root | 唯一的寫入者：找媒體、核對 payload、列出磁碟、寫入與讀回。`/run/ditto-installer/backend.sock`（0660，群組 `ditto-installer`）；每條連線先以 `SO_PEERCRED` 核對前端 UID，不符即回 `peer_rejected` 並關閉，不讀任何請求。`Restart=no`：中斷的寫入不會被重啟後的空白狀態掩蓋 |
| `ditto-installer-ui.service` | `ditto-installer` | tty1、`PAMName=ditto-installer`（只有 account／session 堆疊，給 Wayfire 一個 logind 座位工作階段）。`wait-drm` 最多等 30 秒；之後 GPU Wayfire＋Quickshell → pixman／Qt software → 英文文字畫面 |

協定是一行一個 JSON，固定動作：`state`（含進度與結果）、`list`、`select`、`back`、`confirm`、`cancel`、`reboot`。前端只能回傳後端發出的不透明 token，不能指定路徑、偏移、payload 檔或命令。`confirm` 會重新列舉並比對磁碟身分後直接開始寫入，沒有「已確認但未開始」的中間狀態。失敗或取消後可以回到磁碟清單；成功後只能重新開機。寫入中不接受重新開機。

## 模組

| 檔案 | 內容 |
| --- | --- |
| `ditto_installer/disks.py` | 由 sysfs 列出實體整碟與排除原因 |
| `ditto_installer/manifest.py` | payload 清單嚴格解析、內嵌 SHA256 綁定、寫入前完整核對 |
| `ditto_installer/layout.py`、`gpt.py` | 目標佈局與最小容量；512-byte 磁區 GPT 讀寫 |
| `ditto_installer/writer.py` | 寫入、讀回、最後提交 GPT |
| `ditto_installer/session.py` | 列出 → 選擇 → 二次確認 → 安裝的狀態機 |
| `ditto_installer/protocol.py`、`backend.py`、`service.py` | 協定、root 後端與正式接線 |
| `ditto_installer/medium.py` | 以固定 ISO label 找媒體、唯讀掛載 |
| `ditto_installer/client.py`、`textui.py` | 前端連線與英文文字畫面 |
| `ditto_installer/messages.py` | 原因與結果代碼的繁中／英文文案（`shell/installer/InstallerMessages.qml` 的繁中內容與它相同，由測試比對） |
| `ditto_installer/payload.py`、`make-payload.py` | builder 專用：從 finish 後的整碟映像依 GPT byte range 切出 payload 與清單 |
| `image/` | installer 映像內的啟動器、畫面 wrapper、Wayfire 設定、PAM、systemd units、sysusers |
| `assemble-iso` | builder 專用：組 ISO 與 `SHA256SUMS` |
| [`shell/installer/`](../../../shell/installer) | 繁中 Quickshell 畫面，沿用 Shell 的 Jelly 元件與 i18n 目錄 |

## 選碟規則

只列 `/sys/block` 下有 `device` 的整碟，略過 loop、ram、zram、dm、md、sr、nbd、fd、mtdblock 與 eMMC boot／rpmb。以下磁碟列出但不能選，並帶原因：安裝媒體所在磁碟、使用中（掛載、swap、holders）、唯讀、可移除、4K 原生磁區、容量不足、資訊讀不到。型號、廠商與序號是裝置提供的資料，只做顯示：移除不可列印字元、最多 64 字元。

確認時重新列舉並比對名稱、major:minor、容量、邏輯磁區大小、型號、廠商、序號、removable、ro；不同就回到列表。寫入時以 `O_EXCL|O_NOFOLLOW` 開啟目標，核心會拒絕已掛載或被占用的區塊裝置；再比對 `st_rdev` 與 `BLKGETSIZE64`。正式路徑只接受區塊裝置。

## 寫入順序與失敗語意

1. 完整核對每個 payload 檔（型態、大小、SHA256）。此前沒有任何寫入。
2. 規劃佈局、開啟並核對目標。
3. 清除舊分割表（頭尾各 1 MiB）。從這一步起，磁碟原有資料不再能經分割表存取。
4. 逐區解壓寫入，同時核對原始長度與 SHA256；超出分割區長度前就停止。空槽頭尾 1 MiB 清零。zstd 只從已開啟、確認為一般檔案的描述元讀取。
5. `fsync` 後重新開啟同一個物件讀回比對 SHA256（區塊裝置先 `BLKFLSBUF`，再以 `O_DIRECT` 讀）。
6. 寫入新 GPT，並讀回、核對主表與備份表。

六步都成立才回報成功。第 3 步之後的失敗或取消是 `partially_written`：因為 GPT 最後才寫，這種磁碟不會開機。第 3 步之前一律是 `untouched`。清除不是安全抹除。

## builder 組裝（計畫，尚未執行）

完整指令列在 turn 2 交接紀錄；順序是：

1. 以本分支重建 normal 映像並跑 `finish-image.sh`（含 pristine scan），保留 `out/disk.sha256`。
2. `make-payload.py` 切 payload，記下清單 SHA256。
3. `generate.py --profile installer --payload-manifest-sha256 <第 2 步> --medium-label DITTO_INSTALL_<版本>`，以 mkosi 建 installer UKI；finalize 會以 runtime policy 套用 Quickshell／Wayfire 子集。
4. `assemble-iso --installer-uki … --installer-build … --payload … --version … --source-date-epoch … --output …`：交叉核對 UKI、installer 設定與 payload 後，以 mkfs.vfat／mtools 建 ESP、以 xorriso 組 ISO，並寫 `SHA256SUMS` 與 `assembly.json`。

## 本機測試

```sh
python3 packaging/distro/installer/tests/test_installer.py
python3 packaging/distro/installer/tests/test_backend.py
python3 packaging/distro/installer/tests/test_assemble.py
python3 packaging/distro/installer/tests/test_ui_wrapper.py
python3 packaging/distro/installer/tests/test_qml.py   # 需要 Qt 6.10.2（QT_PREFIX）才跑 qmltestrunner
```

只使用 task 自有的稀疏一般檔案、假 sysfs、暫存目錄中的 Unix socket、記錄型的工具替身與 #212 的 Quickshell stubs；不開啟任何區塊裝置、loop 或掛載，不需要 root。`sfdisk --json／--verify` 作為獨立讀者核對寫出的 GPT。這些測試**不能**證明真實區塊裝置的 `O_EXCL`、`O_DIRECT`、`BLKFLSBUF`、`BLKRRPART`，也不能證明 mkosi `Format=uki`、PAM／logind 座位、Wayfire 在實體 GPU 的行為、growfs 或開機。

## 已知限制與待驗證

- 尚未建出 ISO 或 installer UKI。mkosi `Format=uki` 的實際行為、installer 的 RAM 需求與 UKI 大小、大型 El Torito FAT 映像在光碟開機的相容性、`PAMName=` 給 Wayfire 的座位工作階段、installer 的 ELF 依賴閉包，都要在 builder／VM 確認。
- 只支援 UEFI x86_64 與 512-byte 邏輯磁區；可移除式裝置（含 USB 隨身碟）不列為目標。
- 清單 SHA256 綁定安裝器與同一媒體上的 payload，是完整性檢查，不是簽章；真實性依 GitHub pre-release 的 `SHA256SUMS`。
- 清除不是安全抹除；檔案系統 UUID 來自固定 mkosi Seed，所有安裝相同，只有 GPT GUID 隨機。
- 安裝環境不含 Orca；畫面有 AT-SPI 名稱與文字狀態，但螢幕閱讀器流程未驗證。文字畫面只有英文。
- VM 須驗：ISO 以 USB 與光碟開機、安裝、離線回讀（machine-id 為空、無 host key、無 ESP／rootfs seed、無人員帳號、對安裝結果重跑 pristine scan）、首次開機 growfs、#212 建帳號、PAM 登入；負例含 payload 一個 byte 損毀、目標太小、確認畫面取消、寫入中取消、無 DRM。
