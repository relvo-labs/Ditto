use std::{
    collections::{BTreeMap, BTreeSet},
    fs::File,
    io::{self, BufRead, BufReader},
    path::Path,
};

use chrono::{DateTime, FixedOffset};
use serde::Deserialize;

use crate::Sample;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Conditions {
    pub reference_machine_id: String,
    pub physical_reference_machine: bool,
    pub cold_login_each_run: bool,
    pub warmup_seconds: u64,
    pub fixed_variables: Vec<String>,
    /// G1 A/B only: what the runner read back after enabling the ten D-34
    /// plugins in each login. Absent from G0 conditions.
    #[serde(default)]
    pub plus10_loaded: Vec<Plus10Loaded>,
}

/// The readback after the one ChangeSet that enabled the D-34 set.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Plus10Loaded {
    pub login_id: String,
    /// Cordis entries of the set whose fiber is `active` in hostd.
    pub cordis_active: u32,
    /// QML entries of the set the Shell mounted (shell_mounted_providers after
    /// minus before).
    pub qml_mounted: u32,
    #[serde(default)]
    pub note: String,
}

struct Run {
    samples: Vec<Sample>,
    span_seconds: f64,
}

fn load_run(path: &Path) -> io::Result<Run> {
    let mut samples = Vec::new();
    for line in BufReader::new(File::open(path)?).lines() {
        let line = line?;
        if !line.trim().is_empty() {
            samples.push(serde_json::from_str::<Sample>(&line)?);
        }
    }
    if samples.len() < 2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{}: need at least two samples", path.display()),
        ));
    }
    let first = DateTime::<FixedOffset>::parse_from_rfc3339(&samples[0].ts)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let last = DateTime::<FixedOffset>::parse_from_rfc3339(&samples[samples.len() - 1].ts)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let span_seconds = (last - first).num_milliseconds() as f64 / 1000.0;
    if span_seconds <= 0.0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "samples are not in time order",
        ));
    }
    let initial = &samples[0];
    if samples.iter().any(|sample| {
        sample.run_id != initial.run_id
            || sample.state != initial.state
            || sample.fingerprint != initial.fingerprint
            || sample.excluded != initial.excluded
    }) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "metadata changed within a run",
        ));
    }
    Ok(Run {
        samples,
        span_seconds,
    })
}

fn stats(values: &[u64]) -> (f64, u64, u64) {
    let mut sorted = values.to_vec();
    sorted.sort_unstable();
    let mid = sorted.len() / 2;
    let median = if sorted.len().is_multiple_of(2) {
        (sorted[mid - 1] as f64 + sorted[mid] as f64) / 2.0
    } else {
        sorted[mid] as f64
    };
    let p95 = sorted[(sorted.len() as f64 * 0.95).ceil() as usize - 1];
    (median, p95, *sorted.last().expect("nonempty values"))
}

fn cell(value: &str) -> String {
    value.replace('|', "\\|").replace('\n', " ")
}

