# 頂部面板建置與打包

原生 networkd observer 與 Quickshell 同程序，使用相同的 Qt 6.10.2。
先設定 `QT_PREFIX`（預設 `$HOME/Qt/6.10.2/gcc_64`），執行：

```sh
bash shell/providers/panel_top/build-network.sh
sh packages/host-sdk/bin/ditto-plugin validate shell/providers/panel_top
bash shell/providers/panel_top/pack.sh --out target/ditto-packages/
```

建置需要 qmake、make 與 C++17 編譯器（預設 `g++`，可用 `CXX` 指定）。
`build-network.sh --check` 只檢查工具鏈；內建套件建置會先跑此檢查。
manifest 的 `qml/PanelTop.qml` 是已提交的原始入口；乾淨 checkout 的 SDK validate 不依賴原生建置產物。
panel 的 `pack.sh` 在缺少 `.so` 時會明確警告，再重新建置；建置失敗或仍缺模組時拒絕產包。
內建套件建置也會先建置原生模組。這兩條是發行打包路徑。
通用 SDK pack 只驗證 manifest 與 QML 入口，**不會建置或檢查原生模組**；
直接對乾淨來源使用它，可能得到只有 NM 路徑的開發用包，不可用於發行。請使用上述 panel `pack.sh`。
`native/`、建置腳本與文件不屬於套件內容。

固定同一套 Qt、編譯器與 libstdc++ 時，Qt prefix 路徑別名不應影響 archive hash；
不保證不同工具鏈產生相同內容。模組不含 Qt RUNPATH；本機以 qmltestrunner 驗證宿主已載入的 Qt 相依庫，Quickshell 實機仍待 VM 回讀。
原子替換 `.so` 可保留執行中 Shell 的舊 mmap；它不代表已驗證熱換載入第二份同 URI 模組。
1.1.0 → 1.1.1 升版與回退仍須在持續執行的 Shell 上檢查 Loader 狀態、NM/networkd 回讀及舊來源清理。
