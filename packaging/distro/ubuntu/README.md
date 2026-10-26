# Ubuntu 映像配方

本目錄是從 2026-10-24 Ubuntu 桌面 UAT 抽取的 mkosi 配方，尚未從 repo 路徑重建出通過驗收的映像，不是可發行映像。架構與責任見[雙形式 ADR](../../../docs/platform/distro-architecture.md)，來源與驗證範圍見 [D-51 §依據](../../../.agents/notes/decisions/2026-10-24-d51-ubuntu-mkosi-base.md#依據)。

原 run 建出 `ditto-uat-ubuntu.raw`，SHA256 為 `ee181cd8ee3f2a7a2b2d7fabf270865f67352d771645b6c53c4b2d01890a321d`。去除測試配置後，repo 配方不會產出相同 hash；該 hash 只識別抽取來源。原 run source 是 `48593c3383353e25f07b6f247ae834cb92064911`、archive SHA256 `a5ae33292e8398f4fa65375fd8aeaf87fdabb1ac5baba3cbbf4163b6707b2b2d`，未含 #185；本分支從含 #185／#186 的基準開始，未重建的差異不能算作已驗證。

## 最短建置路徑

在另行準備的可丟棄 Ubuntu 26.04 amd64 builder 執行，使用 mkosi `26-3`、Python ≥3.12、bash、util-linux、systemd-boot（builder 的 `bootctl` 須 ≥257）、dpkg、tar。需要 root 的 mkosi／loop mount 僅在該 builder 內執行。這裡不建立 builder、啟動測試環境或下載私人 cache。

先備妥兩項輸入：

1. `git archive` 格式的來源 tarball（repository 路徑位於 tar root），已獨立核對的 source commit 與 SHA256。
2. 同來源、同 snapshot 建置的 runtime tree，路徑見下節。D04 負責產出、來源核對與授權材料；此配方不含端到端 runtime bootstrap。`lock-runtime.py` 只計算雜湊，不證明輸入可信，也不執行 tree 裡的程式。

從 repo 根目錄設定輸入後：

```sh
recipe="$PWD/packaging/distro/ubuntu"
source_tar=/srv/ditto-input/source.tar
runtime_tree=/srv/ditto-input/runtime
source_commit="$(git get-tar-commit-id < "$source_tar")"
source_sha="$(sha256sum "$source_tar" | cut -d' ' -f1)"
build_dir=/var/tmp/ditto-image-1
snapshot=20261020T000000Z
# source_commit/source_sha 必須先與可信輸入紀錄比對，不能只信檔名。
python3 "$recipe/lock-runtime.py" --runtime-tree "$runtime_tree" \
  --source-commit "$source_commit" --source-sha256 "$source_sha" \
  --snapshot "$snapshot" > /var/tmp/ditto-runtime-lock.json
python3 "$recipe/generate.py" --source-tar "$source_tar" \
  --source-commit "$source_commit" --source-sha256 "$source_sha" \
  --runtime-tree "$runtime_tree" --runtime-lock /var/tmp/ditto-runtime-lock.json \
  --snapshot "$snapshot" --version 1 --output "$build_dir"
(cd "$build_dir" && sudo timeout 3600s mkosi --force build)
sudo timeout 120s bash "$recipe/finish-image.sh" "$build_dir" --forbid "$PWD"
```

`--output` 必須不存在；用新目錄建立下一版。source tar 的獨立可信 hash 不符、PAX comment 與宣告 commit 不符、runtime 缺檔／digest 不符、pin／snapshot 不一致即停止。PAX comment 只是 archive 的身分一致性檢查，可被偽造；不取代可信來源與獨立核對的 digest。mkosi 套件取得需可用的 snapshot mirror 或預載 cache；本輪沒有執行這一步。`packages.txt` 的 kernel 與 snapshot 是 PoC 鎖；變更 snapshot 時 D02／D04 必須一起核對 kernel／Qt／runtime lock，不代表可任意替換。

成品在 `out/ditto.raw`，另有 mkosi JSON manifest／split partitions／UKI、`packages.tsv`、`pristine-scan.json`、`boot-tool-versions.txt` 與 `disk.sha256`。版本紀錄包含 builder 的 `bootctl --version` 與由映像 dpkg DB 回讀的 systemd 套件版本；`bootctl --root` 仍執行 builder 的 binary。finish 步驟會修改 ESP 安裝 fallback EFI，**以完成後 disk hash 為準**；不要使用完成前 mkosi disk checksum 對外發布。每版 lock 同存於映像 `/usr/share/ditto/`。

## Runtime tree 與來源責任

tree 以映像 root 為起點，只接受 `generate.py` 列舉的路徑與 lock 中的檔案，不複製整台 builder。所有 regular files 必須列 SHA256；symlink 另列 target，可經多個已列入 lock 的 symlink 抵達同 lock 的 regular file。每一跳都限於 admitted image paths，拒絕循環、未列目標、越界與 parent symlink。

| 輸入位置 | 來源／建置要求 |
| --- | --- |
| `usr/lib/ditto/target/release/` | 必備 Core、worker、confine、supervisor、dittoctl、test-host、D-Bus proxy、固定 generation runner；含 #213 的來源另須 firstboot-account helper；native 依 `rust-toolchain.toml`／Cargo.lock 建置，以 compiler path remap（例如 rustc `--remap-path-prefix`）把 source、Cargo registry、toolchain 與建置目錄映射為中性路徑，保留固定 runner 的 Qt pkg-config 建置路徑 |
| `usr/lib/ditto/packages/{host-runtime,agent-runtime}/dist/` | 同 source 的 pnpm frozen-lockfile bundle；保留 bundle 的上游 notice |
| `usr/lib/ditto/target/ditto-packages/` | `scripts/build-builtin-packages.sh` 的正式包；不得加入驗證 relay 或故障夾具 |
| `usr/bin/quickshell`、`usr/bin/wayfire`、指定 Wayfire libraries／plugins、`usr/share/wayfire/` | 固定 Quickshell rev `1a4716c…`、Wayfire `d399023…`；系統 libdir 只接受 `libwf-{config,utils,touch,json}.so*`、`libwlroots-0.20.so*` 的數字版本及 Wayfire plugin `.so`，不接受 libc／Qt 等其他 distro libraries；編譯時用中性 source 路徑。Wayfire lock 來源為 `packaging/reference-image/source-builds.lock`，相依版本若調整須在 D04 明列 |
| `usr/local/libexec/xdg-desktop-portal-wlr` | repo `tools/xdpw/pin.json` 加既有 patches；D-Bus proxy 同理依 `tools/dbus-proxy/pin.json`，不自行抓浮動版本 |
| `usr/lib/ditto-node/bin/node` | Node 22.23.2；官方來源／hash 與 Node 的第三方授權材料另核對 |
| `usr/share/doc/ditto-runtime/` | 必備 source provenance、各元件 LICENSE／NOTICE、修改清單；至少有檔案不代表法律盤點完成，D11 須逐項審查 |

所有 native 產物都必須用 compiler path remap 或中性來源／建置路徑編譯，輸出不得含具名 home、checkout、`agent-runs`／`worktrees`／`ditto-runs`／`cache/scratch` 等 producer 路徑。是否做到，由新映像的 pristine scan 對實際輸出 bytes 判定；只提供 remap 指令或建置旗標不算證明。不得修改既有 binary 字串、偽造 Git identity，也不得把自有產物的 hash 登錄成公開例外。scanner 的 producer 規則對自有產物沒有例外：#205 第一輪的 `ditto-core`、`dittoctl`、`ditto-test-host`、`ditto-worker` 命中，須以 remap 重建解決。

`runtime_policy.py` 同時供 lock generation、generator、apply 與 finish audit 使用。runtime 不透過 ExtraTrees 覆寫套件：先 stage 在 generated project 的 `runtime/`，finalizer 以 `dpkg-query --admindir=$BUILDROOT/var/lib/dpkg` 檢查全部路徑（包含 link）。target 的 merged-/usr 等別名依映像內實際 parent symlink 解析，再比對 target package 歸屬；獨立的實體 `/bin` 不會直接視為 `/usr/bin`。任一已被套件擁有或 query 異常（含逾時）即以 exit 2 拒絕，全部通過才 copy；既有 regular-file 目的地的 `st_nlink > 1` 也在任何 copy 前拒絕，避免改寫共用的套件 inode。finish 再對 mounted target DB 與實際 payload hashes 做唯讀 audit。這些查詢不讀 builder 的預設 dpkg DB；preflight 拒絕不得被忽略。真實映像的 catalog 查詢耗時尚待 #148／#151 重建時量測，#199 保留該項驗收。

套件預檢允許缺少 `updates/`；存在時必須是真實目錄，並以 `lstat` 檢查所有直接 journal entries，在任何 dpkg 查詢前拒絕 symlink（包含懸空或循環）與非 regular file（例如目錄、FIFO），不遞迴追蹤。正常的 regular numeric journal 仍可使用。預檢也在任何 dpkg 查詢前要求存在的 `arch`、`triggers/File`、`triggers/Unincorp` 為 regular file、`triggers/` 為真實目錄（均拒絕 symlink，允許缺少），但這仍是限定的 metadata 預檢，並非完整 dpkg metadata graph 的隔離保證。

此 generator 從 source tar 安裝 Shell、固定 session／units 與 Fcitx profile，替換 checkout 路徑為 `/usr/lib/ditto`。runtime pins 固定 Qt 6.10.2、Rust 1.98.1、Node 22.23.2；這些欄位是輸入聲明，仍需 binary／ELF／QML 實測。此抽取版本沿 Ubuntu UAT 使用 snapshot `/usr` Qt，不引入另一份私有 Qt；正式跨 suite runtime 決策交 D04。

## Boot 與 pristine 檢查

`repart.d/` 維持 ESP＋writable state＋versioned read-only `/usr`＋empty slot。`finalize.sh` 預先整合 tty1 getty conflict 與 greetd PAM Wayland type；generator 保留 udev settle，另以 `wait-drm` 最多等待 30 秒，確認任一 `card[0-9]+` 有 backing device；不固定 PCI／vendor／card 編號，逾時由非致命的 ExecStartPre 放行，讓 greeter wrapper 可走無 DRM 文字保底。這是可攜化的實際 readiness wait，尚未證明與原 UAT boot 行為等價。`finish-image.sh` 驗 partition labels，唯讀掛載 `/usr`，用 `bootctl --no-variables` 安裝 `EFI/BOOT/BOOTX64.EFI`，不寫 builder EFI NVRAM。不再執行舊 run 的事後 boot patch。

沒有內建人員帳號、密碼、client SSH key、自動登入或遠端控制配置。root 鎖定；SSH 與 sysupdate 自動 timers 預設停用；`ditto-ssh-keygen.service` 是 ssh.service 必要依賴，以 `ssh-keygen -A` 在每機首次啟動 SSH 前產生 host keys。映像清空 machine-id，移除 rootfs 的 `var/lib/systemd/random-seed` 與 ESP 的 `boot/loader/random-seed`；finish 以 `bootctl install --random-seed=no` 避免產生 seed，另刪除 mkosi 已寫入的 ESP seed，確認不存在（含懸空 symlink），失敗即中止。開機時由既有 `systemd-random-seed.service`／`systemd-boot-random-seed.service` 分別管理 rootfs／ESP seed，不新增服務。fstab 與 finish 階段均以 `umask=0077` 掛載 ESP，只限 root 存取；fstab 另有 `ditto-state` 的 `/` 項目，用途見下方 #221 一節。這些是 source 契約，修正後映像尚未重建；首次開機 seed 服務實際成功執行、生成非空且各機不同的 ESP seed，以及 root-only 權限仍待 #207 開機回讀。首次帳號畫面與 wrapper 已有來源接線；PR A helper 尚未存在時由具名 TODO 維持 agreety，沒有可用帳號，不能當作可用的首次設定。這不是安裝器。

scan 唯讀檢查 mounted pristine rootfs；傳入 `--forbid` 可加精確的作者／checkout 路徑，全檔比對；預設檢查具名 home 與 build producer 路徑，允許 AppArmor 等 distro 使用的泛用 `/home/` tunable，不按檔名全面排除。報告只輸出路徑／hash，不輸出檔案內容。帳號檢查採 passwd／shadow 聯合驗證：`etc/passwd` 與 `etc/shadow` 均須包含 root、帳號集合必須一致，任一缺檔、不可讀、非 regular file、檔案或 parent symlink、重複帳號、密碼欄位空值／active credential／格式錯誤均失敗；passwd 可用 `x` 指向 shadow，shadow 則只接受真正鎖定的密碼欄位。host keys、authorized keys、known-hosts、非空 machine-id、rootfs／ESP random seed（含空檔）、greetd／getty／GDM 等 active autologin、sudoers（包含 include）免密規則、未核准完整 PEM key blocks 或讀取錯誤也均失敗。ESP seed 的懸空 symlink、指向檔案或目錄的 symlink 與實體目錄也列入 identity 拒絕，不讀取 link 的外部目標。未結構化或其他格式秘密仍需 D11／D12 供應鏈掃描，不將此掃描當完整保證。

`etc/systemd/system/` 與 `usr/lib/systemd/system/` 下的 unit symlink 只在映像 root 內逐 component 解析，不讀 builder 的同名路徑：絕對目標從映像 root 起算；merged-/usr 的 `lib -> usr/lib` 等 parent symlink 先展開，再處理其後的 `..`；獨立的實體 `lib/` 讀它自己的內容。整條鏈的 parent 與 leaf symlink 合計最多跟隨 40 次，不逐層重設。越界、循環、超限、懸空、中間 component 不是目錄、終點不是 regular file（FIFO 不開啟）或讀取錯誤，都列入 `authentication_config` 並使 scan 失敗，報告不輸出例外文字。只有 leaf 精確指向 `/dev/null` 才視為 mask；經 alias 抵達的 autologin／`login -f` 內容仍拒絕。

`public-selftest-key-sha256.json` 僅核准 GnuTLS `usr/lib/x86_64-linux-gnu/libgnutls.so.30.41.1` 七份公開 upstream self-test 的完整 block hash，不按 library 路徑全面豁免。原 PoC 的 source commit `4e84948a5e89689edbab2c5920db7fc32f31a985`、blob `914b94a5903e45af1560b603cf7ca20e5b2f8e24` 及來源分類見 [D-51 §依據](../../../.agents/notes/decisions/2026-10-24-d51-ubuntu-mkosi-base.md#依據)。升版出現新 block 必須重新分類。

`public-producer-path-fixtures.json` 依 [#205 owner 裁定](https://github.com/relvo-labs/Ditto/issues/205#issuecomment-6389746879) 登錄已獨立核對來源的公開套件／vendor bytes。這些檔案含具名 home 樣式字串，但字串屬於上游範例、上游美術中繼資料或上游官方建置環境，不是 Ditto 建置者的路徑。只有映像路徑**與**完整檔案 SHA256（及大小）都和唯一 entry 精確吻合的 regular file，其 producer-path 命中才改列 `public_producer_fixtures`，報告保留路徑、hash、來源與驗證層級，不輸出命中內容。邊界如下：

- 不看檔名、目錄、prefix 或套件歸屬，也不改 producer 規則。改動任一 byte、截斷、附加資料、換路徑或換版本，都會回到 `literal_matches`。
- 同一檔案的 `--forbid`、私鑰（GnuTLS 規則範圍不變）、autologin／免密 sudo、identity 與讀取錯誤檢查照常執行並失敗。分類只處理 producer-path 這一項命中。
- manifest 缺失、不可讀、JSON 錯誤、重複 key、重複或衝突 entry、無效 digest、缺來源／版本、非 canonical path，或含 Ditto 自有安裝路徑（`usr/lib/ditto/`、`usr/share/ditto/`、`usr/share/doc/ditto-runtime/`、`usr/local/libexec/`），都使 scan 失敗，且不分類任何檔案。自有產物只能用 remap 重建解決；`usr/lib/ditto-node/bin/node` 是 Node.js 官方 binary，不屬自有產物。
- 目前 15 項：#205 第一輪 8 項，加上 #221 builder 掃描的 7 項（見下方 #221 一節）。驗證層級不同：14 個 Ubuntu 檔案為 `signed-snapshot-index`：由 snapshot `20261020T000000Z` 的 `.deb` 解出後雜湊相同；`.deb` 雜湊列於 Packages.xz，該 Packages.xz 列於 gpgv 驗證通過的 InRelease。Node 22.23.2 為 `https-shasums-pgp-unverified`：tarball 內 `bin/node` 雜湊相同，tarball 符合以 HTTPS 取得的 SHASUMS256，但 **SHASUMS256 的 PGP 簽章尚未驗證**。
- 升版或換 snapshot 後，bytes 不同就不會吻合，必須重新取得來源並逐檔核對後再登錄。原始 `.deb`／tarball 不納入 repo。

## DEV／VM 與 TEST ONLY 驗證入口

一般桌面輸出不設定強制軟體繪製；首次設定 greeter 有獨立、限定一次的 pixman／Qt software 退路。GPU-less VM 要另加 `--dev-software-render` 產生獨立測試候選，launcher 才設定 `WLR_RENDERER_ALLOW_SOFTWARE=1 LIBGL_ALWAYS_SOFTWARE=1`；`image-inputs.json` 記錄 `mode=dev-software-render`，一般為 `mode=normal`。此旗標不是產品預設，也不授權將測試候選發布。原 UAT 是 virtio-vga＋llvmpipe 軟體繪製；一般模式在 GPU-less VM 預期無法提供該桌面。兩種新輸出都尚未開機資格驗證。

產品 pristine disk 仍沒有帳號、password、authorized key 或 autologin。重建驗證可在**另行授權、可丟棄的獨立測試副本**，透過 console 使用 systemd 內建 debug shell；先對未修改的 pristine disk 跑 finish／scan 並保存 hash，再建立測試副本，不對測試後的副本重新宣稱 pristine。

1. 在測試副本關閉 Secure Boot，使用 systemd-boot 選單的 `e` 編輯該次 UKI command line（需要允許 editor；若該 builder 禁用它，這條路徑就是未具備條件，不能算通過）。保留完整原 cmdline，包含 `root=`、精確 `mount.usr=` 與唯讀旗標，只在末尾追加 `systemd.debug_shell=1`；不要寫入產品 UKI 或 loader 預設。
2. 開機後以本機虛擬 console 切到 tty9（通常 Ctrl+Alt+F9）。Ubuntu pinned unit 直接啟動 `/usr/bin/bash`，這是刻意的 TEST ONLY root console，不需要修改 root password，也不啟動 SSH。從該 console 回讀版本、mount、runtime 與服務狀態。
3. 若要驗證互動桌面，可由操作者在這個可丟棄副本以標準 `useradd -m`／`passwd` 建立臨時測試使用者，再回 tty1 登入。密碼互動輸入，不置於命令列、recipe、logs 或自動腳本。這只是後續測試操作，不是 D06 首次帳號／安裝器實作，agreety 密碼登入仍須實際驗證。結束後銷毀副本，未帶 debug 參數的下一次啟動不應留下 debug shell。

此路徑已核對 systemd `v259.9` 的 [debug generator](https://github.com/systemd/systemd/blob/v259.9/src/debug-generator/debug-generator.c)、[debug unit](https://github.com/systemd/systemd/blob/v259.9/units/debug-shell.service.in)、[UKI command-line 選擇](https://github.com/systemd/systemd/blob/v259.9/src/boot/stub.c) 與 Ubuntu snapshot `systemd_259.9-0ubuntu0.1_amd64.deb` 內實際 tty9 unit；來源位置與核對方式見 [D-51 §依據](../../../.agents/notes/decisions/2026-10-24-d51-ubuntu-mkosi-base.md#依據)。未在 guest 執行，不能宣稱可登入或 runtime 驗證完成。這裡不使用尚未驗證的 SMBIOS SSH credential provisioning 建議。

## 尚未具備資格（not yet qualified）

- 尚無從 repo 路徑重建、通過 finish／pristine scan 並開機驗證的映像；目前只有靜態／合成輸入檢查與下列 #205 第一輪失敗結果。原 UAT 完整桌面可用，不代表抽取配方已可重建。
- [#205](https://github.com/relvo-labs/Ditto/issues/205) 第一輪以固定來源與 snapshot `20261020T000000Z` 完成 normal image construction，但 target runtime（Quickshell 缺 `libunwind.so.8`）與 pristine scan 均失敗，未開機、未發行。本次只修正 source：target 套件加入 `libunwind8`（snapshot 歸屬 `libunwind8:amd64 1.8.3-0ubuntu1`，不放進 runtime tree）、unit alias 改在映像內解析、native 建置要求 path remap。新映像仍須重建，並完成 finish／pristine scan、完整 staged ELF 集合的 target 依賴回讀，以及 remapped runtime 實際被新映像使用的回讀；source 測試通過不代表映像通過。
- 第一輪 scan 另有 8 個套件／vendor 檔案命中具名 home 樣式：adduser 兩個範例、`asoundrc.txt`、util-linux `deprecated.txt`、xkeyboard-config `symbols/se`、Fcitx5 SVG 圖示、`libgtk-3` 與隨附 Node。依 [#205 owner 裁定](https://github.com/relvo-labs/Ditto/issues/205#issuecomment-6389746879)，這 8 項已逐檔核對來源，並登錄於 `public-producer-path-fixtures.json`。目前只以合成 fixture，以及由已核對的上游 bytes 組成的 task-owned 目錄驗證過；新映像必須含完全相同的 bytes，才會在 scan 中吻合，這點尚待重建後實掃確認。Node 的 PGP 簽章仍未驗證。
- 未提供 runtime 全流程乾淨建置／builder 工具鏈快照、第二人重建或 bit-for-bit reproducibility。原 UAT 使用 pinned Quickshell cache binary 並留 PoC label。
- 尚無產品 sysupdate transfers、簽章／通道、Secure Boot、verity、boot counting／health-gated bless 接線；PoC 的未簽章本機 transfer 沒有帶進來。安裝 systemd-container 只提供 sysupdate binary，不代表更新可用。
- 完整 reboot 才是已觀察到的換槽方法；Ubuntu PoC soft-reboot 未切 `/usr`。新 image 未重驗更新／手動或自動回退、hang／斷電矩陣與 shared state schema 相容。
- greetd／bounded DRM wait 接線仍屬 PoC；UAT 使用 autologin，抽取版的 agreety 密碼登入未實測；產品 GDM／GNOME 共存、帳號建立／OEM、keyring 登入與冷開機解鎖由 D06／D07 處理；原 Ubuntu UAT keyring 冷開機後 locked。
- pristine scanner 只在 #205 第一輪失敗映像執行過，本次修正尚未在新的真實映像執行；合成 positive controls 不能替代完整 Ubuntu default files／package closure 的實際掃描。固定 mkosi seed 的 UUID 與空 machine-id／ConditionFirstBoot 語意由 #152 決定，GDM／relogin 接線由 #153 決定，runtime closure 精簡交 #151；本輪不變更這些政策。
- 安裝器只有 [`packaging/distro/installer/`](../installer/README.md) 的後端核心與 payload 抽取，尚無 ISO、安裝畫面或開機驗證；Secure Boot／NVIDIA／硬體、音效、NFR／效能均未接受；無模型憑證或 pinned backend。模板 runner 存在不代表任意程式可安全啟用。
- source／NOTICE／SBOM、名稱／角色素材權利與營運 EOL／修補 SLA 尚須各責任 issue 交付。B 加裝版只共用封裝契約，本目錄不實作 #174。

抽取對照：原 `work/build-image.py` → generator／repart／finalize；`finish-image.sh`、`patch-image-boot.sh` → 完成步驟與前置 boot 設定；`scan-pristine-rootfs.py` → 掃描器。`prepare-builder.sh` 與 provisioning 不納入；`build-native.sh`／`build-ui.sh`／`build-desktop.sh`／`build-wayfire*.sh`／`fetch-wayfire-deps.py` 的成功結果轉成明確 runtime 輸入契約，未冒充已移植成乾淨建置管線。

## #221 ISO 預覽版的映像調整（source 契約，尚未重建）

依 owner 2026-10-26 決定（[#152 留言](https://github.com/relvo-labs/Ditto/issues/152#issuecomment-6414217695)）：

- `packages.txt` 加入 `linux-firmware` 與 `mesa-libgallium`。amdgpu、i915、xe、nouveau、radeon 等 kernel 驅動已在 `linux-modules-7.0.0-38-generic`（snapshot 沒有 `linux-modules-extra` 這個套件），缺的是 firmware；`linux-firmware` 在 snapshot 是拉入全部 `linux-firmware-*` 分包的 meta，依 index 估計安裝後約 662 MiB。`mesa-libgallium` 原本就由 `libegl-mesa0` 帶入，明列是為了閉包精簡時不被移除。不含 NVIDIA 專有驅動。套件名稱與版本只查過 `resolute`、`-updates`、`-security` 的 Packages index（InRelease 以本機 Ubuntu archive keyring 經 gpgv 驗證），沒有下載或安裝 `.deb`。
- `/etc/fstab` 新增 `/dev/disk/by-partlabel/ditto-state / ext4 rw,x-systemd.growfs 0 0`。安裝器會把 `ditto-state` 分割區設成填滿磁碟，首次開機由 `systemd-growfs-root.service` 線上擴展 ext4。依 systemd v259.9 `src/fstab-generator/fstab-generator.c`，initrd 的 `rootflags=` 只採用 `x-systemd.makefs`／`validatefs`，growfs 必須來自 host 端 `/etc/fstab` 的 `/` 項目。`systemd-repart` 無法做這件事：它只會把分割區長進緊接其後的空間，而 `ditto-state` 後面是兩個 `/usr` 槽。直接複製的映像分割區大小不變，growfs 不做事。
- `generate.py --profile installer` 產生 #221 安裝器映像：mkosi `Format=uki`，整個系統放在 UKI 的 initrd、從 RAM 執行；套件另列於 `packages-installer.txt`（只帶顯示相關 firmware 分包與繁中畫面需要的 Qt／Mesa／字型，組 UKI 必須在映像內的 `systemd-boot-efi`，以及 finalize／帳號／Wayfire 用到的 `passwd`（usermod）、`login`（nologin）、`libgles2`；不含 greetd、首次帳號流程、SSH、音效、portal 或桌面服務）；runtime 只套用 Quickshell／Wayfire 子集（同一 lock 與 runtime policy，子集內的連結若指向子集外即拒絕）；finalize 改用 `finalize-installer.sh`，並拒絕含 `etc/initrd-release` 的結果。用法與限制見[安裝器 README](../installer/README.md)。
- builder phase A 以 `cc9808835bf1494cf1322d15de5c687510c822f0` 建出 normal 映像（mkosi exit 0；`/usr` 已用 2.14 GB／可用 6.19 GB，normal UKI 440 MB，ESP 剩 334 MB），但 finish 的 pristine scan 有 8 個 producer-path 命中而失敗，未產生 payload、installer UKI 或 ISO。命中全部來自 #221 新拉入的套件：`linux-firmware-qualcomm-misc`（`qcom/sdm845/adsp.mbn.zst`、`cdsp.mbn.zst`）、`linux-firmware-realtek`（`rtw89/rtw8922a_fw-3.bin.zst`），以及 `orca` 依賴帶入的 `python3-psutil` 7.1.0-1ubuntu1（兩個範例、`METADATA`、`tests/test_linux.py`，再加上 `tests/__pycache__/test_linux.cpython-314.pyc`）。命中內容是上游作者的示範路徑、mock 字串與韌體廠商的建置環境路徑。
- 其中 7 個是套件原有的檔案：coordinator 從 snapshot 下載 `.deb`，確認其 SHA256 與 Packages.xz（列於 gpgv 驗證通過的 InRelease）相同，解出的檔案 SHA256 與映像內的檔案相同。這 7 項依 #205 裁定，以精確路徑＋SHA256＋大小登錄於 `public-producer-path-fixtures.json`（`signed-snapshot-index`）；沒有目錄或套件層級的例外，scanner 與規則都沒有改。
- 第 8 個 `.pyc` 不是套件檔案，而是 `python3-psutil` 的 postinst 執行 py3compile 時產生的，不在 #205 裁定範圍，因此不登錄。`finalize.sh` 改為刪除 `usr/lib/python3/dist-packages/psutil/tests/__pycache__`（只刪產生的 bytecode，套件檔案保留），之後若 `psutil/tests` 下仍有任何 `.pyc`，建置即失敗。沒有用 dpkg `path-exclude`，因為本機無法驗證 mkosi 26 安裝套件時是否讀取映像內的 `dpkg.cfg.d`；finalize 在所有套件安裝之後執行，結果可以檢查。installer 映像不需要同樣處理：依已驗證的 snapshot index 計算，`packages-installer.txt` 的 Depends／Pre-Depends 閉包（含 Recommends 亦同）不含 `python3-psutil`；normal 映像是經 `orca` 帶入。installer 的 initrd 仍要另外跑 pristine scan。
- builder attempt 2（`845da6c`）：normal 映像、finish／pristine scan（0 findings，15 項 fixture 吻合，psutil bytecode 不存在）、60 個 target ELF 與 payload 都通過；installer 的 mkosi 在組 UKI 前失敗：`sd-stub not found at /usr/lib/systemd/boot/efi/linuxx64.efi.stub in the image`。依 mkosi v26 原始碼，`Format=uki` 會從映像根目錄讀取 sd-stub 與 kernel，ukify 則取自 builder／tools tree；initrd 是映像本身的 cpio，microcode 可有可無。因此 `packages-installer.txt` 只補上 sd-stub 的提供者 `systemd-boot-efi`（universe；`-updates` 為 259.9-0ubuntu0.1，與 systemd 同版；名稱與版本已在 gpgv 驗證過的 snapshot index 中核對）。normal 映像原本就有這個套件。installer UKI 尚未重建。
- builder attempt 3（`35f8930`）：sd-stub 已找到，normal 映像、scan、ELF、payload 再次通過；installer 的 finalize 在 `chroot usermod --lock root` 以 exit 127 失敗（`passwd` 不在清單內）。為了不再一輪只修一件，這次對 installer 映像做了一次完整的靜態閉包檢查：finalize 以 chroot 執行的命令、unit 的 `Exec*` 與 shebang、UI wrapper、後端實際呼叫的程式（mount、zstd、systemctl）、PAM 模組、sysusers 的 shell、Python import、Quickshell／Wayfire 子集的 ldd（取自 normal 映像回讀）、QML import、開機與媒體所需的 kernel module，以及 mkosi `Format=uki` 從映像讀取的 sd-stub、kernel 與 `/init`。每一項都以 gpgv 驗證過的 snapshot `Contents-amd64.gz`／Packages.xz 對應到套件，再檢查是否在 Depends 閉包內；閉包模型以 attempt 3 的實際安裝清單校準過。結果缺 3 個，已補上：`passwd`、`login`、`libgles2`（沒有它 Wayfire 根本無法啟動）。kernel module 中 sr_mod、sd_mod、cdrom、virtio_blk／scsi、xhci／ehci_pci、efivarfs 已確認編入 kernel，isofs、usb-storage、uas、nvme、ahci 則由 `linux-modules-7.0.0-38-generic` 提供。recipe 測試會從來源抽出這些命令，並要求每一個都有對應的套件。installer UKI 尚未重建。
- VM 驗收（ISO 由 `10edcf8` 建出，缺陷 `VM221-B-001`）：首開卡建立的第一個帳號已在 `sudo` 群組，但 normal 映像沒有 `sudo`、`/etc/sudoers` 或 `pkexec`，root 又是鎖定的，owner 指定的管理員因此沒有任何提權途徑。`packages.txt` 加入 `sudo`（snapshot 的 `-updates`／`-security` 為 1.9.17p2-1ubuntu3.2）。`/usr/bin/sudo` 不是 dpkg 擁有的檔案：sudo 的 postinst 以 update-alternatives 建立它，指向 setuid 的 `/usr/bin/sudo.ws`（priority 40）。`/etc/sudoers` 來自 Pre-Depends 的 `sudo-common` 1.2ubuntu，是 Ubuntu 預設的 `%sudo ALL=(ALL:ALL) ALL`，需要密碼。沒有加入 NOPASSWD，也沒有加入 polkit／pkexec。sudo 的其他依賴都已在 attempt 4 的 normal 映像中，閉包只多 `sudo` 與 `sudo-common`。installer 清單不變：它以 root 從 RAM 執行，不建立帳號。
- 兩個 `.deb` 的 SHA256 與 gpgv 驗證過的 Packages.xz 相同。以解出的真實檔案加上 postinst 會建立的 alternatives 連結跑本目錄的 scanner：sudoers、`sudoers.d/README`（其中的 `@includedir` 是註解行）、PAM 檔與 `sudo.service -> /dev/null` 都沒有 authentication 命中。但 sudo 上游範例 `usr/share/doc/sudo/examples/sudoers` 含 `/home/operator/...`，會命中 producer-path 規則，**在依 #205 裁定登錄這個精確 fixture 之前，下一次 finish／pristine scan 會失敗**。本輪沒有改 scanner 或規則，也還沒有登錄；路徑、SHA256 與大小已交 coordinator 核對上游 bytes。
- recipe 測試從 helper 實際的 `useradd -G` 讀出群組：每個群組都必須登錄對應的工具，其提供套件要出現在 normal 映像的每種模式中，且不出現在 installer 中。
- 其他管理工具：`adduser` 與 `passwd` 已在映像內。下列項目記錄但本輪不改：沒有 `apt`（`/usr` 唯讀、A/B 更新走 sysupdate，裝套件不是這個映像的管理方式）；沒有終端文字編輯器（`visudo`／`sudoedit` 預設的 `/usr/bin/editor` 不存在）；沒有 `polkitd`（桌面的關機與暫停經 logind，沒有 polkit 時一般 session 是否仍被允許，需要 VM 確認）。
- 以上修正都還沒有重建映像。sudo 在唯讀 ext4 `/usr` 上的 setuid 是否生效、`sudo -v` 要求密碼後提權、alternatives 連結與 `/etc/sudoers` 權限，都要在 VM 回讀。下一次 builder 要用新的 source commit 與新的 output 路徑重跑 finish／pristine scan，確認這 7 項以 `public_producer_fixtures` 吻合，並確認 `.pyc` 已不在映像內。
- 以上只有 source 測試。新映像仍須在 builder 回讀：`packages.tsv` 含 `linux-firmware*`、`/usr` 8 GiB 槽的使用量、UKI 大小與 ESP 剩餘空間（firmware 是否被帶進 initrd），以及 finish／pristine scan；VM 須回讀 `systemd-growfs-root.service` 結果與擴展後的 `df`。實體 GPU 仍未驗證。

本機回歸入口為 `python3 packaging/distro/ubuntu/tests/test_recipe.py -v`，需要 Git 與真實 `dpkg-query`。測試只使用 task-owned filesystem／dpkg fixtures、source archive 與有界 DRM 假目錄，不啟動 runtime binary、guest 或掛載映像；通過不代表映像已取得資格。


## 首次帳號接線（#212，尚待整合 VM）

詳見 [first-boot README](../first-boot/README.md)。generator 一律安裝原生 1A 畫面、
wrapper、Wayfire 設定與 Chewing profile。`TODO_FIRSTBOOT_ACCOUNT_PR_A` 讓 PR B 先合併時
仍可建置：PR A 來源 artifacts 全不存在時，greetd 保留舊 agreety，並在映像
`/usr/share/ditto/firstboot-integration.json` 明記未啟用。只要出現 PR A 任一 artifact，
就必須具備 crate、Unicode NOTICE、七個 unit（account socket／service、recover、tty、dispatch socket／service、prepare）、固定 root launcher、tmpfiles 與同來源 runtime-lock 的 helper binary；不齊即在
建立 output 前拒絕。齊備時命令改為 `/usr/lib/ditto/ditto-greeter`，finalizer 啟用
`ditto-firstboot-account.socket`、`ditto-firstboot-tty-dispatch.socket` 與 `ditto-firstboot-account-recover.service`。generator 按實際 unit 建立
`sockets.target.wants`、`sysinit.target.wants` 與 `greetd.service.wants`；recovery 的
`Before=greetd.service` 不可改成 greetd 的 Requires。finalizer 移除舊 recovery `.requires` link。
TTY unit 不預設啟用，只有通過 peer／greetd ancestry／root 帳號檢查的固定請求才由 root 排程。
prepare unit 先停止 greetd/getty、清理 `_greetd` session、接管／切換 tty1，再交給原三項 capabilities 的帳號 TTY unit；結束或失敗後由 OnSuccess／OnFailure 回 greetd 正式 PAM 登入。
root-owned 的本次開機 latch 與人類確認的最多三次嘗試阻止 respawn loop，重開機才允許再次 handoff。
這不是在 PR B 內提供假 helper，也不給 greeter 一般 root 命令權限。

新增 `fcitx5-chewing`（台灣注音）、`at-spi2-core`、`orca`、`speech-dispatcher`，
精確套件版本／授權與完整 closure 尚待同 snapshot 新映像的 dpkg manifest 回讀。
pristine scan 新增拒絕 `var/lib/ditto/firstboot/{account-created,pending}` 的任何存在形式，
包含空檔、目錄、FIFO、懸空 link 或 unsafe parent；既有檢查沒有移除。
greetd command 只精確接受既有 agreety 或新 wrapper，不接受附加參數／shell 命令。

Qt offscreen 單元測試只能證明驗證、可存取標記、鍵盤順序與使用 doubles 的狀態機；
Socket／greetd／PAM 真實協定、GPU／pixman／無 DRM、fcitx5 中文提交、Orca 與音訊、
登入後的程序清理及重開機，均須兩個 PR 整合後另做 VM 驗收。

整合 #213／#214 後，須從同一來源重建 helper 並更新 runtime lock，使其列入
`usr/lib/ditto/target/release/ditto-firstboot-account`；舊 lock 缺件會失敗。
runtime admission／lock 工具已支援該路徑，端到端 producer 仍由 D04 提供；本次未重建 runtime、
更動 lock hash 或建置真實映像。PR A 的 `--tty` 保持 root-only；wrapper 改送無帳密的固定 handoff。
原始碼已接 root TTY 啟動及回登入；真實 systemd ordering、可見 controlling VT、帳號工具、復原與 PAM 仍須新建可丟棄 VM 接受。
登入後須在 VM 確認沒有殘留 `_greetd` 程序，包含 Orca、AT-SPI 與 speech-dispatcher。
