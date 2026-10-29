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
| 沒有程序在聽：沒有 socket 檔（`ENOENT`）、沒有程序綁著它（`ECONNREFUSED`）、路徑不是目錄（`ENOTDIR`） | 不存在 | 無。Shell 退出由 Core 的受控啟動器處理 |
| 在聽，但**從未**回過 `pong` | 尚未武裝 | 無 |
| 第一次收到 `pong`，或收到**可證明是另一個程序**的 `pong`（不論先前是什麼狀態，見下方身分規則） | 已武裝，新的一代，進入**啟動寬限**（60 秒） | 無。日誌 `state` 帶 `phase="startup"` 與 `peer`；已武裝時被取代記 `detail="new_shell"` |
| 收到**可能是同一個程序**的 `pong`（不論先前是什麼狀態：斷線重連後、不存在或尚未武裝之後、觸發後沒殺掉；含讀不到對端、讀不到啟動時間） | 已武裝，這一代繼續，未回應次數歸零 | 無。寬限仍從這一代第一次武裝起算，不重新開始；寬限已過就照 3 次規則 |
| 啟動寬限內連續 10 次未回應（約 19～21 秒） | 已觸發 | 同下一列；日誌帶 `phase="startup"` |
| 寬限結束後連續 3 次未回應（約 6～7 秒） | 已觸發 | `SIGKILL` Shell → 寫 `rescue-request.json` → `systemctl --user start --no-block ditto-rescue.service`；日誌帶 `phase="steady"` |
| 已觸發後 | 等 Shell 回 `pong` 才重新武裝 | 同一個卡住的 Shell 不會被處理兩次 |

「不存在」只表示沒有程序在聽，沒有別的意思。connect 失敗只有一個地方判斷（`classify_connect_error`），第一次連線和寫入遇到斷線（`BrokenPipe`）後的重連都用它：上面三種錯誤是不存在；backlog 滿（`EAGAIN`）和其他錯誤都是一次未回應。主執行緒停住、不再 accept 的 Shell 仍握著 listening socket，supervisor 每次未回應後都會重連，很快就把 backlog 填滿，所以這種 Shell 只會被看成未回應，不會被看成不存在。

「尚未武裝」是刻意的限制：在第一次回 `pong` 之前就卡住的 Shell，supervisor 不會處理。啟動期的卡住要由 Core 的啟動就緒檢查負責。

**啟動寬限**（#226）：Shell 的 `SocketServer` 一起來就會回 `pong`，所以 supervisor 很早就武裝；接著 Shell 的主執行緒在建立 Core 連線、掛載開機供應者時會停頓。在不開 KVM 的 QEMU（TCG）上實測停頓 6.1 秒與 5.1 秒，後者之後還有約 2 秒、1 秒的慢回覆；KVM 上最大 0.5 秒。套用 3 次規則會把正常啟動的 Shell 殺掉並進入救援。因此每一代 Shell 從武裝起 60 秒內，要連續 10 次未回應才觸發：

