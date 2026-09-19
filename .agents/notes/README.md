# Ditto 決策紀錄

本目錄保存**無法從程式碼、測試或 git 歷史讀出來**的決定：為什麼這樣選、考慮過什麼、影響了哪些階段。

格式、判準與撰寫程序見 skill `ditto-decision-record`（[SKILL.md](../skills/ditto-decision-record/SKILL.md)）。本檔只說明目錄結構。

## 結構

| 目錄 | 內容 | 檔名 |
| --- | --- | --- |
| `decisions/` | 待決策清單落定、與計畫不同的核定值、值得記住的否決 | `YYYY-MM-DD-<kebab-slug>.md` |
| `gate-reviews/` | 階段出口評審結果 | `G<n>-exit.md` |

## 規則

- 每則決策紀錄同時回寫 [milestones/01/05 §2 待決策清單](../../milestones/01/05-risks-decisions.md) 的對應列。
- 紀錄不刪除。決策被推翻時，把舊紀錄狀態改為「已推翻」並與新紀錄互相指向。
- 尚未定案的討論是**待決策**，加入 `milestones/01/05` 的清單並設定最晚時點，不放進 `decisions/`。

目前兩個目錄皆為空：首次決策發生在 G0（最早為 D-02 合成器選擇與 D-06 資源預算核定）。
