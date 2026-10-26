# 整碟安裝器（#221，進行中）

這是 #221 ISO 預覽版安裝器的原始碼：後端核心、root 後端服務與協定、英文文字前端、installer 映像設定（`generate.py --profile installer`）、payload 抽取與 builder 專用的 `assemble-iso`。**還沒有建出任何 ISO 或 installer 映像，也沒有在 builder 或 VM 執行過**；下列「組裝」與「待驗證」兩節是計畫。繁中圖形畫面尚未加入。範圍依 owner 2026-10-26 決定（[#152 留言](https://github.com/relvo-labs/Ditto/issues/152#issuecomment-6414217695)）：選一整顆磁碟、二次確認、寫入隨附且驗過 hash 的 Ditto 映像、讀回核對、拔除媒體後重開機，首次開機走 #212 的建帳號畫面。不做 live 桌面、雙系統、保留分割區或 LUKS；Secure Boot 須由使用者關閉。

## 安裝器做什麼、不做什麼

安裝器只把 [Ubuntu 配方](../ubuntu/README.md) 產出、已通過 finish 與 pristine scan 的 `out/ditto.raw` 各分割區位元組寫到目標磁碟，再寫一份新的 GPT。它**不掛載、不修改**目標上的檔案系統，不建立帳號、不寫 machine-id、SSH host key 或 random seed。因此安裝結果的 OEM 身分狀態，等於 payload 來源映像的 pristine scan 結果；GPT 的 disk／partition GUID 每次安裝隨機產生。

`ditto-state` 分割區會設成填滿磁碟剩餘空間，裡面仍是 8 GiB 的 ext4；首次開機由映像 `/etc/fstab` 的 growfs 項目線上擴展（見 Ubuntu 配方 #221 一節）。ESP、`/usr` 槽與空槽維持映像原大小與順序。

## 模組

| 檔案 | 內容 |
| --- | --- |
| `ditto_installer/disks.py` | 由 sysfs 列出實體整碟與排除原因；sysfs、mountinfo、swaps、安裝媒體的 major:minor 都可注入 |
| `ditto_installer/manifest.py` | payload 清單的嚴格解析；清單位元組須符合安裝器內嵌的 SHA256；寫入前完整核對每個 payload 檔 |
| `ditto_installer/layout.py` | 目標佈局與最小容量 |
| `ditto_installer/gpt.py` | 512-byte 磁區的 GPT 讀寫（含 CRC 與備份表核對） |
| `ditto_installer/writer.py` | 寫入、讀回、提交 GPT |
| `ditto_installer/session.py` | 列出 → 選擇 → 二次確認 → 安裝的狀態機 |
| `ditto_installer/messages.py` | 原因與結果代碼的繁中／英文文案 |
| `ditto_installer/payload.py`、`make-payload.py` | builder 專用：從 finish 後的整碟映像依 GPT byte range 切出 payload 與清單 |
| `ditto_installer/protocol.py`、`backend.py`、`service.py` | root 後端：Unix socket、`SO_PEERCRED` 只接受固定前端 UID、一行一個 JSON 的固定動作 |
| `ditto_installer/medium.py` | 以固定 ISO label 找安裝媒體、固定 argv 唯讀掛載，並回報要排除的裝置 |
| `ditto_installer/client.py`、`textui.py` | 前端連線與英文文字畫面（無 DRM 時使用） |
| `image/` | installer 映像內的啟動器、systemd units 與 sysusers |
| `assemble-iso` | builder 專用：組 UEFI hybrid ISO 與 `SHA256SUMS` |

後端是唯一權威。畫面只送固定動作：列出、以隨機 token 選擇、以確認畫面發出的一次性 token 確認、取消；不能指定路徑、偏移或 payload 檔。

## 選碟規則

只列 `/sys/block` 下有 `device` 的整碟，略過 loop、ram、zram、dm、md、sr、nbd、fd、mtdblock 與 eMMC boot／rpmb。以下磁碟列出但不能選，並帶原因代碼：

- `install_medium`：安裝媒體所在的磁碟（以媒體掛載點的 major:minor 對應到整碟或其分割區）。
- `in_use`：整碟或分割區已掛載、作為 swap，或有 holders（LVM、RAID、dm）。
- `read_only`、`removable`、`too_small`（小於清單算出的最小佈局）。
- `unsupported_sector_size`：邏輯磁區不是 512 bytes（4K native）；預覽版不支援。
- `unreadable`：sysfs 資訊讀不到。

型號、廠商與序號是裝置提供的資料，只做顯示：移除不可列印字元、合併空白、最多 64 字元。序號依序讀 `serial`、`device/serial`、SCSI VPD 0x80。