/// Generate evidence for review. The report never asserts that a budget passed.
pub fn generate(conditions: &Conditions, inputs: &[&Path; 3]) -> io::Result<String> {
    let runs = [
        load_run(inputs[0])?,
        load_run(inputs[1])?,
        load_run(inputs[2])?,
    ];
    let initial = &runs[0].samples[0];
    let ids: BTreeSet<_> = runs
        .iter()
        .map(|run| run.samples[0].run_id.as_str())
        .collect();
    if ids.len() != 3 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "three distinct run IDs are required",
        ));
    }
    if runs.iter().any(|run| {
        run.samples[0].fingerprint != initial.fingerprint
            || run.samples[0].state != initial.state
            || run.samples[0].excluded != initial.excluded
    }) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "runs have different fingerprint, state or exclusion list",
        ));
    }
    let mut out = String::from("# G0 子集資源報告（待出口評審）\n\n");
    let conditions_complete = initial.state == "desktop_full_no_agent_g0_subset"
        && !conditions.reference_machine_id.trim().is_empty()
        && conditions.physical_reference_machine
        && conditions.cold_login_each_run
        && conditions.warmup_seconds >= 300
        && runs.iter().all(|run| run.span_seconds >= 600.0)
        && !conditions.fixed_variables.is_empty();
    if conditions_complete {
        out.push_str(
            "量測條件欄位齊全；仍須核對參考機指紋與原始資料。本報告不宣稱任何預算達標。\n\n",
        );
    } else {
        out.push_str("**開發試跑：條件未滿足 G0 出口量測流程，不可作為 EX-05 證據。**\n\n");
    }
    out.push_str(&format!("| 條件 | 值 |\n| --- | --- |\n| 參考機 | {} |\n| 實體機 | {} |\n| 每次冷登入 | {} |\n| 暖機秒數 | {} |\n| 狀態 | {} |\n| 範圍 | G0 子集；沒有 Cordis 宿主與 Agent |\n\n",
        cell(&conditions.reference_machine_id), conditions.physical_reference_machine,
        conditions.cold_login_each_run, conditions.warmup_seconds, cell(&initial.state)));
    out.push_str("## 版本指紋\n\n| 欄位 | 值 |\n| --- | --- |\n");
    for (key, value) in &initial.fingerprint {
        out.push_str(&format!("| {} | {} |\n", cell(key), cell(value)));
    }
    out.push_str("\n## 固定變因\n\n");
    for value in &conditions.fixed_variables {
        out.push_str(&format!("- {}\n", value));
    }
    out.push_str("\n## 三次重複與分層 PSS\n\nPSS 單位為 KiB；RSS 僅供診斷，不與 PSS 相加。\n\n| Run ID | 採樣數 | 跨度秒數 | 層 | 中位數 | p95 | 峰值 | 原始資料 |\n| --- | ---: | ---: | --- | ---: | ---: | ---: | --- |\n");
    for (index, run) in runs.iter().enumerate() {
        let mut per_layer: BTreeMap<String, Vec<u64>> = BTreeMap::new();
        for sample in &run.samples {
            if !sample.errors.is_empty()
                || sample
                    .processes
                    .iter()
                    .any(|process| process.pss_kib.is_none() || !process.read_errors.is_empty())
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{}: incomplete process sample", inputs[index].display()),
                ));
            }
            let mut totals = BTreeMap::<String, u64>::new();
            for process in &sample.processes {
                *totals.entry(process.layer.clone()).or_default() +=
                    process.pss_kib.expect("checked above");
            }
            if sample.state == "desktop_full_no_agent_g0_subset"
                && ["core", "shell", "compositor"]
                    .iter()
                    .any(|layer| !totals.contains_key(*layer))
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "G0 subset sample is missing a required layer",
                ));
            }
            for (layer, value) in totals {
                per_layer.entry(layer).or_default().push(value);
            }
        }
        for (layer, values) in per_layer {
            if values.len() != run.samples.len() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "a layer vanished during sampling",
                ));
            }
            let (median, p95, peak) = stats(&values);
            out.push_str(&format!(
                "| {} | {} | {:.1} | {} | {:.1} | {} | {} | `{}` |\n",
                cell(&run.samples[0].run_id),
                run.samples.len(),
                run.span_seconds,
                cell(&layer),
                median,
                p95,
                peak,
                inputs[index].display()
            ));
        }
    }
    out.push_str("\n## 完整程序清單\n\n| Run ID | 單元 | 層 | PID | cgroup | 命令 |\n| --- | --- | --- | ---: | --- | --- |\n");
    for run in &runs {
        let mut processes = BTreeMap::new();
        for sample in &run.samples {
            for process in &sample.processes {
                processes.insert((process.unit.clone(), process.pid), process);
            }
        }
        for process in processes.values() {
            out.push_str(&format!(
                "| {} | {} | {} | {} | {} | {} |\n",
                cell(&run.samples[0].run_id),
                cell(&process.unit),
                cell(&process.layer),
                process.pid,
                cell(&process.cgroup),
                cell(&process.cmdline)
            ));
        }
    }
    out.push_str("\n## 顯式排除清單\n\n| 單元 | 原因 |\n| --- | --- |\n");
    for exclusion in &initial.excluded {
        out.push_str(&format!(
            "| {} | {} |\n",
            cell(&exclusion.unit),
            cell(&exclusion.reason)
        ));
    }
    out.push_str("\n## 本階段不可量測\n\nCordis 宿主、Agent 暖態、無 Node 救援模式、完整桌面總量與活動工作在 G0 不可量測；不以 G0 子集數字代替。GPU／顯存欄位目前沒有採集器，原始資料中的原因須保留。\n");
    out.push_str("\n## GPU／顯存採集狀態\n\n| Run ID | 可取得 | 原因 |\n| --- | --- | --- |\n");
    for run in &runs {
        let gpu = &run.samples[0].gpu;
        out.push_str(&format!(
            "| {} | {} | {} |\n",
            cell(&run.samples[0].run_id),
            gpu.available,
            cell(&gpu.reason)
        ));
    }
    Ok(out)
}

// ---- G1 (EX1-10) -------------------------------------------------------------

const MIB: u64 = 1024;
const HOSTD_BUDGET_KIB: u64 = 100 * MIB;
const DESKTOP_BUDGET_KIB: u64 = 600 * MIB;
const PLUS10_BUDGET_KIB: u64 = 50 * MIB;
/// The D-34 set: five QML status items and five Cordis settings plugins.
const PLUS10_QML: u32 = 5;
const PLUS10_CORDIS: u32 = 5;

/// `report` for any state: the G0 subset keeps its own report unchanged.
pub fn generate_any(conditions: &Conditions, inputs: &[&Path; 3]) -> io::Result<String> {
    let first = load_run(inputs[0])?;
    if crate::is_g1_state(&first.samples[0].state) {
        generate_g1(conditions, inputs)
    } else {
        generate(conditions, inputs)
    }
}

/// Per-run figures in KiB (PSS) and bytes (V8).
struct RunStats {
    run: Run,
    layers: BTreeMap<String, Vec<u64>>,
    /// Sum of every layer except the verification relay, per sample.
    total: Vec<u64>,
    heap_used: Vec<u64>,
    external: Vec<u64>,
    array_buffers: Vec<u64>,
    heap_missing: usize,
}

