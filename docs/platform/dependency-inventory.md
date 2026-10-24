# G0 依賴與授權盤點起點

此清單跟隨第一批 G0 程式碼建立。版本取自 `Cargo.lock`、`pnpm-lock.yaml` 與凍結參考平台；CI 的 [`licenses.yml`](../../.github/workflows/licenses.yml) 會輸出完整 Cargo metadata 與 pnpm 依賴授權清單供逐項審查。**這不是發行前授權審查完成的聲明**；NOTICE 彙整、Qt 模組逐項義務、名稱與角色素材權利仍屬 D-11。

## Ubuntu 發行版增量（2026-10-24）

owner 已選 Ubuntu 26.04＋mkosi＋sysupdate，A／B 共用封裝責任見[雙形式 ADR](distro-architecture.md)。下列為 PoC／UAT 的來源盤點，尚非完整 SBOM 或發布接受；Fedora 證據保留、實作暫停。

| 元件 | 精確基線／來源 | 修改、義務與責任 |
| --- | --- | --- |
| Ubuntu base／kernel／systemd／dracut 與 runtime packages | resolute snapshot `20261020T000000Z`；UAT kernel `7.0.0-38-generic`，PoC systemd `259.9-0ubuntu0.1`；逐包版本由 mkosi manifest／`packages.tsv` 輸出 | 各包授權以 `/usr/share/doc/*/copyright` 為準，不能套用單一 Ubuntu 授權；D04／D11 補齊 source／NOTICE／傳遞依賴與自有修改，D12 負責安全重建 |
| mkosi | PoC／UAT `26-3`，Ubuntu builder package | LGPL-2.1-or-later（仍須以出貨來源核對）；僅建置工具，不納入 target runtime；builder 工具鏈未完整快照化 |
| Qt／Quickshell | Qt 6.10.2 獨立版本鎖；Ubuntu UAT 用 snapshot `/usr` Qt；Quickshell `1a4716cde794a59928d9d9fc15f2afc7a95de360` cache binary | UAT 無 source patch，cache 留 PoC label；D04 需乾淨重建及逐模組散布材料。跨 suite 私有 runtime 不可覆蓋 B 宿主 Qt |
| Wayfire／subprojects | source-built `d39902379c5737eebe1dc3a830659fa3f0fa22e0`；鎖見 `packaging/reference-image/source-builds.lock` | UAT build glue 非產品 patch；MIT 與各 subproject LICENSE 隨 payload，D04／D11 記錄實際 dependency closure |
| Node | 22.23.2，UAT 的本機相同版本 cache | MIT 及 Node 內第三方 notices；正式包須保存來源、hash、LICENSE，不能把 cache 來源當正式供應鏈 |
| xdg-desktop-portal-wlr／D-Bus proxy | repo `tools/xdpw`／`tools/dbus-proxy` 的 pin、patch 與建置腳本 | 沿既有來源紀錄彙整授權與修改；D11 補完整 NOTICE。recipe 保留 payload hash，未重新取得上游 |

字型、Fcitx、foot、portal 等進入 A 後是實際出貨元件，不能沿用下表 G0「由宿主提供」的排除理由。配方攜帶 Ubuntu copyright 與外部 payload notices；這不是逐檔權利審查完成。Rust／pnpm／編譯器與 mkosi 是建置期工具，除 Node runtime 外不因建置使用而出貨。D-11 法律裁定由 owner 處理，工程 SBOM／source／NOTICE 仍由 #51 交付。

## Rust 直接依賴

