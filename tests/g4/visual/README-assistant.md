# R3 助理驗證（#67）

Owner Neil 於2026-10-19選定 **D1／56／E1**。Shell的AssistantSurface instance僅在既有assistant presentation路徑選用 `entryStyle: "fab"`、`symbolVariant: "ditto"`；元件固定56 px與E1兩段啟動，沒有未選尺寸／展開方式的開關。`capsule`、`neutral`、`portrait`接點與其測試保留。Core／Profile、已儲存文件、開發／簡報、legacy avatar與會話安全契約不變。決策歷史見 [D-48](../../../.agents/notes/decisions/2026-10-17-d48-default-assistant-entry.md)。本次追加已備於 `fab/evidence/repair1/d48-addendum.patch`，sandbox的.agents為唯讀，待coordinator套用；原結論不改寫。D1授權仍**未釐清**，來源與修改見 [SOURCES](../../../shell/assistant/SOURCES.md)。

E1第一次click／Enter／Space展開「助理＋真實狀態」標籤膠囊（約195×56），第二次才經原activated路徑開同一compact ChatPanel。Escape收合不取消turn／approval；ChatBody保留IME composing guard。hover／focus僅0.96回饋，press 0.90，120 ms OutCubic；reduced-motion／隱藏會settle。沒有新增快捷動作或聊天權威。

## 視覺修正與 oracle

- D1仍引用既有body.png，35 px顯示，按device pixel ratio作3×解碼（DPR 1為105 px），smooth／mipmap。圓底加深、外環固定，不隨working pulse淡去。像素量測符號外環核心對實際膠囊填色，非只比token；淺色由約1.43:1到6.89:1，legacy約7.85:1，目標≥3:1。抗鋸齒邊緣不冒充核心對比。
- 預設淺色DockPill中心離底46 px（edgeGap 12＋pillThickness 68／2）；AssistantSurface用具名常數及出處註解，測試直接比較實際provider幾何。1280×800收合／標籤均從y=740修到754，中心差−14→0 px，右距32 px。未編輯provider，也不決定#46移動。
- chat.open驅動第二圈可見輪廓和Accessible「對話已開啟」文字；包含圓形FAB、標籤膠囊、reduced-motion與legacy theme。這是當前開啟狀態，不改任務投影或操作。
- E1第二次啟動重現compact範例按鈕超出右界16 px。只在有entryRect的assistant compact啟用boundedSuggestions：按鈕保留既有16 px外邊距，完整文字在其內換行、保留原Accessible name與操作。legacy compact（entryRect=null）與full維持原單行版。ChatPanel只新增該padding opt-in，ChatBody只改範例排版。

## 重跑與證據

Qt／PATH依common-b8；全部是development，Core、session／turn／approval、輸出及layer-shell／FloatingWindow為fixture／替身。不是Wayfire、真模型、實體輸入或NFR證據。

```sh
bash tests/g4/visual/run-assistant.sh /data/hermes/ditto-runs/g4-impl/fab/evidence/repair1/after
DITTO_ASSISTANT_CAPTURE_OUT=/data/hermes/ditto-runs/g4-impl/fab/evidence/repair1/after bash tests/g4/visual/run.sh /data/hermes/ditto-runs/g4-impl/fab/evidence/repair1/visual
bash tests/g4/motion/run.sh /data/hermes/ditto-runs/g4-impl/fab/evidence/repair1/motion
```

- `unit/tst_assistant.qml`：既有七態、終態與離線原因、IME policy、capsule／neutral／portrait與32項合計；FAB僅56／E1，驗證首次展開不開聊天、鍵盤、透明圓角及reduced-motion。
- `assistant/tst_assistant_flow.qml`：同一ConversationState、草稿／串流／歷史／approval、E1兩段鍵盤啟動、Escape、縮放Region與取樣；X→Y回焦policy、legacy compact四角像素／幾何與pre-candidate capsule三theme oracle保留。
- `assistant/tst_assistant_repair.qml`：四項缺陷的實際像素／幾何、a11y與邊距回歸；`REPAIR_MEASURE`輸出原始數據。RED在366f174的來源上得到7項行為失敗，非compile失敗，見repair1/red/visual-regressions.log。
- `capture/tst_assistant_capture.qml`：D1-56-E1共11場景（收合、hover、focus、標籤展開、working收合／展開、open標籤／圓形、reduced-motion、legacy theme、全桌面），加原normal／legacy各六場景，共23張1280×800。normal依新Shell選擇；legacy仍用原avatar。正常動畫保留並等待有限過渡完成，working pulse持續是有意的狀態提示。

PNG只存repo外的repair1證據目錄，不進git。前後裁圖／量測總索引為 `/data/hermes/ditto-runs/g4-impl/fab/evidence/repair1/repair1.md`；runner逐張索引為after/assistant-captures.md，JSON記錄fixture、幾何、renderer、source／commit／PNG hashes，profile_hash=null。全桌面使用真正staged頂部列及Dock，無乾淨桌布，沒有拿需求JPEG當壁紙，不宣稱忠實還原或owner最終接受。

stage只移除有紀錄的layer-shell行、替代stub enum、提供FloatingWindow Item替身。legacy avatar掛載／Avatar.qml／ApprovalWindow.qml原始碼oracle保留（avatar按合併過對比修正的f99b4ea比對；其餘25c0b72）。既有schema shape checker仍可離線執行：

```sh
git show 25c0b72:schema/profile-document.json > /path/to/evidence/profile-document-base.json
node --experimental-strip-types tests/g4/visual/check-assistant-contracts.mjs /path/to/evidence/profile-document-base.json
```

實體Wayfire input region／回焦、IME、Orca、多屏熱插拔與NFR均未執行，交原驗收項。此runner的canonical i18n位於scripts/lint-shell-i18n.mjs；若Node啟動lrelease遭EPERM，保留BLOCKED並直接lrelease／cmp作補充，不以替代檢查冒充canonical通過。原R3的socket／IPC限制亦不由本slice解除。
