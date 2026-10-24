# Ubuntu 映像配方

本目錄是從 2026-10-24 Ubuntu 桌面 UAT 抽取的 mkosi 配方，尚未從 repo 路徑重建出通過驗收的映像，不是可發行映像。架構與責任見[雙形式 ADR](../../../docs/platform/distro-architecture.md)，來源與驗證範圍見 [D-51 §依據](../../../.agents/notes/decisions/2026-10-24-d51-ubuntu-mkosi-base.md#依據)。

原 run 建出 `ditto-uat-ubuntu.raw`，SHA256 為 `ee181cd8ee3f2a7a2b2d7fabf270865f67352d771645b6c53c4b2d01890a321d`。去除測試配置後，repo 配方不會產出相同 hash；該 hash 只識別抽取來源。原 run source 是 `48593c3383353e25f07b6f247ae834cb92064911`、archive SHA256 `a5ae33292e8398f4fa65375fd8aeaf87fdabb1ac5baba3cbbf4163b6707b2b2d`，未含 #185；本分支從含 #185／#186 的基準開始，未重建的差異不能算作已驗證。

## 最短建置路徑

在另行準備的可丟棄 Ubuntu 26.04 amd64 builder 執行，使用 mkosi `26-3`、Python ≥3.12、bash、util-linux、systemd-boot、dpkg、tar。需要 root 的 mkosi／loop mount 僅在該 builder 內執行。這裡不建立 builder、啟動測試環境或下載私人 cache。

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

成品在 `out/ditto.raw`，另有 mkosi JSON manifest／split partitions／UKI、`packages.tsv`、`pristine-scan.json` 與 `disk.sha256`。finish 步驟會修改 ESP 安裝 fallback EFI，**以完成後 disk hash 為準**；不要使用完成前 mkosi disk checksum 對外發布。每版 lock 同存於映像 `/usr/share/ditto/`。

## Runtime tree 與來源責任

tree 以映像 root 為起點，只接受 `generate.py` 列舉的路徑與 lock 中的檔案，不複製整台 builder。所有 regular files 必須列 SHA256；symlink 另列 target，可經多個已列入 lock 的 symlink 抵達同 lock 的 regular file。每一跳都限於 admitted image paths，拒絕循環、未列目標、越界與 parent symlink。

| 輸入位置 | 來源／建置要求 |
| --- | --- |
| `usr/lib/ditto/target/release/` | 必備 Core、worker、confine、supervisor、dittoctl、test-host、D-Bus proxy、固定 generation runner；native 依 `rust-toolchain.toml`／Cargo.lock 建置，以 compiler path remap（例如 rustc `--remap-path-prefix`）把 source、Cargo registry、toolchain 與建置目錄映射為中性路徑，保留固定 runner 的 Qt pkg-config 建置路徑 |
| `usr/lib/ditto/packages/{host-runtime,agent-runtime}/dist/` | 同 source 的 pnpm frozen-lockfile bundle；保留 bundle 的上游 notice |
| `usr/lib/ditto/target/ditto-packages/` | `scripts/build-builtin-packages.sh` 的正式包；不得加入驗證 relay 或故障夾具 |
| `usr/bin/quickshell`、`usr/bin/wayfire`、指定 Wayfire libraries／plugins、`usr/share/wayfire/` | 固定 Quickshell rev `1a4716c…`、Wayfire `d399023…`；系統 libdir 只接受 `libwf-{config,utils,touch,json}.so*`、`libwlroots-0.20.so*` 的數字版本及 Wayfire plugin `.so`，不接受 libc／Qt 等其他 distro libraries；編譯時用中性 source 路徑。Wayfire lock 來源為 `packaging/reference-image/source-builds.lock`，相依版本若調整須在 D04 明列 |
| `usr/local/libexec/xdg-desktop-portal-wlr` | repo `tools/xdpw/pin.json` 加既有 patches；D-Bus proxy 同理依 `tools/dbus-proxy/pin.json`，不自行抓浮動版本 |
| `usr/lib/ditto-node/bin/node` | Node 22.23.2；官方來源／hash 與 Node 的第三方授權材料另核對 |
| `usr/share/doc/ditto-runtime/` | 必備 source provenance、各元件 LICENSE／NOTICE、修改清單；至少有檔案不代表法律盤點完成，D11 須逐項審查 |

所有 native 產物都必須用 compiler path remap 或中性來源／建置路徑編譯，輸出不得含具名 home、checkout、`agent-runs`／`worktrees`／`ditto-runs`／`cache/scratch` 等 producer 路徑。是否做到，由新映像的 pristine scan 對實際輸出 bytes 判定；只提供 remap 指令或建置旗標不算證明。不得修改既有 binary 字串、偽造 Git identity，也不得把自有產物的 hash 登錄成公開例外。scanner 的 producer 規則對自有產物沒有例外：#205 第一輪的 `ditto-core`、`dittoctl`、`ditto-test-host`、`ditto-worker` 命中，須以 remap 重建解決。

`runtime_policy.py` 同時供 lock generation、generator、apply 與 finish audit 使用。runtime 不透過 ExtraTrees 覆寫套件：先 stage 在 generated project 的 `runtime/`，finalizer 以 `dpkg-query --admindir=$BUILDROOT/var/lib/dpkg` 檢查全部路徑（包含 link）。target 的 merged-/usr 等別名依映像內實際 parent symlink 解析，再比對 target package 歸屬；獨立的實體 `/bin` 不會直接視為 `/usr/bin`。任一已被套件擁有或 query 異常（含逾時）即以 exit 2 拒絕，全部通過才 copy；既有 regular-file 目的地的 `st_nlink > 1` 也在任何 copy 前拒絕，避免改寫共用的套件 inode。finish 再對 mounted target DB 與實際 payload hashes 做唯讀 audit。這些查詢不讀 builder 的預設 dpkg DB；preflight 拒絕不得被忽略。真實映像的 catalog 查詢耗時尚待 #148／#151 重建時量測，#199 保留該項驗收。

套件預檢允許缺少 `updates/`；存在時必須是真實目錄，並以 `lstat` 檢查所有直接 journal entries，在任何 dpkg 查詢前拒絕 symlink（包含懸空或循環）與非 regular file（例如目錄、FIFO），不遞迴追蹤。正常的 regular numeric journal 仍可使用。這是限定的 metadata 預檢，並非完整 dpkg metadata graph 的隔離保證；`arch`／`triggers` 等既有追蹤項仍待處理。

此 generator 從 source tar 安裝 Shell、固定 session／units 與 Fcitx profile，替換 checkout 路徑為 `/usr/lib/ditto`。runtime pins 固定 Qt 6.10.2、Rust 1.98.1、Node 22.23.2；這些欄位是輸入聲明，仍需 binary／ELF／QML 實測。此抽取版本沿 Ubuntu UAT 使用 snapshot `/usr` Qt，不引入另一份私有 Qt；正式跨 suite runtime 決策交 D04。

## Boot 與 pristine 檢查

`repart.d/` 維持 ESP＋writable state＋versioned read-only `/usr`＋empty slot。`finalize.sh` 預先整合 tty1 getty conflict 與 greetd PAM Wayland type；generator 保留 udev settle，另以 `wait-drm` 最多等待 30 秒，確認任一 `card[0-9]+` 有 backing device；不固定 PCI／vendor／card 編號，逾時直接使 greetd 啟動失敗。這是可攜化的實際 readiness wait，尚未證明與原 UAT boot 行為等價。`finish-image.sh` 驗 partition labels，唯讀掛載 `/usr`，用 `bootctl --no-variables` 安裝 `EFI/BOOT/BOOTX64.EFI`，不寫 builder EFI NVRAM。不再執行舊 run 的事後 boot patch。

沒有內建人員帳號、密碼、client SSH key、自動登入或遠端控制配置。root 鎖定；SSH 與 sysupdate 自動 timers 預設停用；`ditto-ssh-keygen.service` 是 ssh.service 必要依賴，以 `ssh-keygen -A` 在每機首次啟動 SSH 前產生 host keys。映像清除 machine-id／random seed；D06 尚須提供首次帳號建立，直接開機只有登入提示，尚無可用帳號。這不是安裝器。

scan 唯讀檢查 mounted pristine rootfs；傳入 `--forbid` 可加精確的作者／checkout 路徑，全檔比對；預設檢查具名 home 與 build producer 路徑，允許 AppArmor 等 distro 使用的泛用 `/home/` tunable，不按檔名全面排除。報告只輸出路徑／hash，不輸出檔案內容。帳號檢查採 passwd／shadow 聯合驗證：`etc/passwd` 與 `etc/shadow` 均須包含 root、帳號集合必須一致，任一缺檔、不可讀、非 regular file、檔案或 parent symlink、重複帳號、密碼欄位空值／active credential／格式錯誤均失敗；passwd 可用 `x` 指向 shadow，shadow 則只接受真正鎖定的密碼欄位。host keys、authorized keys、known-hosts、非空 machine-id／random seed、greetd／getty／GDM 等 active autologin、sudoers（包含 include）免密規則、未核准完整 PEM key blocks 或讀取錯誤也均失敗。未結構化或其他格式秘密仍需 D11／D12 供應鏈掃描，不將此掃描當完整保證。

`etc/systemd/system/` 與 `usr/lib/systemd/system/` 下的 unit symlink 只在映像 root 內逐 component 解析，不讀 builder 的同名路徑：絕對目標從映像 root 起算；merged-/usr 的 `lib -> usr/lib` 等 parent symlink 先展開，再處理其後的 `..`；獨立的實體 `lib/` 讀它自己的內容。整條鏈的 parent 與 leaf symlink 合計最多跟隨 40 次，不逐層重設。越界、循環、超限、懸空、中間 component 不是目錄、終點不是 regular file（FIFO 不開啟）或讀取錯誤，都列入 `authentication_config` 並使 scan 失敗，報告不輸出例外文字。只有 leaf 精確指向 `/dev/null` 才視為 mask；經 alias 抵達的 autologin／`login -f` 內容仍拒絕。

`public-selftest-key-sha256.json` 僅核准 GnuTLS `usr/lib/x86_64-linux-gnu/libgnutls.so.30.41.1` 七份公開 upstream self-test 的完整 block hash，不按 library 路徑全面豁免。原 PoC 的 source commit `4e84948a5e89689edbab2c5920db7fc32f31a985`、blob `914b94a5903e45af1560b603cf7ca20e5b2f8e24` 及來源分類見 [D-51 §依據](../../../.agents/notes/decisions/2026-10-24-d51-ubuntu-mkosi-base.md#依據)。升版出現新 block 必須重新分類。

`public-producer-path-fixtures.json` 依 [#205 owner 裁定](https://github.com/relvo-labs/Ditto/issues/205#issuecomment-6389746879) 登錄已獨立核對來源的公開套件／vendor bytes。這些檔案含具名 home 樣式字串，但字串屬於上游範例、上游美術中繼資料或上游官方建置環境，不是 Ditto 建置者的路徑。只有映像路徑**與**完整檔案 SHA256（及大小）都和唯一 entry 精確吻合的 regular file，其 producer-path 命中才改列 `public_producer_fixtures`，報告保留路徑、hash、來源與驗證層級，不輸出命中內容。邊界如下：

- 不看檔名、目錄、prefix 或套件歸屬，也不改 producer 規則。改動任一 byte、截斷、附加資料、換路徑或換版本，都會回到 `literal_matches`。
- 同一檔案的 `--forbid`、私鑰（GnuTLS 規則範圍不變）、autologin／免密 sudo、identity 與讀取錯誤檢查照常執行並失敗。分類只處理 producer-path 這一項命中。
- manifest 缺失、不可讀、JSON 錯誤、重複 key、重複或衝突 entry、無效 digest、缺來源／版本、非 canonical path，或含 Ditto 自有安裝路徑（`usr/lib/ditto/`、`usr/share/ditto/`、`usr/share/doc/ditto-runtime/`、`usr/local/libexec/`），都使 scan 失敗，且不分類任何檔案。自有產物只能用 remap 重建解決；`usr/lib/ditto-node/bin/node` 是 Node.js 官方 binary，不屬自有產物。
- 目前 8 項的驗證層級不同。7 個 Ubuntu 檔案為 `signed-snapshot-index`：由 snapshot `20261020T000000Z` 的 `.deb` 解出後雜湊相同；`.deb` 雜湊列於 Packages.xz，該 Packages.xz 列於 gpgv 驗證通過的 InRelease。Node 22.23.2 為 `https-shasums-pgp-unverified`：tarball 內 `bin/node` 雜湊相同，tarball 符合以 HTTPS 取得的 SHASUMS256，但 **SHASUMS256 的 PGP 簽章尚未驗證**。
- 升版或換 snapshot 後，bytes 不同就不會吻合，必須重新取得來源並逐檔核對後再登錄。原始 `.deb`／tarball 不納入 repo。

## DEV／VM 與 TEST ONLY 驗證入口

一般輸出不設定強制軟體繪製。GPU-less VM 要另加 `--dev-software-render` 產生獨立測試候選，launcher 才設定 `WLR_RENDERER_ALLOW_SOFTWARE=1 LIBGL_ALWAYS_SOFTWARE=1`；`image-inputs.json` 記錄 `mode=dev-software-render`，一般為 `mode=normal`。此旗標不是產品預設，也不授權將測試候選發布。原 UAT 是 virtio-vga＋llvmpipe 軟體繪製；一般模式在 GPU-less VM 預期無法提供該桌面。兩種新輸出都尚未開機資格驗證。

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
- 無 installer、Secure Boot／NVIDIA／硬體、音效、NFR／效能接受；無模型憑證或 pinned backend。模板 runner 存在不代表任意程式可安全啟用。
- source／NOTICE／SBOM、名稱／角色素材權利與營運 EOL／修補 SLA 尚須各責任 issue 交付。B 加裝版只共用封裝契約，本目錄不實作 #174。

抽取對照：原 `work/build-image.py` → generator／repart／finalize；`finish-image.sh`、`patch-image-boot.sh` → 完成步驟與前置 boot 設定；`scan-pristine-rootfs.py` → 掃描器。`prepare-builder.sh` 與 provisioning 不納入；`build-native.sh`／`build-ui.sh`／`build-desktop.sh`／`build-wayfire*.sh`／`fetch-wayfire-deps.py` 的成功結果轉成明確 runtime 輸入契約，未冒充已移植成乾淨建置管線。

本機回歸入口為 `python3 packaging/distro/ubuntu/tests/test_recipe.py -v`，需要 Git 與真實 `dpkg-query`。測試只使用 task-owned filesystem／dpkg fixtures、source archive 與有界 DRM 假目錄，不啟動 runtime binary、guest 或掛載映像；通過不代表映像已取得資格。
