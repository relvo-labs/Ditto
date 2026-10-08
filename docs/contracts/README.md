# 契約文件

這個目錄是 G1 契約細節的權威位置（[plan/03 README §6 第 5 條](../../plan/03/README.md#6-維護規則)）。plan/03 給的是設計判準與初版形狀；實作定案後以這裡與 `schema/` 為準，plan/03 不同步維護第二份。

| 文件 | 內容 | 狀態 |
| --- | --- | --- |
| [protocol-0.2.md](protocol-0.2.md) | Core 協定 0.2：握手、呼叫方、錯誤、`_meta`、事件、能力群組、交易參與者方法 | 實作中；M3 起依 D-35 凍結欄位 |
| [host-protocol.md](host-protocol.md) | Core ↔ `ditto-hostd`：身分、`on_behalf_of`、條目推送、租約、轉送呼叫、事件橋、資源回報 | 實作中 |
| [store-schema.md](store-schema.md) | `ditto-store`：資料表、不變量、trigger、遷移、檔案鎖與離線模式 | 實作中 |
| [profile-document.md](profile-document.md) | ProfileDocument 欄位、所有權、revision 與匯出語意 | 實作中 |
| [manifest.md](manifest.md) | 插件 manifest 的欄位與 Core 如何使用它們 | 實作中 |
| [agent-0.3.md](agent-0.3.md) | G2：Agent 後端隔離的語意、`conversations` 事件主題、Shell 對話入口 | 實作中（G2 M1） |

型別的單一事實來源是 `crates/ditto-protocol`（D-13）。這些文件描述語意與不變量；欄位的確切形狀以 `schema/*.json` 為準，兩者不一致時是缺陷，以 Rust 型別為準修正文件。
