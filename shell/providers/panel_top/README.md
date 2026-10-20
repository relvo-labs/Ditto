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
建置成功才產生 manifest 的 `qml/BuiltPanelTop.qml` 入口與原生 `.so`；
乾淨 checkout 直接執行 SDK pack 會明確回報 `package_missing`／`build first`。
panel 的 `pack.sh` 會先重新建置，再呼叫 SDK pack。直接使用 SDK 時也必須先重新建置，不可只複製產生的 QML 入口。
`native/`、建置腳本與文件不屬於套件內容。

固定同一套 Qt、編譯器與 libstdc++ 時，Qt prefix 路徑別名不應影響 archive hash；
不保證不同工具鏈產生相同內容。模組不含 Qt RUNPATH；本機以 qmltestrunner 驗證宿主已載入的 Qt 相依庫，Quickshell 實機仍待 VM 回讀。
原子替換 `.so` 可保留執行中 Shell 的舊 mmap；它不代表已驗證熱換載入第二份同 URI 模組。
1.1.0 → 1.1.1 升版與回退仍須在持續執行的 Shell 上檢查 Loader 狀態、NM/networkd 回讀及舊來源清理。
