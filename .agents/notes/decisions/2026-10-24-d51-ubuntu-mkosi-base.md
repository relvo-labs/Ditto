# D-51 Ubuntu 26.04＋mkosi 底座與雙交付形式

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-24（雙形式由 owner 於 2026-10-23 提出） |
| 狀態 | 已決定（底座選擇；不代表產品驗收） |
| 決策者 | 專案 owner |

## 結論

先做 Ubuntu：A 完整映像採 Ubuntu 26.04＋mkosi＋systemd-sysupdate `/usr` A/B；B 既有 Ubuntu Desktop 加裝版（#174）與 A 並行、共用套件。Fedora bootc 暫停，證據保留、不再投入實作；不提供 Fedora 既有桌面加裝版。

本決策部分修訂 D-18／#158「不再採工作階段安裝包」：2026-10-21 對 A 的完整發行版方向保留，2026-10-23 新增 B；不撤銷 [D-49](2026-10-21-d49-g4-mvp-owner-acceptance.md) 的 MVP 接受。B 不是把既有 Ubuntu 原地轉成 A。接口見 [雙形式 ADR](../../../docs/platform/distro-architecture.md)。

## 依據

決策權威為專案 owner 2026-10-24 對話，由 coordinator 轉錄於 [#148 留言 6384379418](https://github.com/relvo-labs/Ditto/issues/148#issuecomment-6384379418)。parent 於 2026-10-24 21:36:31 +08:00 重新回讀 id、作者 `Lei-k` 與全文，確認 Ubuntu 優先、Fedora 暫停及雙形式方向不變；修正的只有兩條 UAT 遠端 client 證據的歸屬。本輪 writer 讀取該回讀紀錄，未把較早離線 issue 快照當最新授權。

parent 的實際回讀保存在 `/data/hermes/agent-runs/ditto-d01-ubuntu-adr/repair1/evidence/authority-comment-verified.json`；較早 `distro-progress-audit-20261024/sources/issue-{148,158,174}.json` 與各 comments 僅保留為歷史輸入。

TEST ONLY console 路徑另核對 systemd v259.9 `src/debug-generator/debug-generator.c`、`src/boot/stub.c`、`src/boot/boot.c` 與 `units/debug-shell.service.in`；並從 Ubuntu snapshot `20261020T000000Z` 的 `systemd_259.9-0ubuntu0.1_amd64.deb` 讀出實際 tty9 `/usr/bin/bash` unit。來源 URL／hash 與讀回檔案保存在 `/data/hermes/agent-runs/ditto-d01-ubuntu-adr/repair1/evidence/upstream/`。這是 HTTPS 來源核對，未另驗 APT 簽章，也未實跑 guest；不推論 SMBIOS SSH credential provisioning 可用。

以下證據根目錄為 `/data/hermes/ditto-runs/`，本次只讀取留存證據，未操作 VM。

| 證據 | 已驗證事實 | 未涵蓋 |
| --- | --- | --- |
| `distro-poc/CRITERIA.md`、`ubuntu/README.md`、`ubuntu/evidence/C2-C4-C8-final-v1.txt` | 2026-10-22 OVMF/KVM：snapshot `20261020T000000Z`、mkosi `26-3`；UEFI／UKI、kernel `7.0.0-38-generic`、systemd `259.9-0ubuntu0.1`、Landlock ABI 8、Qt 6.10.2、Quickshell 0.3.1 | 完整 QML 桌面、全部工具鏈位元一致重建 |
| 同目錄 `C5-stage-v2.txt`、`C5-v2-readback.txt`、`C5-soft-reboot-readback.txt`、`C6-v1-readback.txt`、`C7-auto-rollback-readback.txt` | sysupdate v1→v2；完整 reboot 才換槽；手動 oneshot 回 v1；v3 health 失敗兩次、未 bless，boot counting 回 good v2；唯讀 `/usr` 及 `/etc`／`/var`／`/home` marker 保留 | soft-reboot 沒有切換 `/usr` slot；只做一次完整故障循環，未測 hang／斷電；未簽章傳輸非正式通道 |
| 同目錄 `C9-final-rootfs-scan.txt`、`C9-public-fixture-source-provenance.json` | pristine rootfs 無個人路徑與未核准私鑰；SSH host keys 每機首次開機產生；GnuTLS 公開 self-test 完整 key block 按 SHA256 分類 | 不是全面秘密偵測保證，也不代表沒有 private-key 格式字串 |
| `distro-desktop-uat-20261024/ubuntu/work/README.md`、`evidence/result.json`、`evidence/parent-live-verification.json` | source `48593c3383353e25f07b6f247ae834cb92064911`（未含 #185），Wayfire／Core／hostd／Quickshell DRM session（virtio-vga＋llvmpipe 軟體繪製，非實體 GPU）、launcher 啟動 Foot、設定互動、portal／PipeWire、測試 client 遠端影像／鍵盤及冷開機重連；parent 無干擾回讀 `/usr ro`、ABI 8 與 binary hashes | owner 外部 client 接受 pending；無模型憑證；未重驗完整更新／回退矩陣，非效能／實體 GPU 證據；UAT 用 autologin，repo 的 agreety 密碼登入未實測 |

桌面 UAT 最終 `ditto-uat-ubuntu.raw` SHA256 為 `ee181cd8ee3f2a7a2b2d7fabf270865f67352d771645b6c53c4b2d01890a321d`。repo 配方由該次 work 腳本抽取、去除測試配置，尚未從 repo 路徑重跑，不能把此 hash 當成本次產物。PoC source 為 `d063f0357bfd3dc96e707072fe9e74c8722e3c98`，與 UAT／本分支基準不可混算。

## 考慮過但沒選的方案

- Fedora 44 bootc：暫停、未否決技術可行性。`distro-poc/fedora/round2/README.md` 記錄 C1–C10 VM 通過、標準 bootc／OSTree 與 greenboot；`distro-desktop-uat-20261024/fedora/evidence/result.json` 記錄標準 `bootc install to-disk`、SELinux Enforcing／0 AVC、Fedora UAT 另行實作 host＋TPM2 credential 封存／自動解鎖的測試 harness；Ubuntu UAT 未移植。該方式可移植到 Ubuntu，不是 Fedora 底座的固有優勢。SELinux 與標準 bootc 流程的比較事實仍保留。owner 選擇集中 Ubuntu，避免同時維護兩個底座；RPM／SELinux 與 `/etc` deployment 語意成本留供重評。該 UAT 也未接受更新／回退、硬體或 Secure Boot。
- B 接管宿主 boot／分割或承諾 OS 原子回退：不採用。OS 更新由 Ubuntu APT 與使用者管理。
- 選型等同發布接受：不採用。各切片仍需自己的驗證證據。

## 影響

- 底座選型解除 Ubuntu 方向等待；僅依賴已就緒的 D02–D07／D09 契約切片可開始。D08 必須等待 `D05-recovery-ready` 與 `D09-user-sandbox-ready`，D10 必須等待精確候選與相關證據；本決策未滿足這些入口。D11／D12 的工程材料與乾淨建置切片可並行。不要求 #50 整張先關閉；接口見 ADR。未核定出口、硬體與日期，工期依剩餘工作另估。
- Fedora 實作停止，PoC／UAT 不刪。G0 Ubuntu 24.04 參考機保持歷史凍結，不能挪用為 Ubuntu 26.04 證據。
- Ubuntu UAT 冷開機 keyring 為 locked，未移植 TPM 自動解鎖。Qt 6.10.2 維持獨立於 distro 升版的 pin；G0／跨 suite 私有 runtime 仍需維護。此次 Ubuntu UAT 實際用 snapshot `/usr` Qt 6.10.2，不能誤寫為私有 Qt，也不能推論其他 suite 免測。Wayfire 由來源建置；Quickshell 是 pinned PoC cache binary、留有 PoC label；正式乾淨重建交 D04。
- 尚無 Secure Boot、verity、認證更新通道；安裝器、NVIDIA、實體硬體、音效、效能、第二人重建與完整故障矩陣未核定。A 的 schema／health-gated bless 交 D03／D05；B suite／GA-HWE／preview-stable／EOL 待 owner 核定。缺口不因選型而通過。

本輪抽取修復保留產品預設無帳號、root 鎖定、SSH 停用。加入有界且無廠商／PCI 位址的 DRM 等待，以及明確 `--dev-software-render` 測試模式；兩種 repo 輸出均尚未重建或開機資格驗證。來源 UAT 需要實際 DRM 等待與軟體繪製，udev settle 單獨替代沒有等價證據。TEST ONLY console debug-shell 路徑只經 pinned systemd 來源與 Ubuntu 套件 unit 核對，尚未實跑。固定 mkosi seed／machine-id 首次開機語意交 #152，GDM／relogin 交 #153，runtime closure 精簡交 #151。
