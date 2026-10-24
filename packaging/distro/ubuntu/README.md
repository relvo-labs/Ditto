# Ubuntu 映像配方

本目錄是從 2026-10-24 Ubuntu 桌面 UAT 抽取的 mkosi 配方，尚未從 repo 路徑重跑，不是可發行映像。架構與責任見[雙形式 ADR](../../../docs/platform/distro-architecture.md)。

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
source_commit="$(git rev-parse HEAD)"
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

`--output` 必須不存在；用新目錄建立下一版。source tar 的 hash 不符、runtime 缺檔／digest 不符、pin／snapshot 不一致即停止。mkosi 套件取得需可用的 snapshot mirror 或預載 cache；本次離線 writer 沒有執行這一步。`packages.txt` 的 kernel 與 snapshot 是 PoC 鎖；變更 snapshot 時 D02／D04 必須一起核對 kernel／Qt／runtime lock，不代表可任意替換。

成品在 `out/ditto.raw`，另有 mkosi JSON manifest／split partitions／UKI、`packages.tsv`、`pristine-scan.json` 與 `disk.sha256`。finish 步驟會修改 ESP 安裝 fallback EFI，**以完成後 disk hash 為準**；不要使用完成前 mkosi disk checksum 對外發布。每版 lock 同存於映像 `/usr/share/ditto/`。

## Runtime tree 與來源責任

tree 以映像 root 為起點，只接受 `generate.py` 列舉的路徑與 lock 中的檔案，不複製整台 builder。所有檔案必須列 SHA256；symlink 另列 target，必須指向同 lock 的 regular file。

| 輸入位置 | 來源／建置要求 |
| --- | --- |
| `usr/lib/ditto/target/release/` | 必備 Core、worker、confine、supervisor、dittoctl、test-host、D-Bus proxy、固定 generation runner；native 依 `rust-toolchain.toml`／Cargo.lock 建置，保留固定 runner 的 Qt pkg-config 建置路徑 |
| `usr/lib/ditto/packages/{host-runtime,agent-runtime}/dist/` | 同 source 的 pnpm frozen-lockfile bundle；保留 bundle 的上游 notice |
| `usr/lib/ditto/target/ditto-packages/` | `scripts/build-builtin-packages.sh` 的正式包；不得加入驗證 relay 或故障夾具 |
| `usr/bin/quickshell`、`usr/bin/wayfire`、`usr/lib/x86_64-linux-gnu/`、`usr/share/wayfire/` | 固定 Quickshell rev `1a4716c…`、Wayfire `d399023…` 與實際 subproject closure；編譯時用中性 source 路徑。Wayfire lock 來源為 `packaging/reference-image/source-builds.lock`，相依版本若調整須在 D04 明列 |
| `usr/local/libexec/xdg-desktop-portal-wlr` | repo `tools/xdpw/pin.json` 加既有 patches；D-Bus proxy 同理依 `tools/dbus-proxy/pin.json`，不自行抓浮動版本 |
| `usr/lib/ditto-node/bin/node` | Node 22.23.2；官方來源／hash 與 Node 的第三方授權材料另核對 |
| `usr/share/doc/ditto-runtime/` | 必備 source provenance、各元件 LICENSE／NOTICE、修改清單；至少有檔案不代表法律盤點完成，D11 須逐項審查 |

此 generator 從 source tar 安裝 Shell、固定 session／units 與 Fcitx profile，替換 checkout 路徑為 `/usr/lib/ditto`。runtime pins 固定 Qt 6.10.2、Rust 1.98.1、Node 22.23.2；這些欄位是輸入聲明，仍需 binary／ELF／QML 實測。此抽取版本沿 Ubuntu UAT 使用 snapshot `/usr` Qt，不引入另一份私有 Qt；正式跨 suite runtime 決策交 D04。

## Boot 與 pristine 檢查

