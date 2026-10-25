# 首次開機帳號協定（#212，v1）

本文件凍結 PR A 與 PR B 的介面。傳輸不加入版本欄位，也不接受額外欄位；日後更換後端仍須維持本介面。

連線到 `/run/ditto/firstboot-account.sock`（Unix stream，`root:_greetd`、`0660`）。systemd 使用 `Accept=no` 傳入一個 listener；每次 helper 啟動只 accept 一條連線、處理一筆請求，然後退出。佇列內的其他連線由下一次啟動處理。

## 分幀與身分

- 請求是單行 UTF-8 JSON object，後接 LF。也可送完 JSON 後 `shutdown(SHUT_WR)`，用 EOF 結束請求。
- JSON 最多 **4096 bytes**，不含結尾 LF；JSON 字串中的換行須用 escape 表示。整筆讀取期限為 30 秒。
- 回應也是一行 JSON，後接 LF。client 應讀到 LF，不必等待 EOF；未授權或超大請求可能在未讀完輸入時關閉連線。
- helper 在讀取請求前，使用 `SO_PEERCRED` 核對對方 UID；必須等於執行時透過 NSS 解析的 `_greetd` UID。無法解析也拒絕。socket 群組成員資格不能取代這項核對。

## 請求

只有以下三個必要欄位，全部是 JSON string；重複、未知或缺少欄位均拒絕。不能指定 UID、群組、shell、路徑、工具或權限。

| 欄位 | 規則 |
| --- | --- |
| `display_name` | 可留空；最多 128 個 Unicode scalar、且最多 512 UTF-8 bytes。拒絕所有 Unicode 控制字元與 `:`、`,`、`=`（包括 NUL、LF、CR、Tab）。不靜默修改使用者輸入。 |
| `username` | `^[a-z][a-z0-9-]{0,30}$`；不得與既有使用者、群組、subuid/subgid 條目或 `/home/<name>`、`/var/mail/<name>` 重名，也不得是保留名稱。 |
| `password` | 至少 8 個 Unicode scalar；最多 **511 UTF-8 bytes**（配合 libxcrypt 的 512-byte 含 NUL 上限）。拒絕 NUL、LF、CR；接受其他字元與合法 JSON escapes。 |

保留名稱的權威清單在 [input.rs](src/input.rs) 的 `RESERVED`：系統／服務帳號、管理與裝置群組（例如 `root`、`sudo`、`admin`、`wheel`、`nobody`、`greetd`、`ditto`、`firstboot`）。`_greetd` 本身不符合名稱格式。

JSON 範例中的密碼位置應由使用者輸入的值取代；不得把請求印到日誌：

```json
{"display_name":"小愛","username":"alice","password":"<由使用者輸入>"}
```

## 回應

成功（完成 passwd／shadow／群組／家目錄回讀，且完成標記已持久化）：

```json
{"ok":true,"weak_password":false}
```

`weak_password` 只供畫面顯示警告，**不得阻止建立或登入**。符合任一條件即為 `true`：少於 12 個 Unicode scalar；小寫、大寫、數字、非英數四類中不足兩類；或不分 ASCII 大小寫，完全等於 `password`、`password123`、`12345678`、`123456789`、`qwerty123`、`letmein123`。這是簡單提示，不是密碼安全評分。

失敗：

```json
{"ok":false,"error":"invalid_username"}
```

| 穩定代碼 | 意義與 client 處理 |
| --- | --- |
| `invalid_username` | 格式或保留名稱不符；修改帳號名稱。 |
| `username_taken` | 使用者／群組／相關既有資料重名；換一個名稱，不會刪除既有資料。 |
| `password_too_short` | 少於 8 個 Unicode scalar；修改密碼。 |
| `password_invalid` | 密碼含禁止字元或超過長度上限；修改密碼。 |
| `display_name_invalid` | 顯示名稱含禁止字元或過長；修改名字或留空。 |
| `already_provisioned` | 已有完成標記，或 UID_MIN..UID_MAX 內已有帳號；改走登入。 |
| `unauthorized` | 對方 UID 不符，或無法取得可信 greeter 身分；不可重送身分欄位求取權限。 |
| `internal_rolled_back` | 內部操作失敗且回讀確認已回復；也用於畸形／超大／逾時 JSON、欄位型別不符，以及任何副作用前的內部拒絕。這些拒絕沒有建立帳號。可修正輸入或檢查系統後重試。 |
| `internal_rollback_failed` | 無法確認清除完成或安全讀取 pending；停止建立，交由 root 檢查復原紀錄與殘留狀態。不得宣稱帳號不存在。 |

驗證順序是對方身分 → 持鎖復原 → 完成標記／人員帳號 → 欄位驗證 → 名稱衝突。前一項拒絕時不透露後續檢查結果。沒有其他錯誤碼或錯誤訊息欄位。

## 提交後與斷線

收到成功後，PR B 用同一組帳號與密碼經 greetd／PAM 正式登入，再啟動 Ditto session；helper 不做登入、不設定自動登入。client 用完密碼應立即清除引用並退出 greeter。

送出後失去回應不代表失敗。完成標記可能已提交；應讓 wrapper 重新判斷帳號狀態並提供登入，不能把第二次請求當作登入驗證。刪除完成標記也不允許建立第二個人員帳號。已啟動 socket 的 Condition 不會因標記出現而重新求值，因此每次交易仍在鎖內重查。
