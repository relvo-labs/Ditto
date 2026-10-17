# G3 隔離基礎設施診斷宿主

獨立開發工具，對應 #16／17／18 的第一批基礎設施。沒有正式 Core RPC、Profile 寫入、候選啟用或任意命令入口。`full` 只表示此次 **`diagnostic-v1` 固定診斷政策**成立；不能用來啟用生成插件。

```sh
cargo build --locked -p ditto-confine -p ditto-test-host
XDG_RUNTIME_DIR=/run/user/$(id -u) target/debug/ditto-test-host probe files
bash tests/g3/host/run.sh
```

從 checkout 執行。工具在 `artifacts/g3/workspaces/` 建立每次獨立的 0700 工作目錄，避免呼叫端 private `/tmp` 與 systemd user manager 看見不同檔案；完成後只刪自己建立的隨機目錄。測試報告由測試 driver 保存到 `artifacts/g3/`。

先建立 systemd user service，再回讀 D-06b 的 512 MiB／100%／64 tasks／零 swap 與實際 RuntimeMaxSec，才啟動既有 `ditto-confine`。ABI <6、controller 缺失、配額回讀不符或 private status handshake 失敗均不執行診斷 probe。另加 seccomp 禁止非 Unix socket，包含不經 connect 的 UDP；保留 G2 confine 原樣。

固定 probes：檔案／symlink／hardlink、網路／Unix endpoint、scope 外 signals、fork 超量、OOM、忙碌迴圈、逾時、stdout 偽造與逃離 process group 的子程序。SIGTERM／SIGINT／SIGHUP 取消會終止整個候選 service；服務本身有獨立 deadline。成功、失敗與超限都回讀 cgroup 是否清空，清理缺證據會降為 partial。

退出碼：0＝診斷程式成功且已清理；1＝診斷失敗／OOM／逾時／取消或清理未確認；2＝隔離不可用；64＝使用方式錯誤。OOM／逾時對故障測試而言可能是正確結果，driver 依回報判定，不把退出 1 一律當成測試失敗。

`diagnostic-v1` 限制子程序數，**沒有禁止唯讀執行期內的一切 exec**，不載入任意 QML／Node／native 候選。正式生成政策、能力代理、Core／UI 的分項回報與桌面同 PID／revision 證據仍待後續 #19／23／24／30～32。開發 VM 的成功不代表參考機出口或資源量測通過。