| 名稱 | 鎖定版本 | 來源 | 授權標示 | 修改 | 使用與散布義務 |
| --- | --- | --- | --- | --- | --- |
| `serde` | 1.0.229 | [serde-rs/serde](https://github.com/serde-rs/serde)／crates.io | MIT OR Apache-2.0 | 無 | Core 執行期；發行包須攜帶適用授權文，Apache 選項的 NOTICE 待審 |
| `serde_json` | 1.0.151 | [serde-rs/json](https://github.com/serde-rs/json)／crates.io | MIT OR Apache-2.0 | 無 | Core 執行期；同上 |
| `schemars` | 1.2.2 | [GREsau/schemars](https://github.com/GREsau/schemars)／crates.io | MIT | 無 | 目前能力目錄在執行期建立 schema；發行包須保留 MIT 授權文 |
| `libc` | 0.2.189 | [rust-lang/libc](https://github.com/rust-lang/libc)／crates.io | MIT OR Apache-2.0 | 無 | Core peer credential 與量測工具；授權文／NOTICE 待審 |
| `chrono` | 0.4.45 | [chronotope/chrono](https://github.com/chronotope/chrono)／crates.io | MIT OR Apache-2.0 | 無 | 量測工具時間戳；授權文／NOTICE 待審 |

傳遞依賴與平台限定依賴以 CI 的 `cargo-metadata.json` 為完整清單來源，不把上表當作全部。程式碼沒有引入 vendored Cordis、Harness 套件或第三方角色素材。Harness 僅作協定形狀參考，見 [來源紀錄](../upstream/harness-sdk-protocol-shape.md)。

## 開發期依賴

| 直接開發依賴 | 鎖定版本 | 用途／排除原因 |
| --- | --- | --- |
| `@types/node` | 22.18.6 | TS 的 Node 型別；不進執行包 |
| `json-schema-to-typescript` | 15.0.4 | 從 Rust schema 產生 TS；不進執行包 |
| `typescript` | 5.9.3 | 型別檢查；不進執行包 |
| `vitest` | 3.2.4 | 契約測試；不進執行包 |

這些套件及其傳遞依賴**不進 G0 桌面工作階段或預期的執行包**。來源與授權由 `pnpm-lock.yaml` 與 CI `node-licenses.json` 保留；若未來將其中任何套件放進執行包，須改列為執行期並重審散布義務。

## 凍結桌面堆疊與系統資產

| 名稱 | 凍結版本／來源 | 授權標示 | G0 用途與處理 |
| --- | --- | --- | --- |
| Wayfire | 0.11.0，[WayfireWM/wayfire](https://github.com/WayfireWM/wayfire)；revision 見 `source-builds.lock` | MIT | 合成器；散布時攜帶上游 `LICENSE` |
| wlroots | 0.20.2，Wayfire subproject | MIT | Wayland compositor library；攜帶 subproject `LICENSE` |
| wf-config／wf-utils 等 Wayfire subprojects | revision 隨 `source-builds.lock` | 主要為 MIT；完整清單以來源樹為準 | 目前由 Wayfire 私有前綴連結，發行包需逐項彙整 NOTICE |
| Qt | 6.10.2 gcc_64 官方 binary archive | 商業／LGPLv3／GPLv2+／GPLv3，多授權依實際模組 | G0 選 LGPL 相容路徑的可行性；正式散布前須列出實際動態連結模組、重連結材料與對應授權文 |
| Quickshell | 0.3.1，commit `1a4716…` | LGPL-3.0（另附 GPL-3.0 文本） | Shell 執行期；保留來源 revision、授權文與修改狀態（無本地 source patch） |
| cpptrace | commit `91b6b78…`，[jeremy-rifkin/cpptrace](https://github.com/jeremy-rifkin/cpptrace) | MIT | Quickshell crash handler；無本地 source patch，散布時攜帶 MIT 授權文 |
| Noto CJK | Ubuntu `1:20230817+repack1-3` | 字型檔主要 SIL OFL 1.1；Debian source 另含 GPL-3+ 檔案 | 中文顯示；若打包字型，只納入已確認為 OFL 的字型檔並附 OFL 文本 |
| Firefox／foot／Kate／Fcitx5 | 版本見支援矩陣 | 由 Ubuntu／snap 各自提供 metadata | 參考應用與輸入法，不宣稱是 Ditto 發行包內嵌元件 |

`tools/dev-wayland` 的 Debian 容器與已遺棄的 Sway 後端只供開發與決策對照，不進 G0 參考工作階段或預期發行包。`packaging/reference-image/apt-packages.txt` 與 `source-builds.lock` 是平台重建清單；它們不是 NOTICE 檔的替代品。

## 素材與權利缺口

- `shell/avatar/layers/body.png` 來自凍結原型，來源已登記，但權利**未釐清**；公開發行前不能把它標為可散布。
- `hit-mask.json` 是從 `body.png` alpha 產生，權利隨來源素材。
- 眼睛、嘴、陰影與其他 Shell 圖形由本倉庫 QML 繪製，沒有額外圖示包或第三方角色素材。
- 名稱「Ditto」與角色設計尚未完成權利審查；G0 不把內部測試工作階段誤寫成公開發布核准。
