# D-52 Ditto 自有程式碼採 MIT

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-10-25 |
| 狀態 | 已決定；只核定自有程式碼授權 |
| 決策者 | 專案 owner Lei-k |

## 結論

Ditto 自有程式碼採根目錄 [MIT LICENSE](../../LICENSE)，著作權行為 `2026 Ditto contributors`。此決定取代 PRD §24.1 與 README 的自有程式碼授權未指定狀態；D-49 的其餘法律責任歸屬不變。

## 依據

owner 於 2026-10-25 指示繼續 Ditto 工作，並先補 MIT 授權；[#200](https://github.com/relvo-labs/Ditto/issues/200) 的本機 issue 快照是本次實作範圍。這是 owner 決定，不是完整法律審查或發行接受證據。

## 考慮過但沒選的方案

- 保留自有程式碼 `UNLICENSED`：不符合 owner 已核定的 MIT 決定，不重開授權選擇。
- 把完整映像、第三方或使用者產物統一改為 MIT：不在本決定範圍，也不能取代各自的權利與義務。

## 影響

- Cargo workspace、第一方 Node 套件及可交付自有 builtin manifest 對齊 MIT；保留所有版本、private 旗標、lockfile、第三方 LICENSE／NOTICE 與測試資料語意。owner／使用者生成物的預設 `UNLICENSED` 不變。
- Linux、Ubuntu、Qt、Wayfire、第三方插件與素材不重新授權。名稱、商標、角色、美術素材、商業模式、Codex 再散布及完整映像的其餘法律裁定仍由 owner 負責；#51 未因此完成。
- `scripts/build-builtin-packages.sh` 會將 manifest 納入 `.dittopkg`；`crates/ditto-store/src/packages.rs::insert` 拒絕相同 id／version 的不同內容。本次只修來源 metadata，保留版本，不打包、不安裝、不改 registry／Profile。下次重新打包／散布前須分配新版本並驗證升版；既有套件與歷史 revision 不得覆寫。
- 授權一致性由 `node scripts/check-license.mjs` 與 `node --test scripts/check-license.test.mjs` 檢查，不代替發行包盤點、獨立審查或 Ready 裁定。

本 checkpoint 的 `.agents/` 為唯讀檔案系統，故紀錄暫存於此並由 canonical 決策清單連結；release-audit skill 與歷史 D-49／G3 補註的待套用 patch 留在 checkout 外的 evidence，交由 coordinator 後續處理。