fn analyze(path: &Path) -> io::Result<RunStats> {
    let run = load_run(path)?;
    let state = run.samples[0].state.clone();
    let mut layers: BTreeMap<String, Vec<u64>> = BTreeMap::new();
    let mut total = Vec::new();
    let (mut heap_used, mut external, mut array_buffers) = (Vec::new(), Vec::new(), Vec::new());
    let mut heap_missing = 0;
    for sample in &run.samples {
        if !sample.errors.is_empty()
            || sample
                .processes
                .iter()
                .any(|process| process.pss_kib.is_none() || !process.read_errors.is_empty())
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("{}: incomplete process sample", path.display()),
            ));
        }
        if sample.login_id != run.samples[0].login_id {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "login changed within a run",
            ));
        }
        let mut totals = BTreeMap::<String, u64>::new();
        for process in &sample.processes {
            *totals.entry(process.layer.clone()).or_default() +=
                process.pss_kib.expect("checked above");
        }
        let shell_like = totals.contains_key("shell") || totals.contains_key("rescue-ui");
        if crate::required_layers(&state)
            .iter()
            .any(|layer| !totals.contains_key(*layer))
            || !shell_like
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("{}: a sample is missing a required layer", path.display()),
            ));
        }
        if state == "rescue_no_node"
            && (totals.contains_key("hostd") || totals.contains_key(crate::VERIFICATION_LAYER))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "rescue_no_node sample contains a Node process",
            ));
        }
        total.push(
            totals
                .iter()
                .filter(|(layer, _)| layer.as_str() != crate::VERIFICATION_LAYER)
                .map(|(_, value)| value)
                .sum(),
        );
        for (layer, value) in totals {
            layers.entry(layer).or_default().push(value);
        }
        match sample
            .processes
            .iter()
            .find_map(|process| process.node_memory.as_ref())
        {
            Some(memory) => {
                heap_used.push(memory.heap_used_bytes);
                external.push(memory.external_bytes);
                array_buffers.push(memory.array_buffers_bytes);
            }
            None if state != "rescue_no_node" => heap_missing += 1,
            None => {}
        }
    }
    if layers
        .values()
        .any(|values| values.len() != run.samples.len())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "a layer vanished during sampling",
        ));
    }
    Ok(RunStats {
        run,
        layers,
        total,
        heap_used,
        external,
        array_buffers,
        heap_missing,
    })
}

fn mib(kib: f64) -> String {
    format!("{:.1}", kib / 1024.0)
}

fn bytes_mib(bytes: f64) -> String {
    format!("{:.1}", bytes / 1024.0 / 1024.0)
}

fn state_title(state: &str) -> &'static str {
    match state {
        "rescue_no_node" => "無 Node 救援模式",
        "desktop_full_no_agent" => "完整桌面（hostd 常駐、Agent 不存在）",
        "desktop_full_plus10_a" => "完整桌面＋10 插件 A/B 的 A（啟用前）",
        "desktop_full_plus10_b" => "完整桌面＋D-34 的 10 個簡單插件（A/B 的 B）",
        "desktop_full_no_avatar" => "完整桌面、角色關閉",
        _ => "未知狀態",
    }
}

fn conditions_complete(conditions: &Conditions, runs: &[&RunStats]) -> bool {
    !conditions.reference_machine_id.trim().is_empty()
        && !conditions.reference_machine_id.starts_with("development")
        && conditions.physical_reference_machine
        && conditions.cold_login_each_run
        && conditions.warmup_seconds >= 300
        && runs.iter().all(|stats| stats.run.span_seconds >= 600.0)
        && !conditions.fixed_variables.is_empty()
}

/// The judgement against one budget, from the p95 of each of the three runs.
fn verdict(complete: bool, p95s: &[u64], limit_kib: u64) -> &'static str {
    if !complete {
        "不判定：條件未滿足 EX1-10 的量測流程（開發試跑）"
    } else if p95s.iter().all(|value| *value <= limit_kib) {
        "三次 p95 皆未超過門檻；仍須出口評審核對指紋與原始資料"
    } else {
        "未達：至少一次 p95 超過門檻。依原則 5 不調整門檻或範圍，須附數據提出調整提案或修正實作"
    }
}

fn check_series(runs: &[&RunStats], same_state: bool) -> io::Result<()> {
    let initial = &runs[0].run.samples[0];
    let ids: BTreeSet<_> = runs
        .iter()
        .map(|stats| stats.run.samples[0].run_id.as_str())
        .collect();
    if ids.len() != runs.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "every run needs its own run ID",
        ));
    }
    if runs.iter().any(|stats| {
        let sample = &stats.run.samples[0];
        sample.fingerprint != initial.fingerprint
            || (same_state && sample.state != initial.state)
            || sample.excluded != initial.excluded
            || sample.login_id.is_none()
    }) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "runs have different fingerprint, state or exclusion list, or no login id",
        ));
    }
    Ok(())
}

fn distinct_logins(runs: &[&RunStats]) -> io::Result<()> {
    let logins: BTreeSet<_> = runs
        .iter()
        .map(|stats| stats.run.samples[0].login_id.clone())
        .collect();
    if logins.len() != runs.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the three runs must come from three different logins",
        ));
    }
    Ok(())
}

fn push_header(out: &mut String, conditions: &Conditions, state: &str, complete: bool) {
    if complete {
        out.push_str("量測條件欄位齊全；仍須出口評審核對參考機指紋與原始資料。\n\n");
    } else {
        out.push_str("**開發試跑：條件未滿足 EX1-10 的量測流程（參考機、實體機、每次冷登入、暖機 300 秒、採樣 600 秒），不可作為出口證據。**\n\n");
    }
    let scope = if state == "rescue_no_node" {
        "Core（`--mode rescue`）、Shell 或救援介面、合成器、`ditto-supervisor`、鎖定客戶端（若在執行）、Fcitx；沒有 hostd，也沒有任何 Node 程序"
    } else {
        "Core、Shell、hostd、合成器、`ditto-supervisor`、鎖定客戶端（若在執行）、Fcitx；Agent 不存在"
    };
    out.push_str(&format!(
        "| 條件 | 值 |\n| --- | --- |\n| 參考機 | {} |\n| 實體機 | {} |\n| 每次冷登入 | {} |\n| 暖機秒數（各次實際最短值） | {} |\n| 狀態 | `{}`：{} |\n| 範圍 | {scope} |\n\n",
        cell(&conditions.reference_machine_id),
        conditions.physical_reference_machine,
        conditions.cold_login_each_run,
        conditions.warmup_seconds,
        cell(state),
        state_title(state)
    ));
}

