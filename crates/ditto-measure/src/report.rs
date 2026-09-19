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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn p95_is_nearest_rank() {
        let values: Vec<_> = (1..=100).collect();
        assert_eq!(stats(&values), (50.5, 95, 100));
    }
}
