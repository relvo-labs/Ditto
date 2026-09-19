# 角色素材來源

| 檔案 | 來源 | 授權狀態 | 備註 |
| --- | --- | --- | --- |
| `body.png` | `apps/desktop-prototype/public/ditto-body.png`（凍結原型） | **未釐清**，發行前必須確認 | 身體層；本檔只登記來源，不做法律判斷（`ditto-release-audit`） |
| `hit-mask.json` | 由 `tools/avatar-mask/generate.py` 從 `body.png` 的 alpha 通道產生 | 隨 `body.png` | 建置期產生，不逐幀計算 |

眼睛、嘴與陰影目前由 QML 繪製，不是點陣素材；原型素材本身沒有臉部圖層。若之後改用美術提供的分層素材，必須在此表補登來源與授權，並重新產生命中遮罩。
