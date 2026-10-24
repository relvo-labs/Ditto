# README：AI-native OS 與最新原生桌面畫面

狀態：實作中。主追蹤 #196；owner 於 Telegram 33723 指定 AI-native OS 定位、33697 要求另開平行任務與最新桌面截圖。來源基準 main@5d6a282；若 UI 基準變更，擷取前再對齊。

第一階段：README 文字 checkpoint 與原生擷取環境預檢已完成；提交後由 parent push 並開 Draft。第二階段仍需準備缺少的 Wayfire／本版建置產物、啟動隔離工作階段、擷取與檢查真實畫面，之後才進行完整審查。本階段未擷取產品圖片，不代表 #196 已完成。

第二階段預檢（2026-10-25）：來源已對齊並匯出 main@9a5504a（含已合併的 #194 啟動器變更）。允許查找的公開建置輸出未找到可重用的 Wayfire runtime，主機亦缺少 Wayland、Pixman、libinput 等建置標頭與 pkg-config 模組；依任務停止條件暫停擷取。未啟動桌面、未產生 PNG，README 維持文字版；真實截圖與圖片整合仍待具備相符 runtime 的隔離環境完成，PR #198 保持 Draft。

## 成果與範圍

- 首屏以 Ditto — AI-native OS 與讀者工作／意圖為中心；可組合桌面／插件為實現方式。
- 忠實區分已接受 MVP、目前 Linux 發行版工程與尚未交付的任意生成／安裝／硬體驗收。
- 真正從最新 main 啟動隔離原生桌面，擷取 2–3 張可公開的必要產品畫面；不沿用舊 VM、不以 prototype／mock／改寫 provider 圖充當實景。
- README.md、必要截圖資產與本計畫；必要才最小拆 contributor 內容。不改產品程式、其他計畫或正式／既有驗收環境。

## 順序與檢查

1. 讀 local skills；以來源 registry 核對舊 README claims，參考小組 README 的 reader-first 模式。
2. 先完成 coherent 文字 checkpoint 並交 parent push Draft；避免長時間擷取把成果留在本機。
3. 同一 writer 續接獨立 HOME／runtime／資料的實際桌面擷取，保存 source／程序／原始圖 hash 證據在 repo 外，更新正式圖片與 caption／alt。
4. 實跑文件承諾的最短入口；檢查 links／anchors、Unicode／fences、scope／diff、PNG 尺寸與 GitHub render；parent 看實際圖。
5. 精確候選獨立審查後轉 Ready；不 merge／發布／部署。真正桌面若受阻，保留具體診斷與 Draft，不偽造圖片或靜默換 mock。

## 隔離與保留

與 #192／#195、#194 分開 clone／branch／session。不得改它們或既有 Ubuntu／Fedora VM、使用者 Profile、憑證或桌面。截圖不含私密資料，不偽造 AI 回覆。研究、capture helper、log／驗證圖留 repo 外；只有 README 正式圖片入版控。
