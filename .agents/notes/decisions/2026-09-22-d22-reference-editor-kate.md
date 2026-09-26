# D-22 參考編輯器選擇 Kate

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-22 |
| 狀態 | 已決定 |
| 決策者 | 平台工程＋QA |

## 結論

G0 參考編輯器固定為 Kate 23.08.5（Ubuntu 套件 `4:23.08.5-0ubuntu3`）。EX-03 以 Kate D-Bus `openInput` 建立真正未儲存文件，再用 Wayfire 合成 `Ctrl+A`／`Ctrl+C`，透過 Wayland clipboard 回讀內容並逐次比對 SHA-256。

## 依據

- `tests/g0/lib/reference-apps.sh` 已在 Wayfire 上實測建立未儲存 Kate 文件並得到與輸入一致的 SHA-256。
- `tests/g0/shell-restart-survival/run.sh` 在參考模式每次重啟後都走同一條外部回讀路徑，不以 PID 存活冒充內容保留。
- Kate 是原生 Wayland 參考應用，版本已進 reference preflight。

## 考慮過但沒選的方案

- **替身記憶體程序**：可供開發流程測試，但不是參考編輯器，不能進 EX-03。
- **只檢查 Kate PID**：無法證明未儲存緩衝未改變。
- **讀取磁碟檔案**：未儲存內容不在磁碟上，會驗證錯誤對象。

## 影響

- D-22 結案，D-01 的參考應用集合固定。
- nightly 在參考機缺少 Kate、D-Bus 或 Wayland clipboard 時直接失敗，不降級為替身。
