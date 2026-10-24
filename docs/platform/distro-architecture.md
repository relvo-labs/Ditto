# Ditto 發行版架構：完整映像與 Ubuntu 加裝版

狀態：2026-10-24 owner 已核定 Ubuntu 底座與雙形式；下列介面為實作交接規格，尚非發布或安全驗收。決策紀錄見 [D-51](../../.agents/notes/decisions/2026-10-24-d51-ubuntu-mkosi-base.md)。

## 結論與日期界線

owner 於 2026-10-23 要求 A／B 同時提供，2026-10-24 決定先做 Ubuntu。A 採 Ubuntu 26.04＋mkosi＋systemd-sysupdate `/usr` A/B；B 是既有 Ubuntu Desktop 加裝版（#174），與 A 並行並共用套件。Fedora bootc 暫停、保留證據、不再投入實作，不做 Fedora 既有桌面加裝版。

本 ADR **部分修訂** #158／D-18：2026-10-21 的完整發行版方向對 A 保留，2026-10-23 新增 B 加裝套件；[D-49](../../.agents/notes/decisions/2026-10-21-d49-g4-mvp-owner-acceptance.md) 的 MVP 接受不變。選型不等於更新、安裝器、Secure Boot、NVIDIA 或硬體接受。權威為專案 owner 2026-10-24 對話，由 coordinator 轉錄於 [#148 留言](https://github.com/relvo-labs/Ditto/issues/148#issuecomment-6384379418)；parent 已重新核對作者與全文。回讀與歷史證據位置見 [D-51 §依據](../../.agents/notes/decisions/2026-10-24-d51-ubuntu-mkosi-base.md#依據)。

## A：完整映像（#158）

mkosi 建置 amd64／UEFI 開發候選，repart 建立 ESP、可寫 root/state、版本化唯讀 `/usr` 與同容量空槽。抽取配方沿用 UAT 的 768 MiB ESP＋8 GiB state＋兩個 8 GiB `/usr` 槽；這是 PoC 容量，正式容量由 D02／D03／D06 驗證後凍結。

| 層／權威 | 內容與寫入邊界 |
| --- | --- |
| 底座層 | kernel、firmware、UKI／initramfs、systemd、可信 Wayfire／Qt／Quickshell／Core、鎖定與最小救援。僅受控映像更新器寫 inactive slot／ESP；助手不能原地改 `/usr` |
| 助手層 | 另行版本化的 user-space 部署；Core 協調安裝交易、授權與能力綁定。未信任 QML／Cordis／原生程式在獨立程序與 OS 隔離內，不載入主 Shell／可信 hostd |
| 資料層 | 可寫 `/etc`、`/var`、`/home`；Core 唯一寫 Profile／revision／grants／operation，插件資料經 Core 介面，秘密在系統 keyring。宿主僅持投影，Agent 只提計畫 |
| 救援層 | 隨可信底座交付，無 Node／主 Shell／生成碼仍能操作；保護最近可用版本，檢查 store 相容性後才啟動舊 Core |

UKI cmdline 配對 state label 與精確 `/usr` 版本 label；sysupdate 將 `/usr` payload 寫 inactive partition，UKI 寫 ESP。產品 transfer 必須同版本成組、保護 running slot、保留上一個 good 版本。D03 實作 boot counting；D03／D05 定義 health 回讀，只有健康且 store 相容才 bless。失敗須有重開／watchdog policy，boot counting 本身不能解決 hang。PoC 的兩次 tries 是測試值，產品次數與時窗待核定。

開機後以 os-release＋cmdline＋mount＋selected entry 判定 running 版本，不能單看 sysupdate 列表的 `current`。Ubuntu PoC soft-reboot 未切 `/usr`，第一版以完整 reboot 作換槽契約。回退 `/usr` 不回退共用 state；資料快照／schema 與外部副作用分別由 D05／#41 處理。D03／D12 尚未提供 Secure Boot、verity、簽章或正式更新來源；repo 配方不出貨 PoC 的 `Verify=no` transfer。

## B：既有 Ubuntu Desktop 加裝（#174）

