# D-48 新預設的右下助理入口

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-17 |
| 狀態 | 已決定（新預設改助理）；符號待 owner 決定 |
| 決策者 | owner（需求）；agent（可逆實作選擇） |

## 結論

新 store 的「預設」組合右下改成單一、有標籤的助理入口，不再放重複 Ditto。助理呈現是 default-only 改動；三份新內建組合仍依 #69 契約共用 appearance，optional avatar、舊 Profile、安全、無角色能力全部保留。桌布大型 Ditto 目前是靜態規劃，素材與權利未定。

## 依據

owner 2026-10-17 要求：「預設畫面做到提供的桌面效果圖一樣……因桌布已有 Ditto，右下改成助理，不再放重複 Ditto 角色」（[#64](https://github.com/relvo-labs/Ditto/issues/64) 首段）。實作切片見 #67、#46、#47 與 [design-contract §5](../../../docs/design/default-desktop/design-contract.md#5-右下助理不另造吉祥物或聊天系統)。

## 考慮過但沒選的方案

- 全域改 AvatarSettings::default() 或關閉舊角色：改掉舊文件意義。
- 以 theme、hidden 或 entry config 猜呈現：前兩者已有不同語意；已註冊 entry 沒有此設定，avatar 是 Core 內建呈現。
- 另建聊天或常駐 Agent：分裂會話及授權權威。
- 重畫 Ditto 頭像：違反去重要求。提供可替換中性符號與非 Ditto 幾何小頭像，暫用中性符號；待 owner 決定。

## 影響

| 需求 | optional avatar | 新預設助理 |
| --- | --- | --- |
| AVA-01／02 | 保留本機呼吸、眨眼、注視要求 | 可見按鈕與焦點，不虛構角色動作 |
| AVA-03／04／06 | 保留角色開啟同一對話 | 單一膠囊、同一 ConversationState、真實狀態文字、草稿／串流／歷史 |
| AVA-05、AT-12 | 遮擋、透明命中與喚回仍交 #46 驗證 | 命中限膠囊、快捷鍵喚回、待機不搶焦點 |
| AVA-07、AT-21 | 移動、縮放、隱藏、動畫設定不改 | 沿用 output／corner、enabled／hidden，無入口仍可快捷鍵對話 |
| AVA-08 | 無障礙保留 | IME、鍵盤、文字與回焦整合；實體走查交 #47 |

新 store「預設」改 `soft-jelly-light`、`dock_pill`，兩項均為 **agent 依 #71 交接實作，owner 可反悔**（[component-sheet](../../../docs/design/default-desktop/component-sheet.md) H1／H3）。依已合併 #69 的共用 appearance 契約，新 store「開發」「簡報」也複用「預設」完整 appearance（相同 `soft-jelly-light`、tokens 與其他外觀欄位）；用途組合的供應者／布局／通知／avatar 選擇維持原定義。助理呈現仍只由「預設」設定 `avatar.presentation = "assistant"`；「開發」「簡報」不設定該欄位（legacy），「簡報」保留 hidden／animations 設定。既有 store 不遷移、不重寫。

2026-10-17 repair1 依 coordinator 在 `8efaa35` 的完整 Core gate（124 過／1 失敗）修正共用 appearance；保留 `builtin_switches_read_back_without_rewriting_documents_and_can_be_undone` 的完整 appearance 比較斷言，不以放寬測試解決。

Core 持有 optional typed `avatar.presentation`；absent＝legacy 且省略序列化，不改 AvatarSettings::default()，僅新增值 assistant。沿用既有 Profile／ChangeSet／投影保存與回讀，不新增能力或寫入路徑。

相容政策：schema version 1 與 RPC 版本不變（新增選用欄位）。新版讀舊文件不遷移，digest 不變。舊版 deny_unknown_fields 會拒絕含 presentation 的文件，**不具前向相容**；匯入先驗證，未知欄位不可忽略後執行。沒有自動降版或靜默刪欄位；降版前由新版明確移除呈現意圖、保存及匯出，以舊 schema 驗證，保留原始匯出／store 備份。禁止舊程式直接開含新文件的 store；Core／Shell 同版配送，混版不支援。測試以基底 schema 證明拒絕與明確降版後可讀。

PRD 只更新 §11.1／AVA-03，其他需求、NFR 與出口不變。此為新決策，未覆寫 milestones 既有待決策項。
