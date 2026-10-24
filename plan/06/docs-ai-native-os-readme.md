# README：AI-native OS 與最新原生桌面畫面

狀態：原生截圖與 README 整合、GitHub render 與 parent 視覺確認已完成。獨立審查第 1 輪回報 CHANGES_REQUIRED；本輪修正 F1–F6，待 parent 推送並安排新的差異閉環審查，PR #198 保持 Draft。主追蹤 #196；owner 於 Telegram 33723 指定 AI-native OS 定位、33697 要求另開平行任務與最新桌面截圖。文字起始基準 main@5d6a282；原生擷取基準 main@1d055ce。

## 階段紀錄（歷史）

第一階段：完成 README 文字 checkpoint 與原生擷取環境預檢，之後由 parent push 並開 Draft。當時未擷取產品圖片；缺少的 Wayfire／本版建置產物與真實截圖交後續階段處理。

第二階段預檢（2026-10-25）：來源對齊並匯出 main@9a5504a（含已合併的 #194 啟動器變更）。允許查找的公開建置輸出未找到可重用的 Wayfire runtime，主機亦缺少 Wayland、Pixman、libinput 等建置標頭與 pkg-config 模組；依當時任務停止條件暫停擷取。當時未啟動桌面、未產生 PNG，README 為文字版，PR #198 保持 Draft。

第三階段（2026-10-25）：依 coordinator 新授權，以獨立 Ubuntu 26.04 容器補足相依項，從 main@1d055ce 建置 Core／hostd 與內建套件，啟動原生 Shell、私有 D-Bus 與 Wayfire pixman 工作階段。已回讀 Core／Shell 狀態、擷取並目視檢查個人化設定與網格啟動器兩張正式圖片，整合 caption／alt；task-owned 程序群組與容器均清理並回讀消失。原始圖片、完整來源與命令證據留 repo 外。這是桌面擷取證據，不是 OS 映像、登入管理器、模型或硬體驗收。

修正第 1 輪（2026-10-25）：恢復自有程式碼未指定開源授權的事實；移除把擷取結果混入開發入口的相對敘述，保留首次操作流程未重驗的限制；補上已合併發行版文件的站內導覽；釐清預覽為選用步驟，並將模型連線隔離條件限定在 Codex 訂閱路徑。同步更新計畫現況；本輪只改 README 與本計畫，兩張既有圖片不變，未重跑桌面或模型流程。

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
