# 受控啟動器的 token 交付方式

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-19 |
| 狀態 | 已決定 |
| 決策者 | Runtime（Core） |

## 結論

Core 自己啟動工作階段客戶端，並在**已開啟的描述子**（fd 3）上交付一次性 token；token 先綁定 `spawn` 出來的 PID 與執行檔，再交付。客戶端的環境變數只帶描述子編號與 socket 路徑，不帶 token。

## 依據

- `ditto-permission-and-secrets` 第 6 步：身分不可自述，且不得以「沒有 token 就降級為匿名」收場。
- `tests/g0/identity-negative/run.sh` 的三項負例在開發容器實跑全部被拒：複製到其他程序的有效 token、沒有綁定的連線、自填 `privileged-plugin` 的握手。
- 環境變數版本實測不可行：同 UID 的任何程序都能讀 `/proc/<pid>/environ`，等於把一次性 token 公開。
- 先前嘗試「在 `pre_exec` 阻塞等待父行程註冊」會死結：父行程的 `spawn()` 會等到子行程 exec 才返回。

## 考慮過但沒選的方案

- **環境變數交付**：最簡單，但 token 對同 UID 程序可讀；只剩 PID 綁定在擋。
- **token 檔案（0600）**：同樣對同 UID 可讀，且違反「不落盤於可讀路徑」。
- **不用 token、只靠 peer PID／執行檔**：`SO_PEERCRED` 的 PID 無法偽造，但 PID 重用與競態沒有第二道防線，且與計畫寫定的「一次性 token」不一致。

## 影響

- 客戶端必須能讀描述子。`dittoctl` 直接讀；QML Shell 透過 Quickshell 的 `Process` 讀（實測描述子可被子行程繼承）。
- 以直譯器執行的客戶端（例如 shell 腳本）其執行檔身分是直譯器本身，綁定強度較低；G1 的權限模型要把這件事列入考量。
- 開發模式（`--development`）仍使用單一共用 token，**不構成 EX-07 證據**，程式與日誌都明說這點。