fn push_fingerprint_and_variables(out: &mut String, conditions: &Conditions, sample: &Sample) {
    out.push_str("## 版本指紋\n\n| 欄位 | 值 |\n| --- | --- |\n");
    for (key, value) in &sample.fingerprint {
        out.push_str(&format!("| {} | {} |\n", cell(key), cell(value)));
    }
    out.push_str("\n## 固定變因\n\n");
    for value in &conditions.fixed_variables {
        out.push_str(&format!("- {}\n", value));
    }
}

fn push_layers(out: &mut String, stats: &RunStats, path: &Path, total_label: &str) {
    let run_id = cell(&stats.run.samples[0].run_id);
    let login = cell(stats.run.samples[0].login_id.as_deref().unwrap_or(""));
    for (layer, values) in &stats.layers {
        let (median, p95, peak) = stats_of(values);
        let label = if layer == crate::VERIFICATION_LAYER {
            format!("{layer}（量測工具，不計入合計）")
        } else {
            layer.clone()
        };
        out.push_str(&format!(
            "| {run_id} | {login} | {} | {:.1} | {} | {:.1} | {} | {} | {:.1} | {} | {} | {} | `{}` |\n",
            stats.run.samples.len(),
            stats.run.span_seconds,
            cell(&label),
            median,
            p95,
            peak,
            median / 1024.0,
            mib(p95 as f64),
            mib(peak as f64),
            if layer == crate::VERIFICATION_LAYER {
                "否"
            } else {
                "是"
            },
            path.display()
        ));
    }
    let (median, p95, peak) = stats_of(&stats.total);
    out.push_str(&format!(
        "| {run_id} | {login} | {} | {:.1} | **{total_label}** | {:.1} | {} | {} | {:.1} | {} | {} | — | `{}` |\n",
        stats.run.samples.len(),
        stats.run.span_seconds,
        median,
        p95,
        peak,
        median / 1024.0,
        mib(p95 as f64),
        mib(peak as f64),
        path.display()
    ));
}

fn stats_of(values: &[u64]) -> (f64, u64, u64) {
    stats(values)
}

const LAYER_TABLE_HEAD: &str = "| Run ID | 登入 | 採樣數 | 跨度秒數 | 層 | 中位數 KiB | p95 KiB | 峰值 KiB | 中位數 MiB | p95 MiB | 峰值 MiB | 計入合計 | 原始資料 |\n| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |\n";

fn push_heap(out: &mut String, all: &[&RunStats]) {
    out.push_str("\n## hostd 的 V8 記憶體（hostd 自報，與 PSS 分開）\n\n`heap_used`、`external`、`array_buffers` 取自 `desktop.plugins.diagnostics` 的 `host.heap`（hostd 每 10 秒回報一次，採樣時取最近一次），**三欄不相加，也不與 PSS 相加**；同程序插件沒有各自的記憶體數字（RUN-08）。單位 MiB。\n\n| Run ID | 有值樣本 | 缺值樣本 | heap_used 中位數／p95／峰值 | external 中位數／p95／峰值 | array_buffers 中位數／p95／峰值 |\n| --- | ---: | ---: | --- | --- | --- |\n");
    for stats in all {
        let three = |values: &[u64]| {
            if values.is_empty() {
                "—".to_string()
            } else {
                let (median, p95, peak) = stats_of(values);
                format!(
                    "{}／{}／{}",
                    bytes_mib(median),
                    bytes_mib(p95 as f64),
                    bytes_mib(peak as f64)
                )
            }
        };
        out.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} |\n",
            cell(&stats.run.samples[0].run_id),
            stats.heap_used.len(),
            stats.heap_missing,
            three(&stats.heap_used),
            three(&stats.external),
            three(&stats.array_buffers)
        ));
    }
    let notes: BTreeSet<_> = all
        .iter()
        .flat_map(|stats| stats.run.samples.iter())
        .flat_map(|sample| sample.node_memory_errors.iter())
        .collect();
    if !notes.is_empty() {
        out.push_str("\n缺值原因（原樣）：\n\n");
        for note in notes {
            out.push_str(&format!("- `{}`\n", cell(note)));
        }
    }
}

fn push_processes_and_exclusions(out: &mut String, all: &[&RunStats]) {
    out.push_str("\n## 完整程序清單\n\n| Run ID | 單元 | 層 | PID | cgroup | 命令 |\n| --- | --- | --- | ---: | --- | --- |\n");
    for stats in all {
        let mut processes = BTreeMap::new();
        for sample in &stats.run.samples {
            for process in &sample.processes {
                processes.insert((process.unit.clone(), process.pid), process);
            }
        }
        for process in processes.values() {
            out.push_str(&format!(
                "| {} | {} | {} | {} | {} | {} |\n",
                cell(&stats.run.samples[0].run_id),
                cell(&process.unit),
                cell(&process.layer),
                process.pid,
                cell(&process.cgroup),
                cell(&process.cmdline)
            ));
        }
    }
    out.push_str("\n## 顯式排除清單\n\n| 單元 | 原因 |\n| --- | --- |\n");
    for exclusion in &all[0].run.samples[0].excluded {
        out.push_str(&format!(
            "| {} | {} |\n",
            cell(&exclusion.unit),
            cell(&exclusion.reason)
        ));
    }
    if all
        .iter()
        .any(|stats| stats.layers.contains_key(crate::VERIFICATION_LAYER))
    {
        out.push_str("\n`verification-relay` 是 `install-session.sh --verification-relay` 才有的回讀 relay（`tests/g1/lib/relay.mjs`，由 Core 以 `dittoctl` 身分啟動的 Node 程序）。產品不含它，所以不計入合計；它仍在上方逐次列出 PSS 與程序，並不在排除清單中。它每次採樣向 Core 讀一次診斷，這份負載包含在 Core 與 hostd 的數字裡。\n");
    }
    out.push_str("\n## GPU／顯存採集狀態\n\n| Run ID | 可取得 | 原因 |\n| --- | --- | --- |\n");
    for stats in all {
        let gpu = &stats.run.samples[0].gpu;
        out.push_str(&format!(
            "| {} | {} | {} |\n",
            cell(&stats.run.samples[0].run_id),
            gpu.available,
            cell(&gpu.reason)
        ));
    }
}

