//! G0 raw process sampler. Reports and acceptance decisions require three runs
//! on the frozen physical reference machine; this module never claims a pass.

use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    fs, io,
    path::{Component, Path, PathBuf},
    process::Command,
    time::Instant,
};

use serde::{Deserialize, Serialize};

pub mod report;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub run_id: String,
    pub state: String,
    pub fingerprint: BTreeMap<String, String>,
    pub units: Vec<Unit>,
    pub excluded: Vec<Exclusion>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Unit {
    pub name: String,
    pub layer: String,
    pub scope: Scope,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    User,
    System,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Exclusion {
    pub unit: String,
    pub reason: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProcessSample {
    pub unit: String,
    pub layer: String,
    pub pid: u32,
    pub cgroup: String,
    pub cmdline: String,
    pub pss_kib: Option<u64>,
    pub rss_kib: Option<u64>,
    pub cpu_pct: Option<f64>,
    pub threads: Option<u64>,
    pub fds: Option<usize>,
    #[serde(default)]
    pub node_memory: Option<NodeMemory>,
    pub read_errors: Vec<String>,
}

/// Reserved for G1+ Node hosts. These values are diagnostic and must not be
/// added together or treated as process PSS.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NodeMemory {
    pub heap_used_bytes: u64,
    pub external_bytes: u64,
    pub array_buffers_bytes: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Sample {
    pub run_id: String,
    pub ts: String,
    pub state: String,
    pub fingerprint: BTreeMap<String, String>,
    pub processes: Vec<ProcessSample>,
    pub excluded: Vec<Exclusion>,
    pub gpu: GpuStatus,
    pub errors: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GpuStatus {
    pub available: bool,
    pub reason: String,
}

pub fn validate_manifest(manifest: &Manifest) -> io::Result<()> {
    if manifest.run_id.trim().is_empty()
        || manifest.state.trim().is_empty()
        || manifest.units.is_empty()
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "run_id, state and units are required",
        ));
    }
    if !matches!(
        manifest.state.as_str(),
        "development" | "desktop_full_no_agent_g0_subset"
    ) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unsupported G0 measurement state",
        ));
    }
    let included: BTreeSet<_> = manifest
        .units
        .iter()
        .map(|unit| unit.name.as_str())
        .collect();
    if included.len() != manifest.units.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "duplicate included unit",
        ));
    }
    if manifest.state == "desktop_full_no_agent_g0_subset" {
        let layers: BTreeSet<_> = manifest
            .units
            .iter()
            .map(|unit| unit.layer.as_str())
            .collect();
        if ["core", "shell", "compositor"]
            .iter()
            .any(|layer| !layers.contains(layer))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "G0 subset must include Core, Shell and compositor units",
            ));
        }
    }
    for exclusion in &manifest.excluded {
        if exclusion.reason.trim().is_empty() || included.contains(exclusion.unit.as_str()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "exclusion needs a reason and cannot overlap an included unit",
            ));
        }
    }
    for key in [
        "kernel",
        "qt",
        "quickshell",
        "compositor",
        "rust",
        "node",
        "ditto_commit",
    ] {
        if !manifest
            .fingerprint
            .get(key)
            .is_some_and(|value| !value.trim().is_empty())
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("fingerprint missing {key}"),
            ));
        }
    }
    let actual_kernel = fs::read_to_string("/proc/sys/kernel/osrelease")?;
    if manifest.fingerprint["kernel"] != actual_kernel.trim() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "fingerprint kernel does not match this machine",
        ));
    }
    Ok(())
}

fn unit_cgroup(unit: &Unit) -> io::Result<String> {
    let mut command = Command::new("systemctl");
    if matches!(unit.scope, Scope::User) {
        command.arg("--user");
    }
    let output = command
        .args(["show", "--property=ControlGroup", "--value", &unit.name])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "systemctl failed for {}",
            unit.name
        )));
    }
    let cgroup = String::from_utf8(output.stdout)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "non-UTF8 cgroup"))?;
    let cgroup = cgroup.trim().to_owned();
    if cgroup.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("unit {} has no ControlGroup", unit.name),
        ));
    }
    Ok(cgroup)
}

pub fn cgroup_directory(root: &Path, control_group: &str) -> io::Result<PathBuf> {
    let relative = Path::new(control_group.trim_start_matches('/'));
    if control_group.trim_matches('/').is_empty()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid cgroup path",
        ));
    }
    let base = root.canonicalize()?;
    let candidate = root.join(relative).canonicalize()?;
    if !candidate.starts_with(base) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "cgroup escapes root",
        ));
    }
    Ok(candidate)
}

fn pids_in_cgroup(directory: &Path, pids: &mut BTreeSet<u32>) -> io::Result<()> {
    for line in fs::read_to_string(directory.join("cgroup.procs"))?.lines() {
        if let Ok(pid) = line.parse() {
            pids.insert(pid);
        }
    }
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            pids_in_cgroup(&entry.path(), pids)?;
        }
    }
    Ok(())
}

fn kib_field(contents: &str, key: &str) -> Option<u64> {
    contents
        .lines()
        .find_map(|line| line.strip_prefix(key))
        .and_then(|value| value.split_whitespace().next())
        .and_then(|value| value.parse().ok())
}

/// /proc/<pid>/stat's comm may contain spaces and parentheses, so split only
/// after its final ')' and count from field 3. utime/stime are fields 14/15.
pub fn cpu_ticks(stat: &str) -> Option<u64> {
    let end = stat.rfind(')')?;
    let fields: Vec<_> = stat[end + 1..].split_whitespace().collect();
    Some(fields.get(11)?.parse::<u64>().ok()? + fields.get(12)?.parse::<u64>().ok()?)
}