- 門檻依**每次未回應被觀察到的時間**（supervisor 自己的單調時鐘）落在寬限內或外決定。連續次數不因寬限結束而歸零：寬限一結束，跨過邊界的連續未回應累計達 3 次就觸發。
- 上限：啟動中真的卡死，從卡住起約 21 秒內觸發，不會變成永遠不處理；寬限結束後就是原本的 3 次規則，常態期（NFR-08 的 10 秒）沒有放寬。
- 「哪一代」跟著程序走，不跟著狀態走：每次新連線都以 `SO_PEERCRED` 讀出在聽的程序 PID，並讀 `/proc/<pid>/stat` 的啟動時間，PID 被重用也分得出來。Core 重啟 Shell 的最短退避是 1 秒，比 ping 間隔短，所以新 Shell 可能在 supervisor 看到「不存在」之前就接上；舊連線斷掉、重連到新 Shell 並收到 `pong` 時，若可證明是另一個程序，就是新的一代。反過來，看到「不存在」或觸發之後，回 `pong` 的若可能是同一個程序，也只是這一代繼續，不重新寬限。寬限結束時記一行 `grace_ended`。
- **身分規則**（`Peer::provably_differs_from`，唯一的判斷處）：兩次觀察**除非可證明不同，否則視為可能是同一個程序**。可證明不同只有兩種：兩次都讀到 PID 且 PID 不同；或 PID 相同、兩次都讀到啟動時間且不同。讀不到對端（`getsockopt` 失敗，或對端在看不到的 PID namespace，PID 為 0，日誌記 `peer="unknown"`）、或讀不到啟動時間，都不能證明什麼，視為同一代。這一代先前沒讀到的身分資訊（PID 或啟動時間），之後讀到會記下來（不開新的一代），之後 PID 被重用才分得出來。
- 失敗方向：不確定就當成同一代，寬限不會被重新開始，所以寧可進入救援，不放過卡住的 Shell。代價是無法分辨的替換（讀不到對端，或 PID 相同、其中一次讀不到啟動時間）可能拿不到寬限，在慢機器上可能被誤判而進入救援。Linux 的 Unix socket 一般都讀得到對端，這是退路。
- 同一個 Shell 不能自己延長寬限：不論它被觀察成什麼樣子、斷線重連幾次、中間是否被看成不存在，都仍是同一代。反覆停頓又偶爾回覆的 Shell，寬限一過就照 3 次規則處理。
- 測試證據：單元測試對同一個真實 Shell 窮舉所有觀察方式（每次 `pong` 是有啟動時間、沒有啟動時間、讀不到對端但同一連線、讀不到對端且換了連線，長度 8 的所有序列），乘上停頓模式（k 次未回應後回覆一次，k＝1～9，以及卡死），結果都和每次正確辨識時完全相同；k≥3 與卡死最遲在「第一次武裝＋寬限＋常態上限」內觸發（k＝1、2 等於最多每 6 秒回覆一次，3 次規則本來就不觸發）。另一組測試在其中硬插入「不存在」與「不存在後未回應」（固定後的 pinger 對活著的 Shell 產生不出這些），同一個 Shell 回覆後仍不會重新寬限：k≥3 與卡死最遲在「第一次武裝＋寬限＋常態上限」與「恢復回覆＋常態上限」兩者較晚者內觸發。
- 仍然不會觸發的情況：supervisor 只處理已武裝的 Shell。真的看到「不存在」之後，接著一直未回應（尚未武裝）就不會觸發。對同一個活著、握著 listening socket 的 Shell，固定後的 pinger 不會產生「不存在」（有 socket 測試）。真的不存在，表示 Shell 已經不在，由 Core 的退出與重啟處理；新起來的 Shell 從未回應，則屬於上面「尚未武裝」的既有設計。剩下的只有一種：活著的程序自己關掉或刪除 listening socket，之後重新 listen 卻一直不回應。目前的 Shell 不會這樣做（`SocketServer` 在整個程序期間都開著），supervisor 也無從 ping 到它。
- 依據與取捨見 [D-53](../../.agents/notes/decisions/2026-10-27-d53-supervisor-startup-grace.md)。

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
                 [--startup-grace-ms 60000] [--startup-misses 10]
                 [--shell-scope NAME]... [--pid-file PATH] [--rescue-unit ditto-rescue.service] [--no-rescue]
ditto-supervisor --on-core-failure
ditto-supervisor --once
```

`--startup-grace-ms 0` 關閉啟動寬限。`--startup-misses` 不得小於 `--misses`，否則拒絕啟動；未指定時取 10 與 `--misses` 的較大值，所以原有的呼叫方式（例如 `--misses 100000`）照常可用。

日誌是 stderr 上的 `ditto-supervisor event=<名稱> key="value"` 行，由 journal 依 unit 保存。`started` 記錄生效的門檻（含 `startup_grace_ms`、`startup_misses`）；`state` 在進入已武裝或已觸發時帶 `phase` 與 `peer`（`pid:<n>` 或 `unknown`），`shell_unresponsive` 也帶 `phase`，用來分辨啟動期與常態期的觸發。

## 已知限制

- `ditto-rescue.service` 由 systemd 啟動，**沒有受控啟動器的 token**，所以這條路徑上的救援介面只能用離線模式（D-29）。Core 仍活著時，由 Core 以 `--rescue-ui` 規格啟動的救援介面才能線上操作；兩者如何分工屬於 D-29，見 plan/03/08。
- 從 `SIGSTOP` 到終止的時間在開發機上實測約 6.1～6.6 秒（Python 替身與加上上述 `ping` 分支的 Quickshell 0.3.1 各一次，headless Wayfire，`--no-rescue`）。這是開發證據，不是 EX1-12 ① 的結果；救援介面本身的啟動時間另計。該量測早於啟動寬限，對應的是常態期的 3 次規則；寬限內卡住到終止的時間（上限約 21 秒）只有單元測試，尚未在 VM 實測。