/// EX1-10 layered report for one state. The budget it applies is named next
/// to the numbers; "met" is never written unless the conditions are complete
/// and every run's p95 is within it.
pub fn generate_g1(conditions: &Conditions, inputs: &[&Path; 3]) -> io::Result<String> {
    let all = [
        analyze(inputs[0])?,
        analyze(inputs[1])?,
        analyze(inputs[2])?,
    ];
    let refs: Vec<&RunStats> = all.iter().collect();
    check_series(&refs, true)?;
    distinct_logins(&refs)?;
    let state = refs[0].run.samples[0].state.clone();
    if !crate::is_g1_state(&state) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "not a G1 measurement state",
        ));
    }
    let complete = conditions_complete(conditions, &refs);
    let mut out = format!(
        "# G1 分層資源報告：{}（EX1-10，待出口評審）\n\n",
        state_title(&state)
    );
    push_header(&mut out, conditions, &state, complete);

    out.push_str("## 適用預算\n\n");
    let total_label = if state == "rescue_no_node" {
        "救援模式合計（不作全桌面數字）"
    } else {
        "桌面合計"
    };
    match state.as_str() {
        "desktop_full_no_agent" => {
            out.push_str("穩態門檻以每次的 p95 判定（三次都要在門檻內）。\n\n| 預算 | 依據 | 三次 p95（MiB） | 判定 |\n| --- | --- | --- | --- |\n");
            let hostd: Vec<u64> = refs
                .iter()
                .map(|stats| stats_of(&stats.layers["hostd"]).1)
                .collect();
            let total: Vec<u64> = refs.iter().map(|stats| stats_of(&stats.total).1).collect();
            for (label, values, limit) in [
                ("hostd PSS ≤100 MiB", &hostd, HOSTD_BUDGET_KIB),
                ("全桌面 PSS ≤600 MiB（Agent 不存在）", &total, DESKTOP_BUDGET_KIB),
            ] {
                out.push_str(&format!(
                    "| {label} | plan/03/06 §7.2、PRD 19.1 | {} | {} |\n",
                    values
                        .iter()
                        .map(|value| mib(*value as f64))
                        .collect::<Vec<_>>()
                        .join("、"),
                    verdict(complete, values, limit)
                ));
            }
            out.push('\n');
        }
        "rescue_no_node" => out.push_str("無：plan/03/06 §7.2 規定救援模式分列報告，不作全桌面數字，也不以它代表完整桌面成本。\n\n"),
        "desktop_full_plus10_b" => out.push_str("10 插件增量 ≤50 MiB 以同一次登入的 A/B 判定，見 `report-ab` 產生的 A/B 報告；本報告只列 B 狀態的分層數字。\n\n"),
        "desktop_full_plus10_a" => out.push_str("A 狀態只作 A/B 的對照，不單獨對預算判定。\n\n"),
        _ => out.push_str("plan/03/06 §7.2 未另訂預算：PRD 19.1 要求角色關閉與完整桌面並列報告。此處只列數字，不對門檻判定。\n\n"),
    }
    push_fingerprint_and_variables(&mut out, conditions, &refs[0].run.samples[0]);
    out.push_str("\n## 三次重複與分層 PSS\n\nPSS 取自 `/proc/<pid>/smaps_rollup`；RSS 僅供診斷，不與 PSS 相加。\n\n");
    out.push_str(LAYER_TABLE_HEAD);
    for (index, stats) in refs.iter().enumerate() {
        push_layers(&mut out, stats, inputs[index], total_label);
    }
    if state != "rescue_no_node" {
        push_heap(&mut out, &refs);
    }
    push_processes_and_exclusions(&mut out, &refs);
    out.push_str("\n## 本報告不涵蓋\n\nAgent 暖態與活動工作屬於 G2；G1 沒有 Agent。不以其他狀態的數字代替本狀態。\n");
    Ok(out)
}

