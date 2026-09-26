# G0 中文輸入法橋接：Wayfire input-method-v1

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-23 |
| 狀態 | 已決定；實體登入驗收待完成 |
| 決策者 | 平台工程 |

## 結論

Ditto 的 Wayfire 工作階段採用 Qt `text-input-v3` → Wayfire `input-method-v1` bridge → Fcitx5；停用 Wayfire 的 `input-method-v2` workaround，兩條輸入法橋接不得同時啟用。

## 依據

- 實體登入 session 的 v2 路徑中，Fcitx 已選 `pinyin` 且 QML input context 有焦點，但實體鍵盤輸入直接提交 `nihao`；Wayfire 同時記錄 `trying to map IM popup surface without text input`。
- 切到 v1 bridge 後，`tests/g0/input-method/run.sh` 以同一 QML 控制項實際回讀到 `你好`。原始證據為 `artifacts/g0/input-method-2026-09-22T16:58:05Z-6dfa.json` 及同 run id 的 QML、Fcitx、Wayfire 日誌。
- Wayfire 0.11.0 的插件 metadata 將 `input-method-v1` 描述為 Fcitx5 正常運作所需；上游發布說明亦指出 v1 在多數情況較可靠，v2 因此預設關閉。

## 考慮過但沒選的方案

- 保留 `input-method-v2` 並只修 Fcitx profile：引擎與焦點回讀成立後仍無中文提交，排除單純設定問題。
- 同時啟用 v1 與 v2：Wayfire 原始碼明確記錄這是錯誤組合，會產生兩套競爭的輸入法 relay。
- 修改 Wayfire core 的 v2 relay：在上游已有專為 Fcitx5 提供的 v1 bridge 時，先採上游支援路徑；若 v1 實體驗收仍失敗才考慮維護本地 compositor patch。

## 影響

- `packaging/reference-image/session/wayfire.ini` 與隔離測試夾具載入 `input-method-v1`，並明確停用 `workarounds/enable_input_method_v2`。
- C-08 的合成器要求由固定 `input-method-v2` 修正為「Qt text-input-v3 加上已驗證的合成器輸入法 bridge」。
- 自動 QML 提交已有開發證據；EX-08 仍須在登入工作階段完成實體鍵盤、候選窗位置、foot、Kate 與三方剪貼簿驗收。