fn process_sample(
    unit: &Unit,
    cgroup: &str,
    pid: u32,
    previous: Option<(u64, Instant)>,
    hz: f64,
) -> ProcessSample {
    let base = PathBuf::from(format!("/proc/{pid}"));
    let mut errors = Vec::new();
    let read = |name: &str, errors: &mut Vec<String>| -> Option<String> {
        match fs::read_to_string(base.join(name)) {
            Ok(value) => Some(value),
            Err(error) => {
                errors.push(format!("{name}: {}", error.kind()));
                None
            }
        }
    };
    let smaps = read("smaps_rollup", &mut errors);
    let status = read("status", &mut errors);
    let stat = read("stat", &mut errors);
    let pss_kib = smaps.as_deref().and_then(|value| kib_field(value, "Pss:"));
    let rss_kib = status
        .as_deref()
        .and_then(|value| kib_field(value, "VmRSS:"));
    let threads = status
        .as_deref()
        .and_then(|value| kib_field(value, "Threads:"));
    let cpu_pct = match (stat.as_deref().and_then(cpu_ticks), previous) {
        (Some(now), Some((before, at))) if now >= before && at.elapsed().as_secs_f64() > 0.0 => {
            Some((now - before) as f64 / hz / at.elapsed().as_secs_f64() * 100.0)
        }
        _ => None,
    };
    let fds = match fs::read_dir(base.join("fd")) {
        Ok(entries) => Some(entries.count()),
        Err(error) => {
            errors.push(format!("fd: {}", error.kind()));
            None
        }
    };
    let cmdline = match fs::read(base.join("cmdline")) {
        Ok(bytes) => String::from_utf8_lossy(&bytes)
            .replace('\0', " ")
            .trim()
            .to_owned(),
        Err(error) => {
            errors.push(format!("cmdline: {}", error.kind()));
            String::new()
        }
    };
    ProcessSample {
        unit: unit.name.clone(),
        layer: unit.layer.clone(),
        pid,
        cgroup: cgroup.into(),
        cmdline,
        pss_kib,
        rss_kib,
        cpu_pct,
        threads,
        fds,
        node_memory: None,
        read_errors: errors,
    }
}

pub struct Sampler {
    previous_ticks: HashMap<u32, (u64, Instant)>,
    hz: f64,
}

impl Sampler {
    pub fn new() -> io::Result<Self> {
        // SAFETY: sysconf with _SC_CLK_TCK has no pointer arguments.
        let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        if ticks <= 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            previous_ticks: HashMap::new(),
            hz: ticks as f64,
        })
    }

    pub fn sample(&mut self, manifest: &Manifest) -> Sample {
        let mut processes = Vec::new();
        let mut errors = Vec::new();
        let mut seen_pids = HashMap::<u32, String>::new();
        let now = Instant::now();
        let mut next_ticks = HashMap::new();
        for unit in &manifest.units {
            let outcome = unit_cgroup(unit).and_then(|cgroup| {
                let directory = cgroup_directory(Path::new("/sys/fs/cgroup"), &cgroup)?;
                let mut pids = BTreeSet::new();
                pids_in_cgroup(&directory, &mut pids)?;
                Ok((cgroup, pids))
            });
            match outcome {
                Ok((cgroup, pids)) => {
                    if pids.is_empty() {
                        errors.push(format!("{}: cgroup has no processes", unit.name));
                    }
                    for pid in pids {
                        if pid == std::process::id() {
                            errors
                                .push(format!("{}: sampler is inside measured cgroup", unit.name));
                            continue;
                        }
                        if let Some(first_unit) = seen_pids.insert(pid, unit.name.clone()) {
                            errors.push(format!(
                                "PID {pid} belongs to both {first_unit} and {}",
                                unit.name
                            ));
                            continue;
                        }
                        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok();
                        if let Some(ticks) = stat.as_deref().and_then(cpu_ticks) {
                            next_ticks.insert(pid, (ticks, now));
                        }
                        processes.push(process_sample(
                            unit,
                            &cgroup,
                            pid,
                            self.previous_ticks.get(&pid).copied(),
                            self.hz,
                        ));
                    }
                }
                Err(error) => errors.push(format!("{}: {error}", unit.name)),
            }
        }
        self.previous_ticks = next_ticks;
        Sample {
            run_id: manifest.run_id.clone(),
            ts: chrono::Utc::now().to_rfc3339(),
            state: manifest.state.clone(),
            fingerprint: manifest.fingerprint.clone(),
            processes,
            excluded: manifest.excluded.clone(),
            gpu: GpuStatus {
                available: false,
                reason: "GPU collector not configured for reference hardware".into(),
            },
            errors,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_stat_after_complex_comm() {
        let mut fields = vec!["S".to_owned(); 13];
        fields[11] = "24".into();
        fields[12] = "6".into();
        assert_eq!(
            cpu_ticks(&format!("12 (a ) strange name) {}", fields.join(" "))),
            Some(30)
        );
    }

    #[test]
    fn refuses_cgroup_traversal() {
        let root = Path::new("/sys/fs/cgroup");
        assert!(cgroup_directory(root, "/../../etc").is_err());
    }

    #[test]
    fn g0_subset_cannot_omit_compositor() {
        let manifest = Manifest {
            run_id: "test".into(),
            state: "desktop_full_no_agent_g0_subset".into(),
            fingerprint: BTreeMap::new(),
            units: vec![Unit {
                name: "ditto-core.service".into(),
                layer: "core".into(),
                scope: Scope::User,
            }],
            excluded: vec![],
        };
        assert!(validate_manifest(&manifest)
            .unwrap_err()
            .to_string()
            .contains("Core, Shell and compositor"));
    }
}
