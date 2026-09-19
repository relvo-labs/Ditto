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
