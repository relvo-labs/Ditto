# G4 範圍與出口

本檔為執行提案，權威順序見 [README](README.md)。盤點基底 `39da297`，日期 2026-10-17。

## 1. 六項出口（照錄上位計畫）

下列核取框保留給 owner 的正式出口裁定，不以實作或自動測試自行核定。

| 出口 | 主要承接 |
| --- | --- |
| [ ] 全部 P0 需求通過 | #61 追溯表（PRD 需求表 90 列 P0）；各功能 issue |
| [ ] AT-01～32 適用情境通過 | #56 |
| [ ] AT-25 分層資源、AT-26 工具超限、AT-29 宿主分級通過 | #53（AT-25）、#56（AT-26／29 參考機重跑） |
| [ ] 核定的非功能指標通過，或有數據支持的調整決策 | #52～#55 |
| [ ] 無資料損毀、鎖定繞過、持續黑屏與無法救援等未解決阻斷問題 | #59、#56、#41 |
| [ ] 授權、名稱與角色素材審查完成 | #51 |

「有數據支持的調整決策」指 owner 核定並留存決策紀錄的調整；只提出提案不算通過，核定前該項維持未通過（PRD §19.1）。

PRD §23 另列發布成效指標；本計畫逐項指定承接：對話改造完成率（#56，語意任務集）、配置切換可靠度 100 次 ≥99%（#52）、生成實用性（#44、#56）、回復能力（#56）、使用者可理解性（#57）、SDK 可用性（#58）。

## 2. 範圍與非範圍

| 範圍 | 非範圍 |
| --- | --- |
| 03-phases 的 16 項 G4 工作：SHELL-01～03、PLAT-01～04、CORE-01～04、QA-01～04、DOC-01 | P1：更自由的 QML／腳本生成、第三方移植助手、隔離插件自助安裝、替換角色、語音、完整 portal 與藍牙設備管理、嵌入式腳本引擎（D-07） |
| G3 交接與 VM 未涵蓋的實體驗收（#44） | P2：公開插件生態、跨設備同步、團隊政策 |
| D-38／D-46 後續追蹤中屬於 G4 的項目（[02](02-handoff.md)） | 非參考平台的移植；法律審查本身（Agent 只整理盤點，結論由 owner／法務） |
| 發布交付物與 G4-exit 評審 | 商業模式 |

## 3. 現況盤點（`39da297`）

授權狀態補記（2026-10-25）：下表 `UNLICENSED` 是當時的歷史快照；Ditto 自有程式碼已由 owner 依 [D-52](../../docs/product/2026-10-25-d52-mit-license.md) 改採 MIT。第三方、名稱與素材等 #51 缺口未因此完成。

| 領域 | 實際位置與已有行為 | G4 缺口 | issue |
| --- | --- | --- | --- |
| 預設組合 | `crates/ditto-core/src/defaults.rs` 建一份「預設」Profile，主題 `soft-jelly` | 沒有內建「開發」「簡報」用途組合；現有的只是 `tests/g1/manual-switch/run.sh` 裡臨時建立的測試組合 | #45 |
| 角色 | `AvatarSettings`（`crates/ditto-protocol/src/profile.rs`）有 enabled／hidden／scale／animations／output／corner；位置只有四角 | `shell/avatar/Avatar.qml` 沒有拖曳移動；無角色模式的對話操作未逐項驗證 | #46 |
| 無障礙 | Profile `reduced_motion`；Shell 共 63 處 `Accessible.name` | 沒有整體鍵盤、焦點與螢幕閱讀走查；減少動畫是否涵蓋所有動畫未驗 | #47 |
| 系統整合 | 音量（PipeWire）與網路（NetworkManager）在 `shell/providers/panel_top` 讀取；`desktop.session.lock／logout／suspend／poweroff` 走 logind | 沒有藍牙入口；Super＋數字未在預設快捷鍵；音量／網路路徑驗證不足（D-38） | #48 |
| 輸出 | `desktop.outputs.list`；角色可指定輸出；`tests/g1/output-hotplug` headless 版通過 | 實體第二螢幕與縮放矩陣未驗；參考機目前只接一台螢幕 | #49 |
| 安裝 | `packaging/reference-image/install-session.sh` 從 checkout 建置並安裝，需 sudo 與私有前綴 | 沒有可散布安裝包、升級、回退與移除；內建套件同版本不同內容不會升級；生成模板 hash 改變後舊產物的重驗證 | #50 |
| 授權 | `docs/platform/dependency-inventory.md` 是 G0 起點；`licenses.yml` 只輸出清單；`Cargo.toml` 為 `UNLICENSED`；vendored 套件保留上游 LICENSE | 發行包盤點、Qt 重新連結材料、Qt6Test、Codex 再散布、字型、角色與名稱權利 | #51 |
| 效能 | G0 EX-04 幀時兩次未達 95%；G2 實體座位 Super+A／啟動器 200 次 p95 64／27 ms、Agent 冷啟動 p95 1355 ms（`a88bce8`） | NFR-01 未量；全部 NFR 須在凍結 commit 重測；切換可靠度 100 次 | #52 |
| 資源 | G1 完整桌面 p95 約 450 MiB；G2 參考機 Agent 暖態 p95 88.6～89.2 MiB；D-06a 待核定；D-44 後端暫 1G | 四態分層報告、生成工作的 worker＋native 合計、D-06a 核定、#35 | #53 |
| 長跑 | — | 沒有 8 小時長跑腳本 | #54 |
| 離線 | G2 EX2-10 部分（開發證據） | 參考機實際斷網、重連後會話 | #55、#38 |
| 安全 | 秘密哨兵只在 `tests/g2`；`redacted_detail`；`tests/g1/lock` | 全產品外洩掃描、鎖定繞過矩陣、崩潰報告遮蔽、密碼解鎖錄影 | #59 |
| SDK | `packages/host-sdk` 有範本、範例與 CLI | `docs/` 下沒有 SDK 作者文件 | #58 |
| nightly | 必要步驟為 G0 項目與 G1 EX1-01／03／07／08／09；救援、鎖定、熱插拔為 `continue-on-error` | 連續五晚未成立；必要檢查設定待處理 | #56 |
