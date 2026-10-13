# DeepSeek Harness 參考與啟發紀錄

| 欄位 | 內容 |
| --- | --- |
| 上游 | [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（DeepSeek-AI） |
| 授權 | MIT，Copyright (c) 2026 DeepSeek |
| 本文用途 | 記錄 Ditto 從 Harness 得到的設計啟發、實際取用的程式碼位置、Ditto 自行新增的部分與署名義務 |
| 不在本文 | 逐套件的九欄移植紀錄（package、commit、修改集、測試矩陣等），見下方 §3 列出的紀錄；本文不重複 |

Ditto 的架構方向深受 DeepSeek Harness 啟發。Harness 主張「Everything is a Plugin」：以 [Cordis](https://github.com/cordiverse/cordis) 的 Context、服務依賴與可逆副作用組合整個 agent 執行環境，並以 Profile／Bundle 決定組合。Ditto 把同一個想法搬到 Linux 桌面：桌面的外觀、布局、操作方式與功能都由插件組成，對話與 GUI 操作同一組能力契約。

Ditto 是獨立專案，與 DeepSeek 沒有隸屬關係，也沒有取得 DeepSeek 的背書。

## 1. 參考的上游版本

| commit | 日期 | Harness release | Ditto 用途 |
| --- | --- | --- | --- |
| `477b4f420553e8a52c2fbccc464d7561b239c443` | 2026-09-24 | `dsh` 0.1.7-rc.2 | Cordis vendored fork（G1）；G2 取用的值模組 |
| `ddefc45fbc7f8e46dd73185e68295696d1297887` | 2026-09-17 | `dsh` 0.1.6-alpha.2 | SDK 協定形狀參考（G0，未複製程式碼） |

計畫成立前的調查讀過的 Harness 文件與原始碼範圍列在 [milestones/01/00-findings.md](../../milestones/01/00-findings.md) §1、§4。Harness 目前標示為 developer preview，會有不相容變更；Ditto 一律依固定 commit 取用，不追浮動版本。

## 2. 借鑑的設計（概念，未複製程式碼）

下表是 Ditto 採用的設計想法。「Ditto 的落點」描述 Ditto 自己的實作；它們沿用了 Harness 的思路，但不是 Harness 程式碼。

| Harness 的設計 | Ditto 的落點 | 依據 |
| --- | --- | --- |
| Everything is a Plugin；Cordis 的 Context、`inject`、可逆的 effect 註冊 | `ditto-hostd` 以 Cordis 組合桌面服務；替換供應者不改消費者（DES-10、MOD-03） | 00-findings §4.1 |
| Profile／Bundle 與 `cordis.patch.yml` 的有序疊加，條目以穩定 `id` 定位 | Ditto 的 Profile、Bundle 與 revision；配置權威改在 Rust Core 的 SQLite，不採 YAML 回寫 | 00-findings §4.2、R1 |
| seam 三角：Service Definition／Provider／Consumer | 每個 `desktop.*` 能力同時交付三者才算完成 | 00-findings §4.3、R3 |
| `ctx.approval`：四種結果、`ask`／`never` 政策、失敗即拒絕 | Core 的 approval 流程，由 QML 介面應答（G2，PR #13） | 00-findings §4.4、R5 |
| `ctx.sessions`／`SessionPersistence`：只追加事件、「模型看得到的就已記錄」 | 會話由 Core 持有，Agent 退出後仍可查閱（G2，PR #13） | 00-findings §4.4、R4 |
| `ctx.jobs`、`ctx.credentials`（引用與值分離） | 有上限的工作池；秘密以引用存在 keyring，不進配置（G2，PR #13） | 00-findings §4.4 |
| `sandbox-local` 與 `native/system` 的 `landlock-run` | G3 隔離測試宿主的參考方向，**尚未實作** | 00-findings R6；milestones/01/03 G3-HOST-01 |
| `plugin-manager`：安裝與啟用分離、失敗還原 | 插件中心的安裝／啟用分開記錄 | 00-findings §4.4 |
| `packages/sdk` 換行分幀 JSON-RPC | Core 協定的訊息形狀；傳輸改為 Unix socket | [harness-sdk-protocol-shape.md](harness-sdk-protocol-shape.md) |
| `apps/desktop` 單實例獨占 profile 目錄 | Core 獨占 Profile 的所有權模型 | 00-findings §4.4 |
| `.agents/skills` 加上 `.claude/skills` 符號連結、任務導向的 skill 寫法、生成索引的標記區段 | Ditto 的 `.agents/skills` 結構與 `lint-skills.mjs` 的生成區段 | [plan/01/01](../../plan/01/01-current-state-analysis.md) §3、[plan/01/06](../../plan/01/06-acceptance-and-validation.md) |
| `verify-cordis-catalog`、`scripts/check-vendor-manifest.sh` | schema 重新產生後無差異的 CI 檢查；同名的 vendor 修改紀錄守門腳本 | [milestones/01/04](../../milestones/01/04-verification.md)、`scripts/check-vendor-manifest.sh` |

## 3. 實際取用的程式碼

| 位置 | 內容 | 取用方式 | 逐套件紀錄 |
| --- | --- | --- | --- |
| `packages/host-runtime/vendor/` | Harness 的 Cordis vendored fork：`cordis`、`loader`、`timer`、`cosmokit`、`schemastery`（`477b4f4`） | 直接沿用，Ditto 修改集為空 | [cordis-port.md](cordis-port.md)、[vendor/README.md](../../packages/host-runtime/vendor/README.md) |
| `packages/agent-runtime/vendor/harness/`（G2，PR #13，尚未合併） | `dsh-llm` 等 9 個值模組檔（`477b4f4`） | 薄轉接，Ditto 修改集為空 | `docs/upstream/harness-g2-port.md`（同在 PR #13） |
| Core 協定 | 僅參考訊息形狀 | 零行程式碼 | [harness-sdk-protocol-shape.md](harness-sdk-protocol-shape.md) |

## 4. Ditto 自行新增的部分

以下不是 Harness 既有的能力，文件與對外說明不得寫成「Harness 已提供」（`ditto-upstream-port` 第 5 步）。來源：00-findings §4.5。

1. 跨程序的能力租約與撤銷。
2. 交易式變更：prepare、健康檢查、切換、回讀、提交或回復。Harness 的 loader 樹變更不是交易式的。
3. 熱換等級與交接。
4. Rust Core 的權威配置與不可變 revision 譜系。
5. 桌面能力層（視窗、工作區、啟動器、面板、外觀、通知）與合成器轉接。
6. 不依賴 Node 的救援模式。
7. 受限生成的產品流程：生成 UI 插件、隔離試載入、真實預覽、啟用。
8. PSS 分層預算與量測報告。

## 5. 授權與署名義務

- 每份複製的 Harness 或 Cordis 程式碼都要保留上游 `LICENSE`。目前 `packages/host-runtime/vendor/*/LICENSE` 隨原始碼保存，G2 的 `packages/agent-runtime/vendor/harness/LICENSE` 隨 PR #13 加入；內嵌 vendored Cordis 的 bundle 由 `packages/host-runtime/scripts/notice.mjs` 在檔頭加上授權聲明。
- 本紀錄只說明啟發與來源，不改變任何授權義務。Ditto 自己的專案授權尚未指定（見 README）。
- 發行前的完整授權盤點屬 G4-PLAT-04，由 `ditto-release-audit` 彙整。
- 引用 Harness 時，使用上游 README 提供的格式：

```bibtex
@misc{deepseek-harness2026,
  title={DeepSeek Harness: Everything is a Plugin},
  author={DeepSeek-AI},
  year={2026},
  publisher={GitHub},
  howpublished={\url{https://github.com/deepseek-ai/deepseek-harness}},
}
```

## 6. 維護

取用新的 Harness commit、增加移植套件或新借鑑一項設計時，更新 §1 至 §3；逐套件的九欄紀錄照 `ditto-upstream-port` 寫在各自的移植紀錄。
