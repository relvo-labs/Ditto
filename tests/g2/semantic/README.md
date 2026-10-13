# G2 語意任務集（G2-QA-01）

`tasks.json`（固定集）與 `holdout.json`（保留集）各 50 題：繁中 25、英文 25；外觀 8、布局 8、插件與通知 8、設定檔與撤銷 8、多輪與模糊 10、限制與恢復 8（[plan/04/07 §2](../../../plan/04/07-verification-and-measurement.md)）。保留集涵蓋同類意圖的不同措辭、順序與代稱，不是字串替換，也不得寫進 prompt 或 parser 特例。

## 判定

`oracle.mjs` 只看 Core 的回讀：正規化後的 Profile（entries 以套件為鍵、slots 指向套件）、設定檔清單、視窗幾何（相對工作區）、工作區、Agent 經 turn trace 產生的 ChangeSet；只有預期結果是詢問、拒絕或說明時才看回答文字。模型自述的成功不計。

每題：

- `expect.checks`：述詞（JSON pointer、色相／亮度、區域容差、設定檔、工作區、回答關鍵詞）。
- `expect.outcome`：`change`（至少一個 Agent ChangeSet committed）、`action`（Profile 以外的直接動作，如另存、改名、切工作區）、`answer`／`clarify`／`refuse`／`unsupported`（沒有 Agent ChangeSet；`clarify` 另須提問）。
- `expect.allowed`：允許變動的路徑；其餘欄位的雜湊必須與任務前相同。切換設定檔的題目以 `skip_untouched` 改用明確述詞。
- 不可逆副作用（刪掉任務前已有的設定檔、關掉夾具視窗）上限 0；本人同意刪除的題目另設上限。
- `setup.person.allow`：本題的本人會同意哪些 approval（能力 → Core 顯示的對象名稱）。其餘 approval 一律立即拒絕，如同不在座的人。
- `reference`：參考解，只給自我檢查用。

oracle 版本記在每份摘要（`oracle_version`）；不同版本的分數不可直接比較。

| 版本 | 變更 |
| --- | --- |
| 1 | 初版 |
| 2（2026-10-09） | 回答關鍵詞比對前把彎引號（`’`）視同 `'`；F-D08／H-D08 的「預設設定檔」改指 store 裡名為「預設」的設定檔（v1 指向 driver 自建的 `semantic-base`，模型無從得知） |
| 3（2026-10-09，[D-43](../../../.agents/notes/decisions/2026-10-09-d43-semantic-holdout-and-judging.md)） | 「詢問」不限問號：問號或 `REQUEST_PHRASES` 封閉清單裡的請求用語；F-F04／H-F04 改為點名兩個設定檔、本人（`setup.person`）經 approval 同意後刪除才通過（`deletions_approved`） |

## 執行

```text
tests/g2/semantic/run.sh --tasks fixed|holdout [--self-test|--null] [task id ...]
```

| 模式 | 做什麼 | 意義 |
| --- | --- | --- |
| （預設）model | 每句經 Shell 聊天所用的同一對話 API（`agent.turns.submit`）交給 Agent 與真實模型 | QA-01 的語意分數 |
| `--self-test` | 由 CLI 套用參考解 | 證明夾具與述詞可滿足；不是分數 |
| `--null` | 什麼都不做、回答為空 | 每題都必須失敗；有一題通過即表示述詞空洞 |

model 模式使用 `tests/g2/codex/subscription.mjs` 登入的訂閱（同一個 Core store 與使用者的 session bus 上的 keyring），沒有登入時記 `not_run`。桌面是巢狀 headless Wayfire、真 Shell、hostd、Agent 與 `ditto-confine` 內的 Codex app-server，視窗為 Firefox、foot、Kate，與登入中的 Ditto 互不干擾。

逾時（每 turn 300 秒）記失敗；回合因 `provider_unavailable`、`rate_limited`、`provider_timeout`、`keyring_locked` 結束的題目另列 `infrastructure_errors`，整組重跑，不挑成功的輪次。

## 開發環境限制

headless 夾具裡的 Firefox 不接受 configure 給的寬度（浮動視窗的尺寸只是建議）；Core 等到用戶端提交後才判定，因此這些放置會被誠實回滾，而不是假裝成功。開發機可用 `DITTO_SEMANTIC_BROWSER=chrome` 以 Chrome 代替瀏覽器練習布局題；參考機出口跑 Firefox。`DITTO_SEMANTIC_TRACE_WINDOWS=1` 會在每題後取樣視窗幾何供診斷。

## 開發證據

`--self-test`：固定集與保留集各 50／50；`--null`：兩組皆 0／50（v1 2026-10-08、v2 2026-10-09；Chrome 代替瀏覽器，開發機，不是分數）。真實模型（開發機巢狀桌面，不是參考機出口）：v1 固定集 42／50、保留集 41／50；v2 固定集 45／50、保留集 46／50。逐題分類見 [G2 評審](../../../.agents/notes/gate-reviews/G2-exit.md) §3.4。