/// EX1-10 ③: the increment of the ten D-34 plugins, from A and B sampled in
/// the same login, three logins.
pub fn generate_ab(conditions: &Conditions, pairs: &[(&Path, &Path); 3]) -> io::Result<String> {
    let mut a = Vec::new();
    let mut b = Vec::new();
    for (path_a, path_b) in pairs {
        a.push(analyze(path_a)?);
        b.push(analyze(path_b)?);
    }
    let a_refs: Vec<&RunStats> = a.iter().collect();
    let b_refs: Vec<&RunStats> = b.iter().collect();
    check_series(&a_refs, true)?;
    check_series(&b_refs, true)?;
    distinct_logins(&a_refs)?;
    if a_refs[0].run.samples[0].state != "desktop_full_plus10_a"
        || b_refs[0].run.samples[0].state != "desktop_full_plus10_b"
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "A must be desktop_full_plus10_a and B desktop_full_plus10_b",
        ));
    }
    for (stats_a, stats_b) in a_refs.iter().zip(&b_refs) {
        let (sample_a, sample_b) = (&stats_a.run.samples[0], &stats_b.run.samples[0]);
        if sample_a.login_id != sample_b.login_id
            || sample_a.fingerprint != sample_b.fingerprint
            || sample_a.excluded != sample_b.excluded
            || sample_a.run_id == sample_b.run_id
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "each A/B pair must come from one login with the same fingerprint and exclusions, and two run IDs",
            ));
        }
    }
    let mut every: Vec<&RunStats> = a_refs.clone();
    every.extend(b_refs.iter().copied());
    let complete = conditions_complete(conditions, &every);
    // Were all ten plugins really loaded in B, in every login?
    let loaded: Vec<Option<&Plus10Loaded>> = a_refs
        .iter()
        .map(|stats| {
            let login = stats.run.samples[0].login_id.as_deref().unwrap_or("");
            conditions
                .plus10_loaded
                .iter()
                .find(|loaded| loaded.login_id == login)
        })
        .collect();
    let all_loaded = loaded.iter().all(|loaded| {
        loaded.is_some_and(|loaded| {
            loaded.cordis_active == PLUS10_CORDIS && loaded.qml_mounted == PLUS10_QML
        })
    });

    let mut out = String::from("# G1 10 插件 A/B 增量報告（EX1-10 ③，待出口評審）\n\n");
    push_header(&mut out, conditions, "desktop_full_plus10_b", complete);
    out.push_str("A 與 B 在同一次登入中先後採樣：A 是完整桌面（hostd 常駐、Agent 不存在）且 Profile 中沒有 D-34 的插件；之後以**一個** ChangeSet 啟用 D-34 的 10 個簡單插件（5 個 QML 狀態型、5 個 Cordis 設定型），暖機 300 秒後採 B。增量＝B − A，桌面合計不含量測用 relay。\n\n");

    out.push_str("## B 狀態實際載入的插件\n\n| 登入 | Cordis 執行中（應為 5） | Shell 掛上的 QML（應為 5） | 備註 |\n| --- | ---: | ---: | --- |\n");
    for (stats, loaded) in a_refs.iter().zip(&loaded) {
        let login = cell(stats.run.samples[0].login_id.as_deref().unwrap_or(""));
        match loaded {
            Some(loaded) => out.push_str(&format!(
                "| {login} | {} | {} | {} |\n",
                loaded.cordis_active,
                loaded.qml_mounted,
                cell(&loaded.note)
            )),
            None => out.push_str(&format!("| {login} | — | — | 沒有啟用後的回讀紀錄 |\n")),
        }
    }
    if !all_loaded {
        out.push_str("\n**B 狀態沒有在每次登入都載入全部 10 個插件，所以這份 A/B 量到的不是 D-34 的條件，不對 ≤50 MiB 判定。**\n");
    }

    out.push_str("\n## 適用預算\n\n10 個簡單插件的合計增量 ≤50 MiB（plan/03/06 §7.2、ditto-process-budget）。以每次登入的 p95(B) − p95(A) 判定，三次都要在門檻內；中位數增量並列參考。\n\n| 登入 | A 合計 p95 MiB | B 合計 p95 MiB | p95 增量 MiB | A 中位數 MiB | B 中位數 MiB | 中位數增量 MiB |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n");
    let mut increments = Vec::new();
    for (stats_a, stats_b) in a_refs.iter().zip(&b_refs) {
        let (median_a, p95_a, _) = stats_of(&stats_a.total);
        let (median_b, p95_b, _) = stats_of(&stats_b.total);
        let increment = p95_b as i64 - p95_a as i64;
        increments.push(increment.max(0) as u64);
        out.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | {} |\n",
            cell(stats_a.run.samples[0].login_id.as_deref().unwrap_or("")),
            mib(p95_a as f64),
            mib(p95_b as f64),
            mib(increment as f64),
            mib(median_a),
            mib(median_b),
            mib(median_b - median_a)
        ));
    }
    let judgement = if all_loaded {
        verdict(complete, &increments, PLUS10_BUDGET_KIB)
    } else {
        "不判定：B 狀態沒有載入全部 10 個插件"
    };
    out.push_str(&format!("\n判定：{judgement}\n"));

    out.push_str("\n## 分層增量（中位數，MiB）\n\n同程序插件沒有各自的記憶體數字：Cordis 插件的增量落在 hostd，QML 插件的增量落在 Shell（RUN-08）。\n\n| 登入 | 層 | A 中位數 | B 中位數 | 增量 |\n| --- | --- | ---: | ---: | ---: |\n");
    for (stats_a, stats_b) in a_refs.iter().zip(&b_refs) {
        let login = cell(stats_a.run.samples[0].login_id.as_deref().unwrap_or(""));
        let layers: BTreeSet<&String> =
            stats_a.layers.keys().chain(stats_b.layers.keys()).collect();
        for layer in layers {
            let median =
                |stats: &RunStats| stats.layers.get(layer).map(|values| stats_of(values).0);
            let (in_a, in_b) = (median(stats_a), median(stats_b));
            let show = |value: Option<f64>| value.map(mib).unwrap_or_else(|| "—".into());
            let increment = match (in_a, in_b) {
                (Some(a), Some(b)) => mib(b - a),
                _ => "—（只在一側）".into(),
            };
            out.push_str(&format!(
                "| {login} | {} | {} | {} | {} |\n",
                cell(layer),
                show(in_a),
                show(in_b),
                increment
            ));
        }
    }
    out.push('\n');
    push_fingerprint_and_variables(&mut out, conditions, &a_refs[0].run.samples[0]);
    out.push_str("\n## 六次採樣的分層 PSS\n\n");
    out.push_str(LAYER_TABLE_HEAD);
    for (index, (stats_a, stats_b)) in a_refs.iter().zip(&b_refs).enumerate() {
        push_layers(&mut out, stats_a, pairs[index].0, "桌面合計（A）");
        push_layers(&mut out, stats_b, pairs[index].1, "桌面合計（B）");
    }
    push_heap(&mut out, &every);
    push_processes_and_exclusions(&mut out, &every);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn p95_is_nearest_rank() {
        let values: Vec<_> = (1..=100).collect();
        assert_eq!(stats(&values), (50.5, 95, 100));
    }

    use crate::{Exclusion, GpuStatus, NodeMemory, ProcessSample, Sample};
    use std::path::PathBuf;

    struct Dir(PathBuf);
    impl Dir {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "ditto-measure-{name}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Dir(path)
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// 121 samples five seconds apart (600 s), each process at a fixed PSS.
    fn write_run(
        dir: &Dir,
        run_id: &str,
        state: &str,
        login: &str,
        layers: &[(&str, &str, u64)],
    ) -> PathBuf {
        let path = dir.0.join(format!("{run_id}.jsonl"));
        let start = DateTime::parse_from_rfc3339("2026-10-05T00:00:00+00:00").unwrap();
        let mut text = String::new();
        for index in 0..121 {
            let processes = layers
                .iter()
                .enumerate()
                .map(|(pid, (unit, layer, pss))| ProcessSample {
                    unit: unit.to_string(),
                    layer: layer.to_string(),
                    pid: pid as u32 + 100,
                    cgroup: format!("/{unit}"),
                    cmdline: unit.to_string(),
                    pss_kib: Some(*pss),
                    rss_kib: Some(*pss * 2),
                    cpu_pct: None,
                    threads: None,
                    fds: None,
                    node_memory: (*layer == "hostd").then_some(NodeMemory {
                        heap_used_bytes: 12 << 20,
                        external_bytes: 2 << 20,
                        array_buffers_bytes: 1 << 20,
                    }),
                    read_errors: vec![],
                })
                .collect();
            let sample = Sample {
                run_id: run_id.into(),
                ts: (start + chrono::Duration::seconds(5 * index)).to_rfc3339(),
                state: state.into(),
                fingerprint: [("kernel".to_string(), "k".to_string())].into(),
                processes,
                excluded: vec![Exclusion {
                    unit: "ditto-ref-browser.scope".into(),
                    reason: "reference application".into(),
                }],
                gpu: GpuStatus {
                    available: false,
                    reason: "none".into(),
                },
                errors: vec![],
                login_id: Some(login.into()),
                node_memory_errors: vec![],
            };
            text.push_str(&serde_json::to_string(&sample).unwrap());
            text.push('\n');
        }
        std::fs::write(&path, text).unwrap();
        path
    }

    fn desktop(hostd_mib: u64, shell_mib: u64) -> Vec<(&'static str, &'static str, u64)> {
        vec![
            ("ditto-wayfire.scope", "compositor", 100 * 1024),
            ("ditto-core.service", "core", 30 * 1024),
            ("ditto-quickshell.scope", "shell", shell_mib * 1024),
            ("ditto-supervisor.service", "supervisor", 2 * 1024),
            ("ditto-hostd.scope", "hostd", hostd_mib * 1024),
            ("ditto-fcitx.scope", "input-method", 20 * 1024),
            ("ditto-dittoctl.scope", "verification-relay", 40 * 1024),
        ]
    }

    fn conditions(reference: bool) -> Conditions {
        Conditions {
            reference_machine_id: if reference {
                "ditto-ref-ws-rtx4060-01".into()
            } else {
                "development-host".into()
            },
            physical_reference_machine: reference,
            cold_login_each_run: true,
            warmup_seconds: 300,
            fixed_variables: vec!["fixed".into()],
            plus10_loaded: vec![],
        }
    }

    fn three(dir: &Dir, state: &str, layers: &[(&str, &str, u64)]) -> [PathBuf; 3] {
        ["1", "2", "3"].map(|login| write_run(dir, &format!("run{login}"), state, login, layers))
    }

    #[test]
    fn full_desktop_names_both_budgets_and_judges_only_complete_runs() {
        let dir = Dir::new("budgets");
        let paths = three(&dir, "desktop_full_no_agent", &desktop(60, 150));
        let inputs = [paths[0].as_path(), paths[1].as_path(), paths[2].as_path()];
        let report = generate_any(&conditions(true), &inputs).unwrap();
        assert!(report.contains("hostd PSS ≤100 MiB"));
        assert!(report.contains("全桌面 PSS ≤600 MiB"));
        // 100+30+150+2+60+20 = 362 MiB; the relay's 40 MiB is not in it.
        assert!(report.contains("| **桌面合計** | 370688.0 |"), "{report}");
        assert!(report.contains("三次 p95 皆未超過門檻"));
        assert!(report.contains("verification-relay（量測工具，不計入合計）"));
        assert!(report.contains("heap_used"));
        let development = generate_any(&conditions(false), &inputs).unwrap();
        assert!(development.contains("開發試跑"));
        assert!(!development.contains("三次 p95 皆未超過門檻"));
        assert!(development.contains("不判定"));
    }

    #[test]
    fn a_budget_over_the_line_is_not_met() {
        let dir = Dir::new("over");
        let paths = three(&dir, "desktop_full_no_agent", &desktop(101, 150));
        let inputs = [paths[0].as_path(), paths[1].as_path(), paths[2].as_path()];
        let report = generate_g1(&conditions(true), &inputs).unwrap();
        assert!(report.contains("未達"));
    }

    #[test]
    fn three_runs_need_three_logins() {
        let dir = Dir::new("logins");
        let layers = desktop(60, 150);
        let paths =
            ["a", "b", "c"].map(|id| write_run(&dir, id, "desktop_full_no_agent", "same", &layers));
        let inputs = [paths[0].as_path(), paths[1].as_path(), paths[2].as_path()];
        assert!(generate_g1(&conditions(true), &inputs)
            .unwrap_err()
            .to_string()
            .contains("three different logins"));
    }

    #[test]
    fn rescue_report_has_no_budget_and_refuses_node() {
        let dir = Dir::new("rescue");
        let rescue: Vec<_> = desktop(60, 150)
            .into_iter()
            .filter(|(_, layer, _)| *layer != "hostd" && *layer != "verification-relay")
            .collect();
        let paths = three(&dir, "rescue_no_node", &rescue);
        let inputs = [paths[0].as_path(), paths[1].as_path(), paths[2].as_path()];
        let report = generate_g1(&conditions(true), &inputs).unwrap();
        assert!(report.contains("不作全桌面數字"));
        assert!(!report.contains("≤600 MiB"));
        assert!(!report.contains("heap_used"));
        let dir = Dir::new("rescue-node");
        let paths = three(&dir, "rescue_no_node", &desktop(60, 150));
        let inputs = [paths[0].as_path(), paths[1].as_path(), paths[2].as_path()];
        assert!(generate_g1(&conditions(true), &inputs)
            .unwrap_err()
            .to_string()
            .contains("Node"));
    }

    #[test]
    fn g0_reports_keep_their_own_generator() {
        let dir = Dir::new("g0");
        let layers = [
            ("ditto-g0-wayfire.scope", "compositor", 1024),
            ("ditto-g0-core.scope", "core", 1024),
            ("ditto-g0-quickshell.scope", "shell", 1024),
        ];
        let paths = three(&dir, "desktop_full_no_agent_g0_subset", &layers);
        let inputs = [paths[0].as_path(), paths[1].as_path(), paths[2].as_path()];
        let report = generate_any(&conditions(true), &inputs).unwrap();
        assert!(report.starts_with("# G0 子集資源報告"));
    }

    fn pairs(dir: &Dir, shell_b: u64, hostd_b: u64, same_login: bool) -> Vec<(PathBuf, PathBuf)> {
        ["1", "2", "3"]
            .iter()
            .map(|login| {
                let a = write_run(
                    dir,
                    &format!("a{login}"),
                    "desktop_full_plus10_a",
                    login,
                    &desktop(60, 150),
                );
                let login_b = if same_login {
                    login.to_string()
                } else {
                    format!("x{login}")
                };
                let b = write_run(
                    dir,
                    &format!("b{login}"),
                    "desktop_full_plus10_b",
                    &login_b,
                    &desktop(hostd_b, shell_b),
                );
                (a, b)
            })
            .collect()
    }

    fn loaded(cordis: u32, qml: u32) -> Vec<Plus10Loaded> {
        ["1", "2", "3"]
            .iter()
            .map(|login| Plus10Loaded {
                login_id: login.to_string(),
                cordis_active: cordis,
                qml_mounted: qml,
                note: String::new(),
            })
            .collect()
    }

    #[test]
    fn ab_increment_is_judged_per_login_on_p95() {
        let dir = Dir::new("ab");
        let paths = pairs(&dir, 170, 75, true);
        let inputs = [
            (paths[0].0.as_path(), paths[0].1.as_path()),
            (paths[1].0.as_path(), paths[1].1.as_path()),
            (paths[2].0.as_path(), paths[2].1.as_path()),
        ];
        let mut complete = conditions(true);
        complete.plus10_loaded = loaded(5, 5);
        let report = generate_ab(&complete, &inputs).unwrap();
        // shell +20, hostd +15: 35 MiB.
        assert!(report.contains("| 1 | 362.0 | 397.0 | 35.0 |"), "{report}");
        assert!(report.contains("判定：三次 p95 皆未超過門檻"));
        // Only half the set mounted: no judgement at all.
        let mut half = conditions(true);
        half.plus10_loaded = loaded(5, 0);
        let report = generate_ab(&half, &inputs).unwrap();
        assert!(report.contains("不判定：B 狀態沒有載入全部 10 個插件"));
        // Over the line.
        let dir = Dir::new("ab-over");
        let paths = pairs(&dir, 200, 85, true);
        let inputs = [
            (paths[0].0.as_path(), paths[0].1.as_path()),
            (paths[1].0.as_path(), paths[1].1.as_path()),
            (paths[2].0.as_path(), paths[2].1.as_path()),
        ];
        assert!(generate_ab(&complete, &inputs)
            .unwrap()
            .contains("判定：未達"));
    }

    #[test]
    fn ab_pairs_must_share_their_login() {
        let dir = Dir::new("ab-login");
        let paths = pairs(&dir, 170, 75, false);
        let inputs = [
            (paths[0].0.as_path(), paths[0].1.as_path()),
            (paths[1].0.as_path(), paths[1].1.as_path()),
            (paths[2].0.as_path(), paths[2].1.as_path()),
        ];
        assert!(generate_ab(&conditions(true), &inputs)
            .unwrap_err()
            .to_string()
            .contains("one login"));
    }
}
