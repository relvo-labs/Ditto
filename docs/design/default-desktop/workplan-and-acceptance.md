# 工作順序與可驗收條件

這是新增視覺研究線的執行安排，不取代 G4 #42 或原 NFR。#43／PR #62 的階段文件與不相關工作繼續，不等這份研究實作。

## 1. 依賴與並行邊界

| Slice | 可開始的工作 | 依賴／停止點 |
| --- | --- | --- |
| S0 契約／資產 | R1 資產來源、元件與 token；R2 動態狀態表；R3 呈現與相容性設計；R4 證據 schema | 素材散布要經 #51；R3 先更新權威差異。可以平行研究，不等整張大型 issue 關閉 |
| S1 第一個原生畫面 | R1 材質與構圖＋#45 預設綁定；R3 最小助理入口；#46 legacy、#47 鍵盤／可讀性 slice | 乾淨桌布與所需圖示、呈現契約；若缺素材不得宣稱忠實還原 |
| S2 動態與降級 | R2 依同一原生 slice 接 motion、interrupt、capability fallback | S1 的具體元件幾何；#52／#53 量測接點 |
| S3 聯合驗收 | R4 聚合視覺、狀態、輸入、NFR、易用性 | 各對應 slice 可運行；#49 實體多屏、#57 真測試者可另排，不偽造補件 |

實作前每個 PR 列出寫入範圍。`shell/shell.qml`、`defaults.rs`、Profile／schema、共用 Tokens 同時只能一個 writer；例如 R1 管材質，R3 管助理整合時先合併共同基底，再將小 slice 疊上去，不讓兩個代理改同一檔。此規劃不授權 merge。

## 2. 驗收矩陣

| ID | 證據與 oracle | Owner／重用 |
| --- | --- | --- |
| V1 構圖 | 原圖與原生 QML capture 同 1280×800、scale 1，固定比較場景；錨點／層次逐元件並排與疊圖，不只看全圖相似分數 | R1＋R4，#45 |
| V2 材質 | canvas、正文底、邊框、圓角、高光、陰影、Dock 圖示各自核對；不同 wallpaper／contrast／solid 模式；每個偏離都有理由和 owner 確認 | R1，#47／#51 |
| M1 動態 | 首次呈現、hover、pressed、展開、反向／連點、掉幀、移屏、終態與隱藏清理；有原生樣本錄影，不能用圖猜動畫 | R2，#52／#53 |
| S1 助理真狀態 | 七態＋starting、approval、preview、cancelling、partial、unknown、offline／reconnect；對照同一 Core session／turn／change；收合不取消、重連不重播 | R3，#56 |
| S2 相容性 | 舊 Profile 無新欄位、有完整 avatar 設定、hidden／disabled／animations=false；匯入匯出、切換、undo、restart／hotplug；不重寫非改動欄位或讓已選角色消失 | R3，#46／#49 |
| A1 輸入／可及性 | 鍵盤完整操作、繁中實體輸入法 preedit、候選 Enter／Escape、大字、Orca；不搶焦點、無陷阱、候選窗不裁切、狀態不只靠色／動作 | #47 主責；R3 對助理整合 |
| P1 原 NFR | 完整程序清單與同場景 A/B：正常、減少動畫、降低透明、低效能／software；分報 frame time、喚出、CPU、PSS、GPU，不把救援成本冒充完整桌面 | #52／#53 主責；R2／R4 接結果 |
| U1 易用性 | 找助理、找 app、回原視窗、跨工作區、待確認辨識、拒絕、停止、撤銷、離線恢復；記完成／協助、時間、誤送、焦點遺失與復原 | #57 主責；R4 增補這些任務，不另造招募樣本 |

### 現有 gate 不變

依 [PRD §19](../../product/Ditto-PRD-v0.4.0.md#19-非功能需求與量測基線) 與 [驗收矩陣 §2](../../../milestones/01/04-verification.md#2-非功能指標量測)：

- NFR-02：暖態喚出 p95 ≤150 ms、200 次；冷態另報。
- NFR-03：簡單本機操作 p95 ≤100 ms、200 次，不含 LLM。
- NFR-05：指定操作至少 95% 幀 ≤16.7 ms，隱藏停止非必要渲染。
- 分層資源、三次重複、暖機／採樣、GPU、排除清單依原程序與核定預算。
- #57 維持原至少 5 人、80% 無工程協助完成核心任務，沒有改成研究新數字。
- 效能／動畫／資源的正式出口仍在實體參考機；VM／圖片／來源掃描不能代替。開發原生 capture 與 VM 結果保留其證據類別。

錨點偏差、找入口秒數、90% 任務率等可以在 pilot 提案，但本計畫**沒有核定新數字**。任何新增契約門檻先讓 owner 確認；新數字不能替換原 NFR 或被當成已達標。

## 3. Capture 與證據欄位

每筆記錄：build／commit、Profile ID／document hash、場景 ID、viewport／scale、renderer／compositor、driver／平台、素材 hash、motion／transparency 模式、真實／fixture 標記、operation IDs、結果與原始檔位置。靜態原圖只作目標，不作 runtime 證據。

必要場景：首次登入、雙窗對照、Dock／launcher、助理收合／compact／完整視窗、approval／preview、未知／部分完成、離線／重連、dark/non-default legacy、低特效、鍵盤／IME、大字、多屏。沒有 capture 或尚未量測的格子保持未執行。

## 4. 待核定但不阻擋本次發布規劃

- 乾淨桌布與圖示來源／授權；不從效果圖剪出視窗與狀態做假桌布。
- 助理名稱與符號：依 owner 決定交付非 Ditto 小頭像或中性符號，不預設其中一個。原圖的左側小 Ditto 頭像依需求替換，定案列入偏離帳；需候選時附原生樣本供確認，不擅自定新品牌人物。
- 左上 `01 — SOFT JELLY` 與副標是 caption、桌布還是真 widget：先核定，不硬編、不裁切，也不默默省略。
- Files／Notes 的真實應用與首次登入是否自動開啟；在決定前保留對照場景要求，不把兩窗默默刪掉。
- 天氣／文字是否功能化：預設不新增未授權外部天氣服務；若要功能化再定資料、位置權限、freshness、離線與錯誤。
- R3 的 Core 呈現契約／default-only authority 更新。新預設改助理是已明確要求，技術方案與 legacy 遷移不得由 screenshot 猜。

以上決策未完成只阻擋相依實作 slice，不阻擋 R1～R4 研究、#43 文件或不相關 G4 工作。
