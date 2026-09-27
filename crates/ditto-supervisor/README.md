# ditto-supervisor

Shell 回應性的監看者（G1-PLAT-03 偵測部分，[plan/03/05 §1、§3](../../plan/03/05-platform-supervision-and-rescue.md)）。它是一個小型 Rust 二進位：沒有 IPC 伺服端、不持有任何權威狀態、不寫配置，也不依賴 Shell、Node 或 Core 活著。由 `ditto-supervisor.service`（`Restart=always`）啟動。

## Shell 要實作的 `ping` 行協定

Shell 工作流在 `shell.sock` 上加一個處理器即可。路徑沿用 G0：`$DITTO_RUNTIME_DIR/shell.sock`，未設定時為 `$XDG_RUNTIME_DIR/ditto/shell.sock`。

| 方向 | 位元組 | 說明 |
| --- | --- | --- |
| supervisor → Shell | `ping <n>\n` | `<n>` 是十進位無號整數，從 1 起每次加 1 |
| Shell → supervisor | `pong <n>\n` | `<n>` 原樣回傳，在**同一條連線**上 |

- supervisor 在多次 ping 之間**保持同一條連線**（每 2 秒新開一條，Quickshell 會為每次關閉記一行 `PeerClosedError` 警告）。任何一次未回應後它丟棄連線，下一次 ping 重新連線。Shell 不要主動關閉連線。
- 期限是送出後 **1 秒**。期限內沒收到與這次 `<n>` 相符的 `pong <n>` 就算一次未回應；`pong` 的 `<n>` 不符、連線被關閉而沒有回覆，也都算。
- 在 `pong` 之前出現的其他行會被略過，所以 Shell 日後在同一條連線上多送別的行不會破壞協定。
- 回覆必須來自 **QML 的主執行緒**（`SocketServer` 的 `onRead`）。在別的執行緒回覆會讓凍結的 UI 仍然看起來有回應，監看就失去意義。
- Shell 目前的 `SocketServer` 對不認得的行只記錄 `ignored control line`，不回覆。這種 Shell 在 supervisor 眼中是「尚未武裝」，**不會**被終止，見下節。

在 `shell/shell.qml` 的 `SocketServer` 中，給 handler 一個 id，再於 `onRead` 加一個分支。以下寫法已在 Quickshell 0.3.1（headless Wayfire）上實測可回覆，且健康時不產生警告：

```qml
handler: Socket {
    id: connection
    parser: SplitParser {
        splitMarker: "\n"
        onRead: line => {
            const command = line.trim().split(" ");
            if (command[0] === "ping" && command.length === 2) {
                connection.write("pong " + command[1] + "\n");
                connection.flush();
            } else if (command[0] === "recall" /* …既有分支… */) {
            }
        }
    }
}
```

驗證：`ditto-supervisor --once` 送一次 ping；收到 `pong` 時印出 `Pong` 並以 0 結束，否則以 1 結束。

## 判斷規則

每 2 秒 ping 一次，間隔以開始時間計算。

| 觀察 | 狀態 | 動作 |
| --- | --- | --- |
| 沒有 socket、或沒有程序在聽（`ENOENT`／`ECONNREFUSED`） | 不存在 | 無。Shell 退出由 Core 的受控啟動器處理 |
| 在聽，但**從未**回過 `pong` | 尚未武裝 | 無 |
| 收到 `pong` | 已武裝，未回應次數歸零 | 無 |
| 已武裝後連續 3 次未回應（約 6～7 秒） | 已觸發 | `SIGKILL` Shell → 寫 `rescue-request.json` → `systemctl --user start --no-block ditto-rescue.service` |
| 已觸發後 | 等新的 Shell 回 `pong` 才重新武裝 | 同一個卡住的 Shell 不會被處理兩次 |

「尚未武裝」是刻意的限制：在第一次回 `pong` 之前就卡住的 Shell，supervisor 不會處理。啟動期的卡住要由 Core 的啟動就緒檢查負責。

非阻塞 connect：`SIGSTOP` 的 Shell 不再 accept，listen backlog 滿了以後阻塞式 connect 會把 supervisor 一起卡住。backlog 滿（`EAGAIN`）也算一次未回應。

## 找 Shell 的程序

1. 在 `/sys/fs/cgroup/user.slice/user-<uid>.slice/user@<uid>.service/` 下往下找三層 `*.slice`，依序找 `ditto-shell.scope`、`ditto-quickshell.scope`，終止 `cgroup.procs` 裡的每個 PID。可用 `--shell-scope` 覆寫名稱（可重複）。第二個名稱存在，是因為 Core 的受控啟動器把 scope 命名為 `<prefix>-<kind>.scope`，而 G0 的 Shell 啟動規格 kind 是 `quickshell`。
2. 找不到 scope 時，改讀 `$DITTO_RUNTIME_DIR/shell.pid`（Core 寫入）。格式是 `<pid>\n` 或 `<pid> <starttime>\n`，其中 `<starttime>` 是 `/proc/<pid>/stat` 的第 22 欄。**建議 Core 寫入第二欄**：有第二欄時，PID 被重用的程序不會被誤殺。只有第一欄時，只檢查該程序存在且屬於同一個使用者。
3. PID 1 與 supervisor 自己永遠不會被當成目標。

## `rescue-request.json`

寫在 `$DITTO_RUNTIME_DIR/rescue-request.json`（原子取代），是執行期的紀錄，不是配置：

```json
{"reason":"shell_unresponsive","at_unix_ms":1790501953448,"killed_pids":[735154],"found_by":"pid_file"}
```

`reason` 是 `shell_unresponsive` 或 `core_failure`。`found_by` 是 `scope`、`pid_file`、`stale_pid_file` 或 `none`。救援介面據此決定要顯示的說明與是否進入離線模式；Core 看到 Shell 退出時，若這個檔案在 30 秒內寫過且 `reason` 是 `shell_unresponsive`，**不應重啟 Shell**（plan/03/05 §3：無回應的原因可能是某個供應者，重啟會再卡住）。

## `--on-core-failure`

`ditto-rescue.service` 的 `ExecStartPre=-`。30 秒內已有 `rescue-request.json` 時保留它（救援是 supervisor 啟動的）；否則終止仍在執行的主 Shell，並寫入 `reason: core_failure`。這個模式永遠以 0 結束，不能擋住救援介面。

## 選項

```
ditto-supervisor [--socket PATH] [--interval-ms 2000] [--timeout-ms 1000] [--misses 3]
                 [--shell-scope NAME]... [--pid-file PATH] [--rescue-unit ditto-rescue.service] [--no-rescue]
ditto-supervisor --on-core-failure
ditto-supervisor --once
```

日誌是 stderr 上的 `ditto-supervisor event=<名稱> key="value"` 行，由 journal 依 unit 保存。

## 已知限制

- `ditto-rescue.service` 由 systemd 啟動，**沒有受控啟動器的 token**，所以這條路徑上的救援介面只能用離線模式（D-29）。Core 仍活著時，由 Core 以 `--rescue-ui` 規格啟動的救援介面才能線上操作；兩者如何分工屬於 D-29，見 plan/03/08。
- 從 `SIGSTOP` 到終止的時間在開發機上實測約 6.1～6.6 秒（Python 替身與加上上述 `ping` 分支的 Quickshell 0.3.1 各一次，headless Wayfire，`--no-rescue`）。這是開發證據，不是 EX1-12 ① 的結果；救援介面本身的啟動時間另計。
