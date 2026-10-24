# #190 快捷鍵設定 UX 候選計畫 v0.1

本計畫是未選定預覽；owner 視覺選擇、獨立審查及最終 gates 仍待執行。T2／唯一 writer；base `48593c3383353e25f07b6f247ae834cb92064911`，分支 `hermes/feat-190-shortcuts-ux`。不部署、不接 VM、不發布 PR。

## Design Read

- 現有 `PersonalizationCenter.qml`（legacy／provider）以固定 140／200 寬度顯示原始 chord、命令、狀態、移除；沒有編輯／取消。加入後立即清空欄位，非同步錯誤無法恢復原輸入。先用乾淨 archive 跑行為 RED 與原版渲染，保留證據。
- 延續 Soft Jelly J1／既有 tokens、系統字型及 CJK fallback、Button／Choice／TextField、語意 warning/error；標題與動作在前，鍵名分開顯示（Space → 空白鍵／Space），不改實際 chord。使用原本間距、圓角、焦點環，不加裝飾動畫／依賴。設計差異 3／動作 1／密度 5（描述用，非量測分數）。窄版以垂直堆疊與 Flow 換行，保留控制清單，沒有矩陣。
- A：按列編輯，草稿緊貼目標；B：清單下方的集中編輯區。兩者同資料、視窗、語言及狀態渲染。A 可在隔離分支作未選定提案；B 僅存 evidence/prototypes，不交付兩套 runtime 架構。

## 契約與界線

- Core 是 `/shortcuts`、revision 與 ChangeSet 唯一權威。Shell 僅保有短暫草稿及提交時 snapshot；沿用 `client.propose` 和 `before`／`baseRevision`，不改 Rust、schema、Wayfire 或 reserved keys。
- `desktop.shortcuts.list` 提供 reserved／conflict／bound／binding_path，沒有可捕捉全域鍵的介面；僅提供文字輸入及語法範例。前端只提示精確字串重複／reserved，不新增鍵盤正規化政策。Core preflight 仍為裁決，plugin conflicts 未完整列在此查詢。
- coordinator 對 `/shortcuts` 啟用 timed revert。保留草稿、鎖住寫入直到確認結束；以 `changes.get`／changeUpdated 查同 change；只有 committed＋confirmed/not_required＋profiles.get 回讀目標與 committed_revision 一致才清空。失敗、回復、未知及 readback 失敗保留輸入，不自動重送。
- personalization provider 由 1.0.0 升到 1.1.0：內容已變動，不覆寫 immutable id+version。不改既有 Profile 鎖定。

## 步驟與證據

1. 原版行為 RED（輸入保留、pending interlock、缺 edit）及完整 QML 原版擷取；所有 fixture 明示 offscreen，非 VM／Core 證據。
2. 共用 shortcut UI 與單一 transaction path，provider／legacy 相同；測 create/edit/cancel、reserved/duplicate、pending/confirmation/revert、失敗保留、confirmed authoritative readback、鍵盤與窄版。
3. A/B 清單／編輯／衝突／失敗／pending，zh-TW 相同 viewport 加窄版及 en，實際 Qt render。截圖不作 save 證明；回讀另有可控 protocol double 及可行的真 Core reproducer。
4. focused tests、i18n、QML lint（與 baseline 警告比較）、provider package/version witness、相關 shell extension tests、diff --check。首個 meaningful checkpoint commit 後立即寫 evidence/checkpoint.json／Draft packet。保留所有失敗，不 skip。
5. evidence/result.json／result.md 記錄 exact HEAD、commits、檔案與捕捉路徑、未驗限制，狀態 `waiting_for_owner_visual_selection`。Parent 才能 push／發布 Draft。此 UX 開發證據對應 DES-05／CFG-05～06／CHG-04～09 與 AT-10／11 的局部路徑，不宣稱完整 AT 或人類可用性通過。

## Checkpoint 與延續驗證

- 第一個 commit `68884d3` 已建立 Draft request packet 與 evidence/checkpoint.json；此處仍未選定、未發布、未部署。
- 延續檢查加入真正 Qt key events 的新增／Tab／方向鍵／Enter 路徑；試用期間另回讀已 committed 的新按鍵，但草稿必須繼續鎖住且可見。重複舊事件不得清空下一份草稿。
- 原版三項 RED 保留；原版／A／B 各 24 張實際 offscreen 圖（zh-TW/en、兩種 viewport、六狀態）。同一 protocol double 檢查 UI 輸入、confirmation 及回讀判斷，Core 既有契約測試另驗保留鍵、限時保留、回讀回復及過期基底。沒有端到端實體 compositor save／鍵盤擷取證據。
- `shell/` lint 基底 248 warnings、候選 228；新 helper 無 lint warnings。legacy Section／StylePicker 的動態主題及 teardown warnings 以原版控制記錄比較；不擴大此 task 修復。shell extensions 46 tests 通過，五個 packaged pages 真 Quickshell 載入；此 runner 的長 UNIX socket 路徑令 IPC listener 啟動失敗，沒有當作 IPC 驗證通過。
- 最終數字、來源 hash、截圖、版本 witness、已知限制與失敗原始日誌統一在 task evidence/result.json／result.md。完整 G4、獨立審查與 owner 視覺選擇仍待後續。