`repart.d/` 維持 ESP＋writable state＋versioned read-only `/usr`＋empty slot。`finalize.sh` 預先整合 tty1 getty conflict 與 greetd PAM Wayland type；generator 使用通用 udev settle，移除舊 VM PCI 位址與強制 software renderer。`finish-image.sh` 驗 partition labels，唯讀掛載 `/usr`，用 `bootctl --no-variables` 安裝 `EFI/BOOT/BOOTX64.EFI`，不寫 builder EFI NVRAM。不再執行舊 run 的事後 boot patch。

沒有內建人員帳號、密碼、client SSH key、自動登入或遠端控制配置。root 鎖定；SSH 與 sysupdate 自動 timers 預設停用；`ditto-ssh-keygen.service` 是 ssh.service 必要依賴，以 `ssh-keygen -A` 在每機首次啟動 SSH 前產生 host keys。映像清除 machine-id／random seed；D06 尚須提供首次帳號建立，直接開機只有登入提示，尚無可用帳號。這不是安裝器。

scan 唯讀檢查 mounted pristine rootfs；傳入 `--forbid` 可加精確的作者／checkout 路徑，全檔比對；`etc/` 與 provenance 另查廣義 home/data 路徑。報告只輸出路徑／hash，不輸出檔案內容。host keys、authorized keys、known-hosts、非空 machine-id／random seed、shadow 密碼 hash、未核准完整 PEM key blocks 或讀取錯誤均失敗。未結構化或其他格式秘密仍需 D11／D12 供應鏈掃描，不將此掃描當完整保證。

`public-selftest-key-sha256.json` 僅核准 GnuTLS `usr/lib/x86_64-linux-gnu/libgnutls.so.30.41.1` 七份公開 upstream self-test 的完整 block hash，不按 library 路徑全面豁免。原 PoC 的 source commit `4e84948a5e89689edbab2c5920db7fc32f31a985`、blob `914b94a5903e45af1560b603cf7ca20e5b2f8e24` 及分類見 `distro-poc/ubuntu/evidence/C9-public-fixture-source-provenance.json`。升版出現新 block 必須重新分類。

## 尚未具備資格（not yet qualified）

- 尚未從 repo 路徑重跑 mkosi、boot 或 pristine image scan；本次只做靜態／合成輸入檢查。原 UAT 完整桌面可用，不代表抽取配方已可重建。
- 未提供 runtime 全流程乾淨建置／builder 工具鏈快照、第二人重建或 bit-for-bit reproducibility。原 UAT 使用 pinned Quickshell cache binary 並留 PoC label。
- 尚無產品 sysupdate transfers、簽章／通道、Secure Boot、verity、boot counting／health-gated bless 接線；PoC 的未簽章本機 transfer 沒有帶進來。安裝 systemd-container 只提供 sysupdate binary，不代表更新可用。
- 完整 reboot 才是已觀察到的換槽方法；Ubuntu PoC soft-reboot 未切 `/usr`。新 image 未重驗更新／手動或自動回退、hang／斷電矩陣與 shared state schema 相容。
- greetd 與泛化 udev 接線仍屬 PoC；產品 GDM／GNOME 共存、帳號建立／OEM、keyring 登入與冷開機解鎖由 D06／D07 處理；原 Ubuntu UAT keyring 冷開機後 locked。
- 無 installer、Secure Boot／NVIDIA／硬體、音效、NFR／效能接受；無模型憑證或 pinned backend。模板 runner 存在不代表任意程式可安全啟用。
- source／NOTICE／SBOM、名稱／角色素材權利與營運 EOL／修補 SLA 尚須各責任 issue 交付。B 加裝版只共用封裝契約，本目錄不實作 #174。

抽取對照：原 `work/build-image.py` → generator／repart／finalize；`finish-image.sh`、`patch-image-boot.sh` → 完成步驟與前置 boot 設定；`scan-pristine-rootfs.py` → 掃描器。`prepare-builder.sh` 與 provisioning 不納入；`build-native.sh`／`build-ui.sh`／`build-desktop.sh`／`build-wayfire*.sh`／`fetch-wayfire-deps.py` 的成功結果轉成明確 runtime 輸入契約，未冒充已移植成乾淨建置管線。