確認時重新列舉並比對名稱、major:minor、容量、邏輯磁區大小、型號、廠商、序號、removable、ro；不同就回到列表（`disk_changed`），不寫入。寫入時以 `O_EXCL|O_NOFOLLOW` 開啟目標，核心會拒絕已掛載或被占用的區塊裝置；再比對 `st_rdev` 與 `BLKGETSIZE64`。正式路徑只接受區塊裝置；一般檔案只在測試明確傳入 `allow_regular_file=True` 時接受。

## 寫入順序與失敗語意

1. 完整核對每個 payload 檔（型態、大小、SHA256）。此前沒有任何寫入。
2. 規劃佈局、開啟並核對目標。
3. 清除舊分割表（頭尾各 1 MiB）。從這一步起，磁碟原有資料不再能經分割表存取。
4. 逐區解壓寫入，同時核對原始長度與 SHA256；超出分割區長度前就停止，不寫到下一個分割區。空槽頭尾 1 MiB 清零。zstd 只從已開啟並確認為一般檔案的描述元讀取，不接收路徑。
5. `fsync` 後讀回每個寫入區域比對 SHA256（區塊裝置先 `BLKFLSBUF`，再以 `O_DIRECT` 讀）。
6. 寫入新 GPT，並以同一解析器讀回、核對主表與備份表。

六步都成立才回報 `succeeded`／`installed`。第 3 步之後的失敗或取消會回報 `partially_written`；因為 GPT 最後才寫，這種磁碟不會開機，可以重新安裝。第 3 步之前的失敗或取消一律是 `untouched`，並以位元組雜湊驗證。清除不是安全抹除：未被新內容覆蓋的區域可能仍留有舊資料。

## builder 組裝（計畫，尚未執行）

1. 以本分支重建 normal 映像並跑 `finish-image.sh`（含 pristine scan），保留 `out/disk.sha256`。
2. `python3 packaging/distro/installer/make-payload.py --disk out/ditto.raw --disk-sha256 <disk.sha256> --image-version <版本> --source-commit <commit> --output <新目錄>`，取得清單 SHA256。
3. `generate.py --profile installer --payload-manifest-sha256 <第 2 步> --medium-label DITTO_INSTALL_<版本>` 後以 mkosi 建 installer UKI（`Format=uki`，整個 installer 在 initrd，從 RAM 執行）。
4. `assemble-iso` 以 xorriso／mtools／dosfstools 組 UEFI-only hybrid ISO：El Torito 與 GPT 分割區 2 是同一個 FAT 映像，只含 `EFI/BOOT/BOOTX64.EFI`（installer UKI）；ISO 9660 內是 `ditto/payload/`。

## 本機測試

```sh
python3 packaging/distro/installer/tests/test_installer.py -v
```

只使用 task 自有的稀疏一般檔案與假 sysfs 目錄；不開啟任何區塊裝置、loop 或掛載，不需要 root。需要 `sfdisk` 與 `zstd`：`sfdisk --json`／`--verify` 作為獨立讀者核對寫出的 GPT。測試涵蓋選碟原因、清單嚴格解析、payload 損毀／缺漏／symlink／FIFO、目標太小與身分改變、寫入前後取消、寫入／讀回／提交故障注入、解壓超長與解壓失敗，以及狀態機的 token。這些測試**不能**證明真實區塊裝置的 `O_EXCL`、`O_DIRECT`、`BLKFLSBUF`、`BLKRRPART` 行為，也不能證明 growfs 或開機。

## 已知限制與待驗證

- 尚未建出 ISO 或 installer UKI；繁中圖形畫面尚未加入。mkosi `Format=uki` 的行為、installer 的 RAM 需求與 UKI 大小、大型 El Torito FAT 映像在光碟開機的相容性，都要在 builder／VM 確認。
- 只支援 UEFI x86_64 與 512-byte 邏輯磁區；可移除式裝置不列為目標。
- 清單 SHA256 綁定安裝器與同一媒體上的 payload，是完整性檢查，不是簽章；真實性依 GitHub pre-release 的 `SHA256SUMS`。
- 檔案系統 UUID 來自固定 mkosi Seed，所有安裝相同；只有 GPT GUID 隨機。交 #152 後續處理。
- VM 須驗：ISO 以 USB 與光碟開機、安裝、離線回讀（machine-id 為空、無 host key、無 ESP／rootfs seed、無人員帳號、可對安裝結果重跑 pristine scan）、首次開機 growfs、#212 建帳號、PAM 登入；負例含 payload 一個 byte 損毀、目標太小、確認畫面取消、寫入中取消、無 DRM。
