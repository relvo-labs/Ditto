# G0 資源採樣器

`ditto-measure` 依 systemd 單元查詢 `ControlGroup`，遞迴讀取 cgroup v2 的 `cgroup.procs`；不靠程序名稱搜尋。每個程序分別採集 PSS、RSS、CPU、執行緒、fd、cgroup 與命令列，GPU 欄位若尚無採集器會明示原因。PSS 與 RSS 不相加。

目前可產生原始 JSONL 與三次重複的 G0 子集報告。**尚未在凍結的實體參考機跑固定的 5 分鐘暖機／10 分鐘採樣，因此沒有資源基線或 EX-05 結論。**

## 輸入

`manifest.json` 由執行者填入當次版本指紋與完整單元清單。`kernel` 必須與 `/proc/sys/kernel/osrelease` 一致；`excluded` 必須顯式列出單元與原因，且不得與納入的單元重疊。

```json
{
  "run_id": "2026-10-14T09:00:00Z-abc",
  "state": "desktop_full_no_agent_g0_subset",
  "fingerprint": {
    "kernel": "填入實際 uname -r", "qt": "填入實際版本",
    "quickshell": "填入實際版本", "compositor": "填入實際版本",
    "rust": "填入實際版本", "node": "填入工具鏈版本",
    "ditto_commit": "填入 git commit"
  },
  "units": [
    {"name": "ditto-core.service", "layer": "core", "scope": "user"},
    {"name": "ditto-shell.service", "layer": "shell", "scope": "user"},
    {"name": "ditto-compositor.service", "layer": "compositor", "scope": "user"}
  ],
  "excluded": [{"unit": "firefox.scope", "reason": "使用者自行開啟的參考應用"}]
}
```

上例的單元名稱只是格式示例；正式清單必須反映實際 systemd 工作階段。不能因測不到某程序就把它放進排除清單。若單元無 cgroup、無程序或任一 PSS 讀取失敗，原始 JSONL 會保留錯誤，報告產生器會拒絕這組資料。

`conditions.json` 記錄人工可查核的量測條件：

```json
{
  "reference_machine_id": "實體機識別",
  "physical_reference_machine": false,
  "cold_login_each_run": false,
  "warmup_seconds": 0,
  "fixed_variables": ["桌面元件與背景", "角色素材與狀態", "參考應用與內容"]
}
```

正式執行時依實際情況填入，不得為了讓報告顯示條件齊全而假填。報告仍須由出口評審核對原始資料與參考機指紋；程式不自動宣稱達標。

## 指令

```sh
cargo run --locked -p ditto-measure -- sample manifest.json 121 5000 artifacts/g0/measure-run1.jsonl
cargo run --locked -p ditto-measure -- report conditions.json artifacts/g0/measure-run1.jsonl artifacts/g0/measure-run2.jsonl artifacts/g0/measure-run3.jsonl artifacts/g0/resource-report.md
```

121 個樣本、間隔 5 秒涵蓋至少 600 秒。先完成冷登入與 300 秒暖機，再啟動採樣；重複三次，三個 run ID 必須不同。整個流程由 [`tests/g0/measure/run.sh`](../../tests/g0/measure/run.sh) 執行，它在非參考機上只允許格式檢查。完整固定變因清單見 [量測 profile](../../tests/g0/measure/profile.md)。

## G1 狀態（EX1-10）

`state` 另接受 plan/03/06 §7.2 的四個狀態：`rescue_no_node`、`desktop_full_no_agent`、`desktop_full_no_avatar`，以及 10 插件 A/B 的兩半 `desktop_full_plus10_a`／`desktop_full_plus10_b`。G1 的 manifest 多兩個欄位：

- `login_id`：這次 run 所在的登入（必填）。報告要求三次來自三個不同登入；A/B 報告要求每組 A 與 B 來自同一個登入。
- `node_memory`：`{"unit": "<hostd 的單元>", "relay_socket": "<驗證 relay 的 socket>"}`。每次採樣經 relay 讀 `desktop.plugins.diagnostics` 的 `host.heap`，把 `heap_used`、`external`、`array_buffers` 掛在 hostd 回報的那個 PID 上（必須屬於該單元）。讀不到時記在該樣本的 `node_memory_errors`，不產生數字。三欄**不相加，也不與 PSS 相加**。

驗證時檢查每個狀態必備的層：完整桌面各狀態要有 Core、Shell、合成器、`supervisor` 與 `hostd`，且必須有 `node_memory`；`rescue_no_node` 要有 Core、合成器、`supervisor` 與 Shell 或救援介面，且**不得**有 `hostd`、驗證 relay 或 `node_memory`。`verification-relay` 層（`install-session.sh --verification-relay` 才有的回讀 relay）照樣採樣與列出，但不計入桌面合計，報告會寫明。

`report` 依樣本的狀態選報告：G0 子集沿用原本的 G0 報告（程式未改），G1 狀態產生 EX1-10 報告。G1 報告寫出適用的預算與量到的值：`desktop_full_no_agent` 是 hostd ≤100 MiB 與全桌面 ≤600 MiB，以三次各自的 p95 判定；`rescue_no_node` 沒有預算（分列，不作全桌面數字）；`desktop_full_no_avatar` 只列數字；`desktop_full_plus10_b` 指向 A/B 報告。只有條件齊全（參考機、實體機、每次冷登入、暖機 ≥300 秒、每次採樣跨度 ≥600 秒）且三次都在門檻內時才寫「三次 p95 皆未超過門檻」，否則是「未達」或「不判定」。

```sh
ditto-measure report-ab conditions.json a1.jsonl b1.jsonl a2.jsonl b2.jsonl a3.jsonl b3.jsonl report-ab.md
```

`report-ab` 以每組的 p95(B) − p95(A)（桌面合計）對 10 插件增量 ≤50 MiB 判定，並列中位數增量、分層增量與 hostd 的 V8 欄位。`conditions.json` 的 `plus10_loaded` 記錄每次登入啟用後實際載入的數量（Cordis 執行中、Shell 掛上的 QML）；任何一次不足 5＋5，報告就不對門檻判定。流程由 [`tests/g1/measure/cold-login.sh`](../../tests/g1/measure/cold-login.sh) 執行。
