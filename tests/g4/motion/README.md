# #66 原生動態回歸與錄影

這是開發證據；Core／視窗／會話資料為 fixture，Quickshell layer-shell 使用既有 QML 替身。不是實體 Wayfire、OS 焦點、硬體 FPS 或 NFR-05 證據。候選時長與強度仍待 owner 確認。

依 `.nvmrc` 經 NVM 選 Node，設定 `QT_PREFIX`、`LD_LIBRARY_PATH`、`TMPDIR` 後：

```sh
bash tests/g4/motion/run.sh /data/hermes/ditto-runs/g4-impl/r2-motion/evidence/final/motion
python3 tests/g4/motion/record-native.py /data/hermes/ditto-runs/g4-impl/r2-motion/evidence/final/media
```

第一個指令重用 canonical staging，測實際 scale／opacity、latest intent、長幀、偏好切換、終態與隱藏、同一 draft／turn、Dock 回讀和靜態 capture settle 後的像素穩定。`samples/NativeMotion.qml` 不以 `tst_` 命名，因此只由第二個指令顯式執行，不混入快速回歸。

錄影工具需要已安裝的 FFmpeg，輸出目錄必須在 repo 外且 frames 為空；既有證據不覆寫。工具將 gitignored `.staged/motion-recording` symlink 指到該目錄。每張 PNG 都由運行中的原生 QML 引擎 `grabImage` 取得，不合成動畫中間幀。QtTest 的 `save()` 沒有布林回傳，Python 逐張檢查檔案並計算 SHA-256。

`qml.log` 包含 executable 的 Qt 版本、實際 scene graph／GraphicsInfo 與 platform plugin 載入；requested 環境變數另記，不能用 requested backend 冒充實測。`timestamps.jsonl` 保留 QML 取樣前後的 wall time、Qt FrameAnimation 計數／elapsed，以及 Python 收到該行時的 `time.monotonic_ns()`／wall time。後者含管線與接收延遲，不是 GPU 呈現時間。

`native-motion.mp4` 依實際取樣 wall time 用 variable timestamps 編碼，time scale 為 1，沒有補幀；最後重複一次原末幀以保留 concat duration。取樣／存圖／診斷文字都會增加負載，不用其取樣率推論原生 FPS。`recording.json` 記事件、物件值、每幀 hash、來源前後 hash、編碼命令及 exit。

約 16 秒的固定 fixture 順序：首次呈現；Dock hover／press／反向連點及 focused-window 回讀；助理 press 與 repeat open／instant close；running→cancelling→succeeded／partial／unknown；活動中 hide；運行中 reduced-motion；low-power；恢復 normal；reduced-transparency；再次 hide／unknown。每個關卡以真實 QML 物件值檢查，不捏造百分比或自動重播操作。確切事件與取樣時間以 manifest 為準。

canonical `tests/g4/visual/run.sh` 與 `run-assistant.sh` 仍須各自完整執行。靜態 capture 保留正常模式的 production motion，等實際 Dock reveal／feedback、助理符號與 compact opacity settle 後才抓圖；不全域關閉動畫換取通過。正常 capture、fallback 與動態錄影有不同目的。

F1 repair 1 加入 focused window ID 過渡矩陣與僅作路徑適配的 reviewer reproducer。確認動畫屬 provider 生命週期，不屬被重建的 tile；測試用實際 Animation.started 次數與各 tile 的 confirmedScale 區分真正 ID 過渡和 title／geometry／apps reload 等同身分事件。錄影另包含同 ID upsert 不重播的關卡；舊錄影不覆寫。F2 真實 window 隱藏傳遞未驗證；F3 legacy array 重建的 hover／press／keyboard focus 仍是獨立 follow-up。

#83 在 `tst_dock_tile_lifetime.qml` 補上 F3 的互動生命週期回歸：實際 hover／press／activeFocus、feedback 插值與啟動次數、兩個 Dock 的排序／Tab／pointer grab、釘選 app 與非釘選 window 身分、移除／release／替換，以及 legacy 靜態樣式。canonical staging 現在也包含 DockBottom，仍只剝除 Wayland attached properties；production 外觀與動態參數不變。前段 F3 留待 follow-up 是歷史邊界；本次 QtTest 證據不替代實體 Wayfire 焦點與 hit-region 驗收。詳細映射與未執行項見 `docs/design/default-desktop/motion-candidate.md` 的 F3 段落。
