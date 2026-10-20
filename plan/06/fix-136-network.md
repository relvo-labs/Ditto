# 修復計畫 v0.1 — #136

- Base: `5687d4779eb5eb38205ce6ba749ec1b867c5288e`; M/T2；使用者授權平行修復。
- 先完整讀 skills manifest，再建立可重現症狀的 RED（不是缺 helper 的編譯錯誤）。
- 追蹤狀態來源與實際回傳，最小根因修正；保留安全與 unknown 語意。
- 聚焦測試 GREEN、受影響完整 gates、exact-head 獨立審查；VM 驗證另由 coordinator 串行執行。
- 首個實作 checkpoint commit 後 coordinator push Draft，後續 checkpoint 也 push；不 merge、不修改 live 登入／網路。
- 與 #134 共用翻譯／QML 檔需串行整合，候選不宣稱可直接互相合併。

## 範圍
Live mismatch established: networkctl enp0s1 routable/configured online; IPv4 10.0.2.15 with default via 10.0.2.2, NetworkManager State=20, Connectivity=0, nmcli disconnected:unknown, device unmanaged. Both daemons active; networkd owns interface. Trace Quickshell Networking -> PanelTop status projection -> UI. Do not assume NM is whole host authority. Build regression reaching exactly this mixed-manager case. Prefer narrow existing architecture-compatible read-only state source/fallback, no expensive always-on subprocess polling and no mutation of netplan/network renderer. Never treat unknown as online or make ping sole proof of general Internet availability. Preserve NM wired/wifi/offline/limited/portal/unknown/reconnect and hidden resource behavior. If robust cross-manager support requires broad new contract, stop at diagnosis + smallest plan rather than fake a green icon.
Allowed focus: panel_top provider, narrowly scoped network status helper if needed, tests/stubs and packaging only when source proves required. Not AI auth files. Existing #48 tracks system integration; this is exact user bug #136.

## 第一個 checkpoint 的選擇

- 根因：Quickshell 0.3.1 只支援 NM；PanelTop 的兩種呈現都從 NM 裝置的 `connected` 投影，沒有 networkd 來源。私有 bus 的 configured／routable networkd 與 NM unmanaged fixture 已先得到 UI 狀態斷言 RED。
- 最小來源補充：panel 套件內的可信 Qt／D-Bus module，與 Shell 同程序，非同步呼叫 networkd `ListLinks`／`GetAll`、訂閱屬性與服務擁有者變更；不啟動 daemon、不輪詢、不寫入系統或 Profile。沿用既有 UI 系統狀態讀取邊界，沒有新增 `desktop.*` 契約。
- 只接受 configured、routable 且核心回讀為啟用中的 Ethernet／Wi-Fi；NM 有 connected 裝置時優先使用 NM。networkd 連線的文字明示網際網路狀態未知；來源失敗不保留舊的連線結果。隱藏、release 或 NM 接手時卸下 observer。
- helper 放在 `qml/network/`，可隨既有 QML 套件內容一起發行；內建打包與視覺 staging 都先以同一 Qt prefix 建置。panel 套件升為 1.1.1，避免覆寫已鎖定的 1.1.0。讀取失敗或 module 不可用不使 panel 降級為不可用。
- 開發驗證：`bash tests/g4/network/run.sh <evidence-dir>`、`bash tests/g4/visual/run.sh <evidence-dir>`、`node scripts/lint-shell-i18n.mjs`、`bash scripts/build-builtin-packages.sh <out>`；Node 固定 `.nvmrc`、Qt 固定 6.10.2。測試 bus／loopback 控制只屬於該測試，不接共享服務。
- 對應 DES-05 與 #136；既有 AT-01 矩陣只列 DES-01～04，不能把此開發回歸當作整項 AT 通過。#48／#56 的整合與 VM 同源回讀、獨立審查及參考機資源驗收仍待 coordinator 執行。
