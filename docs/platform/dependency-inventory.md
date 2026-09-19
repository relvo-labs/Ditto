# G0 依賴與授權盤點起點

此清單跟隨第一批 G0 程式碼建立。版本取自 `Cargo.lock` 與 `pnpm-lock.yaml`；CI 的 [`licenses.yml`](../../.github/workflows/licenses.yml) 會輸出完整 Cargo metadata 與 pnpm 依賴授權清單供逐項審查。**這不是發行前授權審查完成的聲明**；NOTICE 彙整與系統套件的正式版本待平台凍結。

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

`tools/dev-wayland` 的 Debian 容器與 Sway、Qt、Quickshell、wayland-utils 目前只供無 GPU 開發測試，不是正式參考映像或發行包。正式平台套件、來源與授權在 D-01／D-03 凍結後另行盤點。