B 以共用 `.deb` 加裝獨立 Ditto session，保留 GNOME、預設 display manager 與 Ubuntu OS 更新路徑，不原地轉換成 A。Ditto 不接管分割、bootloader、PAM、宿主 driver 或全域 IME。首版契約為每 UID 同時一個圖形 session；D07 負責登出後 bus／portal／IME／環境清理。

安全退出旅程為 Ditto 登出 → GNOME 可用 → 在 GNOME 移除 Ditto → 回讀無殘留服務／session entry。預設保留使用者資料，清資料另行確認。TTY／GNOME 可用可信 CLI 救援；宿主 boot／driver 壞損由 Ubuntu recovery 處理。APT 升版與部分安裝報逐項結果，**不承諾宿主 OS 原子回退**。

支援順序沿 #174 提案：先 Ubuntu Desktop 24.04 amd64／GDM／受維護 HWE，再按 suite 重建 26.04；A 選定 26.04 不自動核定 B 的順序。GA 核心桌面限定、preview／stable 通道、公開時機、硬體與每 suite EOL 待 owner 核定，現無 stable 支援承諾。准入需實測 Landlock ABI ≥6、AppArmor／userns、seccomp、cgroup、Wayland，不以 kernel 名稱代替。隔離不足的桌面限定模式停用全部 agent 工具、shell、檔案寫入、生成安裝，只可無工具對話；對話邊界也不足則停助手，API key 不能繞過。這是 D02／D09 待落地契約。

## 共用封裝與維護責任

D04 是來源配方與套件 manifest 的唯一責任方：按 Ubuntu suite／架構各建 ABI 產物，A 組裝與 B stable 指向精確 package version＋digest／runtime digest，不能跨 LTS 共用未重建 binary。建議分為 `ditto-runtime`（Qt／Quickshell／Wayfire／Node 等受鎖 runtime）、可信 Core／救援、session、官方插件，以及 B 的 `ditto-desktop` meta；名稱由 D04 凍結，此處不是既有套件公告。

原版 Ubuntu 包保留 package version／snapshot／copyright；Ditto 自有包由 D04 重建；fork／patched portal 與 source-built Wayfire 保留 revision／patch／LICENSE。Qt 6.10.2 維持獨立於 distro 升版的 pin：24.04 需私有 runtime；Ubuntu UAT 的 snapshot `/usr` Qt 已跑桌面，26.04 是否沿用 distro 模組仍須 D04 驗證 private API／plugin 搜尋路徑與負例；不能覆蓋 B 的宿主 Qt／GNOME。UAT cache Quickshell 不能代替乾淨建置。D11 收集逐模組義務與 NOTICE；D12 建立 CVE 重建→測試→簽章→晉升，營運 owner、SLA、託管與 EOL 待核定。

2026-10-21 的 user-space 優先、一般安裝／相容更新自主、高風險才核准、依 manifest 可連網方向沿 #158 保留；系統套件另過後期閘門，kernel modules 不在範圍。這不放寬現行生成邊界：`generated-templates-v1/full` 只證明固定模板，D08 消費 D09 任意程式沙箱證據後才可開放，不能把映像唯讀或簽章當生成安全。

## D02–D12 交接介面

每份輸出均帶 source commit、suite／arch、映像與 package/runtime digest、助手 deployment、store schema、policy 版本與測試環境；未實作不可回報 ready。下表 D01～D12 為 issue 工作包，與歷史 D-01 等決策編號不同。

