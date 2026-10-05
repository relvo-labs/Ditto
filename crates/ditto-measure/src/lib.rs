//! Raw process sampler for the G0 subset (EX-05) and the G1 states (EX1-10).
//! Reports and acceptance decisions require three runs on the frozen physical
//! reference machine; sampling never claims a pass.

use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    fs,
    io::{self, BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    path::{Component, Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
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
    /// G1: the display-manager login this run was sampled in. A/B pairs must
    /// share it; the three runs of a state must not.
    #[serde(default)]
    pub login_id: Option<String>,
    /// G1: where hostd's own V8 figures are read (desktop.plugins.diagnostics
    /// through the verification relay). They land next to hostd's PSS and are
    /// never added to it.
    #[serde(default)]
    pub node_memory: Option<NodeMemorySource>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NodeMemorySource {
    /// The unit whose process hostd reports itself as.
    pub unit: String,
    /// The verification relay socket (tests/g1/lib/relay.mjs).
    pub relay_socket: PathBuf,
}

/// The measurement states of plan/03/06 §7.2. `desktop_full_plus10` is
/// sampled twice in one login: `_a` before the ten plugins are enabled, `_b`
/// after.
pub const G1_STATES: [&str; 5] = [
    "rescue_no_node",
    "desktop_full_no_agent",
    "desktop_full_plus10_a",
    "desktop_full_plus10_b",
    "desktop_full_no_avatar",
];

pub fn is_g1_state(state: &str) -> bool {
    G1_STATES.contains(&state)
}

/// Layers every sample of a state must contain. In rescue mode the Shell
/// layer may be the rescue interface instead (checked separately).
pub fn required_layers(state: &str) -> &'static [&'static str] {
    match state {
        "desktop_full_no_agent_g0_subset" => &["core", "shell", "compositor"],
        "rescue_no_node" => &["core", "compositor", "supervisor"],
        state if is_g1_state(state) => &["core", "shell", "compositor", "supervisor", "hostd"],
        _ => &[],
    }
}

/// Verification tooling the session runs only under
/// `install-session.sh --verification-relay`. It is sampled and listed, and
/// kept out of the desktop total because the product does not ship it.
pub const VERIFICATION_LAYER: &str = "verification-relay";

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub login_id: Option<String>,
    /// Why hostd's V8 figures are missing from this sample, if they are. They
    /// do not invalidate the PSS sample; the report counts them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub node_memory_errors: Vec<String>,
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
    ) && !is_g1_state(&manifest.state)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unsupported measurement state",
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
    if is_g1_state(&manifest.state) {
        validate_g1(manifest)?;
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

/// The G1 rules that need no machine: required layers, no hostd, relay or
/// Node figures in rescue mode, Node figures tied to the hostd unit, and a
/// login id on every run.
pub fn validate_g1(manifest: &Manifest) -> io::Result<()> {
    let invalid = |message: String| Err(io::Error::new(io::ErrorKind::InvalidInput, message));
    let layers: BTreeSet<_> = manifest
        .units
        .iter()
        .map(|unit| unit.layer.as_str())
        .collect();
    let missing: Vec<_> = required_layers(&manifest.state)
        .iter()
        .filter(|layer| !layers.contains(*layer))
        .collect();
    if !missing.is_empty() {
        return invalid(format!(
            "{} must include the layers {missing:?}",
            manifest.state
        ));
    }
    if manifest
        .login_id
        .as_deref()
        .is_none_or(|login| login.trim().is_empty())
    {
        return invalid(format!("{} needs the login id of the run", manifest.state));
    }
    if manifest.state == "rescue_no_node" {
        if !layers.contains("shell") && !layers.contains("rescue-ui") {
            return invalid("rescue_no_node must include the Shell or the rescue interface".into());
        }
        if layers.contains("hostd") || layers.contains(VERIFICATION_LAYER) {
            return invalid("rescue_no_node runs no Node process: no hostd and no relay".into());
        }
        if manifest.node_memory.is_some() {
            return invalid("rescue_no_node has no hostd to read Node figures from".into());
        }
        return Ok(());
    }
    let Some(source) = &manifest.node_memory else {
        return invalid(format!(
            "{} samples hostd's heap_used/external/array_buffers (node_memory)",
            manifest.state
        ));
    };
    if !manifest
        .units
        .iter()
        .any(|unit| unit.name == source.unit && unit.layer == "hostd")
    {
        return invalid("node_memory must name the hostd unit".into());
    }
    Ok(())
}

/// hostd's process id and V8 figures from a desktop.plugins.diagnostics
/// response (`{"result": {"host": {"heap": …, "process": {"pid": …}}}}`).
pub fn parse_diagnostics(response: &serde_json::Value) -> Result<(u32, NodeMemory), String> {
    if let Some(error) = response.get("error") {
        return Err(format!("diagnostics refused: {error}"));
    }
    let host = response
        .pointer("/result/host")
        .ok_or("diagnostics response has no host")?;
    let state = host.get("state").and_then(|v| v.as_str()).unwrap_or("");
    let pid = host
        .pointer("/process/pid")
        .and_then(|v| v.as_u64())
        .and_then(|pid| u32::try_from(pid).ok())
        .ok_or_else(|| format!("hostd has no process (state {state:?})"))?;
    let heap = host
        .get("heap")
        .filter(|heap| !heap.is_null())
        .ok_or_else(|| format!("hostd has not reported its heap yet (state {state:?})"))?;
    let field = |name: &str| {
        heap.get(name)
            .and_then(|v| v.as_u64())
            .ok_or_else(|| format!("heap.{name} missing"))
    };
    Ok((
        pid,
        NodeMemory {
            heap_used_bytes: field("heap_used")?,
            external_bytes: field("external")?,
            array_buffers_bytes: field("array_buffers")?,
        },
    ))
}

fn relay_call(socket: &Path, method: &str) -> Result<serde_json::Value, String> {
    let failed = |error: io::Error| format!("relay {}: {error}", socket.display());
    let mut stream = UnixStream::connect(socket).map_err(failed)?;
    let timeout = Some(Duration::from_secs(3));
    stream.set_read_timeout(timeout).map_err(failed)?;
    stream.set_write_timeout(timeout).map_err(failed)?;
    let request = serde_json::json!({"method": method, "params": {}});
    stream
        .write_all(format!("{request}\n").as_bytes())
        .map_err(failed)?;
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .map_err(failed)?;
    serde_json::from_str(&line).map_err(|error| format!("relay answer: {error}"))
}

/// Attach hostd's V8 figures to its own process sample. Every failure becomes
/// a note on the sample, never a number.
pub fn attach_node_memory(
    processes: &mut [ProcessSample],
    unit: &str,
    response: Result<serde_json::Value, String>,
) -> Vec<String> {
    let (pid, memory) = match response.and_then(|value| parse_diagnostics(&value)) {
        Ok(found) => found,
        Err(error) => return vec![error],
    };
    match processes
        .iter_mut()
        .find(|process| process.unit == unit && process.pid == pid)
    {
        Some(process) => {
            process.node_memory = Some(memory);
            Vec::new()
        }
        None => vec![format!(
            "hostd reports PID {pid}, which is not a process of {unit}"
        )],
    }
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
        let node_memory_errors = match &manifest.node_memory {
            Some(source) => attach_node_memory(
                &mut processes,
                &source.unit,
                relay_call(&source.relay_socket, "desktop.plugins.diagnostics"),
            ),
            None => Vec::new(),
        };
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
            login_id: manifest.login_id.clone(),
            node_memory_errors,
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
            login_id: None,
            node_memory: None,
        };
        assert!(validate_manifest(&manifest)
            .unwrap_err()
            .to_string()
            .contains("Core, Shell and compositor"));
    }

    fn unit(name: &str, layer: &str) -> Unit {
        Unit {
            name: name.into(),
            layer: layer.into(),
            scope: Scope::User,
        }
    }

    fn g1_manifest(state: &str) -> Manifest {
        Manifest {
            run_id: "run".into(),
            state: state.into(),
            fingerprint: BTreeMap::new(),
            units: vec![
                unit("ditto-wayfire.scope", "compositor"),
                unit("ditto-core.service", "core"),
                unit("ditto-quickshell.scope", "shell"),
                unit("ditto-supervisor.service", "supervisor"),
                unit("ditto-hostd.scope", "hostd"),
            ],
            excluded: vec![],
            login_id: Some("4".into()),
            node_memory: Some(NodeMemorySource {
                unit: "ditto-hostd.scope".into(),
                relay_socket: "/run/user/1000/ditto/verify-relay.sock".into(),
            }),
        }
    }

    #[test]
    fn g1_desktop_states_need_hostd_and_its_heap() {
        for state in [
            "desktop_full_no_agent",
            "desktop_full_plus10_a",
            "desktop_full_plus10_b",
            "desktop_full_no_avatar",
        ] {
            assert!(validate_g1(&g1_manifest(state)).is_ok(), "{state}");
            let mut without_hostd = g1_manifest(state);
            without_hostd.units.retain(|unit| unit.layer != "hostd");
            assert!(validate_g1(&without_hostd)
                .unwrap_err()
                .to_string()
                .contains("hostd"));
            let mut without_heap = g1_manifest(state);
            without_heap.node_memory = None;
            assert!(validate_g1(&without_heap).is_err());
            let mut heap_elsewhere = g1_manifest(state);
            heap_elsewhere.node_memory.as_mut().unwrap().unit = "ditto-core.service".into();
            assert!(validate_g1(&heap_elsewhere).is_err());
        }
    }

    #[test]
    fn g1_supervisor_cannot_be_left_out() {
        let mut manifest = g1_manifest("desktop_full_no_agent");
        manifest.units.retain(|unit| unit.layer != "supervisor");
        assert!(validate_g1(&manifest)
            .unwrap_err()
            .to_string()
            .contains("supervisor"));
    }

    #[test]
    fn g1_runs_carry_their_login() {
        let mut manifest = g1_manifest("desktop_full_no_agent");
        manifest.login_id = Some(" ".into());
        assert!(validate_g1(&manifest)
            .unwrap_err()
            .to_string()
            .contains("login"));
    }

    #[test]
    fn rescue_state_refuses_node_processes() {
        let mut manifest = g1_manifest("rescue_no_node");
        assert!(validate_g1(&manifest)
            .unwrap_err()
            .to_string()
            .contains("no hostd"));
        manifest.units.retain(|unit| unit.layer != "hostd");
        assert!(
            validate_g1(&manifest).is_err(),
            "Node figures without hostd"
        );
        manifest.node_memory = None;
        assert!(validate_g1(&manifest).is_ok());
        manifest
            .units
            .push(unit("ditto-dittoctl.scope", VERIFICATION_LAYER));
        assert!(validate_g1(&manifest).is_err(), "the relay is Node");
        manifest.units.pop();
        manifest.units.retain(|unit| unit.layer != "shell");
        assert!(validate_g1(&manifest).is_err());
        manifest
            .units
            .push(unit("ditto-rescue-shell.scope", "rescue-ui"));
        assert!(validate_g1(&manifest).is_ok());
    }

    fn process(unit: &str, pid: u32) -> ProcessSample {
        ProcessSample {
            unit: unit.into(),
            layer: "hostd".into(),
            pid,
            cgroup: String::new(),
            cmdline: String::new(),
            pss_kib: Some(1),
            rss_kib: Some(1),
            cpu_pct: None,
            threads: None,
            fds: None,
            node_memory: None,
            read_errors: vec![],
        }
    }

    #[test]
    fn heap_lands_on_the_reporting_hostd_process_only() {
        let response = serde_json::json!({"result": {"host": {"state": "running",
            "process": {"pid": 42, "pss_kib": 1},
            "heap": {"heap_used": 10, "external": 20, "array_buffers": 30}}}});
        let mut processes = vec![
            process("ditto-hostd.scope", 41),
            process("ditto-hostd.scope", 42),
        ];
        assert!(
            attach_node_memory(&mut processes, "ditto-hostd.scope", Ok(response.clone()))
                .is_empty()
        );
        assert!(processes[0].node_memory.is_none());
        let memory = processes[1].node_memory.as_ref().unwrap();
        assert_eq!(
            (
                memory.heap_used_bytes,
                memory.external_bytes,
                memory.array_buffers_bytes
            ),
            (10, 20, 30)
        );
        // A PID outside the unit is a note, not a number.
        let mut elsewhere = vec![process("ditto-core.service", 42)];
        let notes = attach_node_memory(&mut elsewhere, "ditto-hostd.scope", Ok(response));
        assert!(notes[0].contains("not a process of"));
        assert!(elsewhere[0].node_memory.is_none());
    }

    #[test]
    fn missing_heap_and_relay_failures_are_notes() {
        let mut processes = vec![process("ditto-hostd.scope", 42)];
        let no_heap = serde_json::json!({"result": {"host": {"state": "starting", "process": {"pid": 42}, "heap": null}}});
        assert!(
            attach_node_memory(&mut processes, "ditto-hostd.scope", Ok(no_heap))[0]
                .contains("not reported its heap")
        );
        let no_process = serde_json::json!({"result": {"host": {"state": "rescue_mode"}}});
        assert!(
            attach_node_memory(&mut processes, "ditto-hostd.scope", Ok(no_process))[0]
                .contains("rescue_mode")
        );
        let refused = serde_json::json!({"error": {"code": "unauthorized"}});
        assert!(
            attach_node_memory(&mut processes, "ditto-hostd.scope", Ok(refused))[0]
                .contains("refused")
        );
        assert_eq!(
            attach_node_memory(
                &mut processes,
                "ditto-hostd.scope",
                Err("relay: gone".into())
            ),
            vec!["relay: gone".to_string()]
        );
        assert!(processes[0].node_memory.is_none());
    }

    #[test]
    fn g0_samples_serialize_without_g1_fields() {
        let sample = Sample {
            run_id: "r".into(),
            ts: "t".into(),
            state: "desktop_full_no_agent_g0_subset".into(),
            fingerprint: BTreeMap::new(),
            processes: vec![],
            excluded: vec![],
            gpu: GpuStatus {
                available: false,
                reason: "none".into(),
            },
            errors: vec![],
            login_id: None,
            node_memory_errors: vec![],
        };
        let text = serde_json::to_string(&sample).unwrap();
        assert!(!text.contains("login_id") && !text.contains("node_memory_errors"));
    }
}
