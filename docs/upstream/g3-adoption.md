# G3 上游能力沿用與測試矩陣

本紀錄對應 #29／AT-18；在 G2 已落地的模型適配器、工具、會話三類薄轉接上，加入 G3 正式生成能力。沒有新增或改寫 vendored 上游原始碼，也沒有取用 Harness 的 landlock-run／sandbox-local。來源清單與義務沿用 [Cordis 紀錄](cordis-port.md)、[G2 Harness／Codex／proxy 紀錄](harness-g2-port.md)；逐檔摘要以各 vendor manifest 與 pin 為權威。

## 九欄紀錄

| 欄位 | 模型適配器 | 工具 | 會話 |
| --- | --- | --- | --- |
| package | Harness dsh-llm 值模組 0.1.7-rc.2；Codex app-server 0.160.0 | Harness native-dispatch 概念；Ditto DesktopTools | Harness Session 概念；Ditto CoreSessionHandle |
| upstream_repo | deepseek-ai/deepseek-harness；openai/codex | deepseek-ai/deepseek-harness | deepseek-ai/deepseek-harness |
| upstream_commit | Harness `477b4f420553e8a52c2fbccc464d7561b239c443`；Codex standalone 以 tools/codex/pin.json 的 sha256 釘選，不宣稱有未記錄的 source commit | 同一 Harness commit；上游工具執行碼未複製 | 同一 Harness commit；上游 Session 儲存碼未複製 |
| port_kind | 值模組薄轉接；Codex 保留外部宿主 | 薄轉接至 Ditto RPC，實作為 Ditto 自有碼 | 薄轉接至 Core 權威儲存，實作為 Ditto 自有碼 |
| modifications | 9 個 Harness 值檔原樣；Ditto backend／schema adapter 自行實作；G3 新增 uint8／uint16 嚴格格式支援 | G3 加 9 個 development 工具；仍依動態 catalog、intent、授權及回讀，未新增 PTC／run_code | G3 artifact 只保存最小來源；刪除對話遮蔽來源，worker 不複製摘要；原會話 writer fence 不變 |
| host_contract | 一個 Core 啟動的 Agent controller，受限 Codex 經私有 stdio；無第二個自主迴圈 | 同一 Agent 程序，所有副作用經 Core；生成測試共用兩槽工作池 | 同一 Agent 的 Cordis agentSessions service；持久資料由 Core 寫入 |
| trust_level | 第一方適配器可信，模型回應不可信；assembler 不是沙箱 | 第一方代理可信，工具參數不可信，不能自宣告 caller／授權 | 第一方代理可信，對話內容不賦權；無第二份正式會話 |
| license | Harness MIT，保留 LICENSE；Codex Apache-2.0／standalone 再散布仍待 D-11／G4；proxy LGPL-2.1-or-later | Ditto 自有實作目前 UNLICENSED（Cargo workspace；尚無專案開源授權）；實際 bundled Harness 檔仍附 MIT | 同左；未把主專案授權套用到未複製的上游程式 |
| test_matrix | agent-runtime codex/direct/harness 測試；G3 腳本模型走釘選 app-server 與 assembler；真訂閱另列未執行 | tools／完整工具 strict schema 測試、共享向量、G3 無授權拒絕與生成／修改 | session／Core conversation writer fence 測試；G3 多輪來源歸屬及刪除來源；Agent 退出後面板保留 |

「上游概念」不等於上游原始碼移植。工具、Session 的 bridge 是 Ditto 自有實作，不能寫成複製了 Harness 自帶持久儲存或安全沙箱。上游升版時先重驗 9 檔摘要、Codex／proxy pins、schema 整形與固定測試矩陣；G3 改動都在 vendor 之外，沒有需重套的 vendor patch。

## 四欄沿用對照

| 直接沿用 | 新增 Ditto 橋接 | Rust 原生能力 | 尚未支援 |
| --- | --- | --- | --- |
| Cordis 的依賴、fiber／effect 生命週期；Harness 的純值 assembler／message／brand 等；固定 Codex 外部 app-server | DesktopTools 動態 schema、CoreSessionHandle、模型 stdio／direct adapter、G3 固定 QML 解譯與服務讀模 | revision／ChangeSet、授權、artifact／資料遷移與快照、cgroup／Landlock／seccomp 測試宿主與工作池 | Harness 自主 Agent、PTC／run_code、任意生成 JS／QML／原生庫、通用 migration 腳本、每個插件獨立 Node sandbox |

## G3 native runner 的取用

Rust generation-host 與 C++ runner 為 Ditto 自有程式，呼叫現有 ditto-confine；沒有新增第三方 source port。連結既有固定 Qt SDK 的 Core／Gui／Qml／Quick，另加入 Qt6Test 執行期依賴（Qt 6.10.2 gcc_64，來源見 packaging/reference-image/source-builds.lock）。本機 QtTest/qtest.h 的 SPDX 為 `LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only`；版本、來源、對應授權文本與重新連結／源碼交付仍須納入 G4 的完整 shipping 盤點，本文不宣告發行授權審查完成。

## 執行證據

本次開發機：全部 Node 工作區測試、Agent schema 與工具測試、`check:upstream` 9 檔摘要及 `check-vendor-manifest --working` 通過，vendor 修改為 0。G3 真 Core／Shell／釘選 app-server 的腳本模型完成兩類生成、多輪新版本、拒絕授權、來源刪除與 Agent 退出後存活。完整檔案及 VM 結果見 [G3-exit](../../.agents/notes/gate-reviews/G3-exit.md)，屬開發證據；AT-18 最終由 owner 文件審查裁定。