| 切片／責任 issue | 輸入 | 輸出及消費方 |
| --- | --- | --- |
| D02 #149 平台准入 | Ubuntu 選型、A 布局／B host 邊界 | kernel／firmware／driver 鎖、實測 ABI／安全能力、B admission／拒絕原因 → D03／D04／D09／D10 |
| D03 #150 開機信任 | D02 kernel／firmware、A 分割與版本配對 | UKI／initrd、簽章接口、boot counting／health-bless／救援入口 → A 的 D04／D05／D06／D12；B 不消費 boot 接口 |
| D04 #151 共用封裝 | source／runtime pins、D02 ABI；A 用 D03 boot 接口 | 每 suite `.deb`／檔案歸屬／digest／APT 信任與 runtime 契約 → A image、B meta、D05／D07／D11／D12；B 套件 PoC 不等 D03 整張完成 |
| D05 #50 回復 | D04 manifest、store schema、A 的 D03 回讀／B 的 APT 邊界 | 先交 `D05-recovery-ready`：operation journal、快照、相容啟動／停用與離線救援 → D08；再接 D08 完成更新／移除旅程；新資料處置歸 #41 |
| D06 #152 安裝／OEM | A image、D03 boot、D05 恢復契約 | live／安裝／首次開機、帳號／磁碟／locale／無障礙契約與證據 → D10／D12；B 不等此切片 |
| D07 #153 session | D04 runtime／檔案歸屬、B GNOME 基線 | GDM／portal／IME／keyring、登入／退出／卸載清理回讀 → A／B、D05／D10；UAT greetd 接線只作開發參考 |
| D08 #154 任意 user-space | D04 SDK；`D05-recovery-ready`＋`D09-user-sandbox-ready` | QML／Cordis／native user module／user service 各自生成→安裝→更新→失敗回復→移除保留資料 → D05／D10 |
| D09 #155 安全 | D02 實測能力、D04 launch／身份、D05 最小復原接口 | 先交 `D09-user-sandbox-ready`：風險／OS 沙箱／網路／秘密／Wayland 過濾及負例 → D08；整合不要求 D08 先完成 |
| D10 #156 候選驗收 | 精確 A／B 組合與各切片證據 | 硬體／故障／NFR 索引與未跑項 → owner 發布判斷；雙螢幕、無障礙、長跑仍歸既有 issue |
| D11 #51 來源與授權 | D04 完整 manifest、revision／patch、素材來源 | SBOM／source／LICENSE／NOTICE／權利缺口 → D12；法律裁定由 owner 處理，不新增技術阻擋 |
| D12 #157 發行工程 | 固定來源、D04 包、A 的 D03 簽章接口、D10／D11 | 隔離 CI／每 suite fresh VM／出貨 manifest／簽章晉升／CVE／EOL 手冊 → A／B 各自發布；APT 信任不依賴 UKI 簽章 |

順序：D01 → D02／D03／D04 的可用契約切片；D04＋最小回復／沙箱 → D08 → D05 完整旅程 → D10。D06／D07、D11、D12 乾淨建置可平行。**不要求 #50 或 #155 整張關閉才開始 D08**；B 也不要求 #150／#152 整張完成。A／B stable 各自取得精確組合證據，B preview 不替代 A 出口。

## 依據、未選方案與限制

證據位置、來源 commit／映像 hash 與驗證範圍見 [D-51 §依據](../../.agents/notes/decisions/2026-10-24-d51-ubuntu-mkosi-base.md#依據)。Ubuntu UAT 是 virtio-vga＋llvmpipe 軟體繪製，非實體 GPU 驗收；UAT 用 autologin，repo 的 agreety 密碼登入未實測。Fedora UAT 的 TPM2 封存解鎖是另外實作、可移植至 Ubuntu 的測試 harness，不是 Fedora 底座的固有優勢。owner 外部 client 與人工接受仍 pending。

[repo 配方](../../packaging/distro/ubuntu/README.md) 由 UAT 抽取、尚未重建或開機資格驗證；一般模式與明確 dev 軟體繪製模式都保留這項限制。選型只解除方向等待，依賴就緒的契約切片才可開始；D08 仍須兩個 ready 切片，D10 仍須候選與證據。Secure Boot、verity、認證更新通道、安裝器、NVIDIA／硬體、音效、效能、第二人重建與完整故障矩陣均未核定。Qt pin 與 source-built Wayfire 的安全維護由 D04／D12 接手，G0／G3 歷史範圍不變，工期依剩餘工作另估。

尚待 owner 核定 B suite／GA-HWE／通道／EOL、更新託管與維護責任、Secure Boot 金鑰路線、精確硬體、健康時窗／重試與資料保留政策；不重問 Ubuntu 優先與雙形式方向。
