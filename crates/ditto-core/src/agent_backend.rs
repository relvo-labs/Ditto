//! The Agent's model backend: one pinned Codex app-server, started by Core
//! inside `ditto-confine` (D-09a, G2-PLAT-04). Core alone decides the binary,
//! its arguments and its OS boundary, and only Core's own launch result can
//! mark the backend isolated; the controller merely receives one end of a
//! private stdio channel. Account tokens stay in the Secret Service through
//! Codex's keyring store; Core never reads them.
use crate::launcher::{self, Quota};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Read},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::{
            fs::{OpenOptionsExt, PermissionsExt},
            net::UnixStream,
            process::CommandExt,
        },
    },
    path::{Path, PathBuf},
    process::{Child, Stdio},
    sync::Mutex,
    time::{Duration, Instant},
};

/// `codex-app-server <version> <sha256> <executable>`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendSpecification {
    pub version: String,
    pub sha256: String,
    pub executable: PathBuf,
    /// Development and test only: a loopback Responses endpoint in place of
    /// the subscription. `main` accepts it only with the fixture compositor.
    pub test_provider: Option<TestProvider>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TestProvider {
    pub base_url: String,
    pub port: u16,
}

pub const PROVIDER_ID: &str = "codex-app-server";
/// The only Codex release whose app-server protocol was inspected (plan/04 §10).
pub const SUPPORTED_VERSION: &str = "0.160.0";

pub fn parse(specification: &str) -> io::Result<BackendSpecification> {
    let fields: Vec<&str> = specification.split_whitespace().collect();
    let [kind, version, sha256, executable] = fields.as_slice() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "backend specification needs: codex-app-server <version> <sha256> <executable>",
        ));
    };
    if *kind != PROVIDER_ID
        || *version != SUPPORTED_VERSION
        || sha256.len() != 64
        || !sha256
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "only the pinned codex-app-server 0.160.0 with a lowercase sha256 is supported",
        ));
    }
    Ok(BackendSpecification {
        version: (*version).into(),
        sha256: (*sha256).into(),
        executable: PathBuf::from(executable),
        test_provider: None,
    })
}

pub fn parse_test_provider(url: &str) -> io::Result<TestProvider> {
    let invalid = || {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "test provider must be http://127.0.0.1:<port>/v1",
        )
    };
    let rest = url.strip_prefix("http://127.0.0.1:").ok_or_else(invalid)?;
    let port = rest.strip_suffix("/v1").ok_or_else(invalid)?;
    let port: u16 = port.parse().map_err(|_| invalid())?;
    if port == 0 {
        return Err(invalid());
    }
    Ok(TestProvider {
        base_url: url.into(),
        port,
    })
}

/// Built-in Codex capabilities that must not be reachable by the model. The
/// list was checked against the tools 0.160.0 actually sends to a model
/// (tests/g2/codex: only Ditto's dynamic tools and `request_user_input`,
/// which this version refuses outside plan mode and Ditto refuses as a
/// server request). Disabling is defence in depth: the OS boundary below
/// does not rely on it.
const DISABLED_FEATURES: &[&str] = &[
    "shell_tool",
    "unified_exec",
    "view_image",
    "multi_agent",
    "multi_agent_v2",
    "goals",
    "apps",
    "plugins",
    "remote_plugin",
    "plugin_sharing",
    "hooks",
    "browser_use",
    "browser_use_external",
    "computer_use",
    "image_generation",
    "tool_suggest",
    "skill_search",
    "skill_mcp_dependency_install",
    "in_app_browser",
    "shell_snapshot",
    "code_mode_host",
    "realtime_conversation",
    "daemon_auto_start",
    "workspace_dependencies",
    "worktrees",
    "sleep_tool",
    "memories",
    "tool_call_mcp_elicitation",
];

/// Per-model fields of the pinned release's built-in model catalog that would
/// turn on tool surfaces Ditto does not allow: `tool_mode: code_mode_only`
/// nests every tool inside a JavaScript `exec` cell, `multi_agent_version`
/// adds the sub-agent `collaboration` namespace, and the patch, search and
/// experimental tool types add built-ins. Feature flags do not remove these
/// (checked against 0.160.0 with a loopback model: tests/g2/codex).
const STRIPPED_MODEL_FIELDS: &[&str] = &[
    "tool_mode",
    "multi_agent_version",
    "multi_agent_reasoning_effort",
    "apply_patch_tool_type",
    "web_search_tool_type",
];

/// Derive Ditto's model catalog from the pinned binary's own embedded one,
/// keeping every model, instruction and limit, minus the fields above.
pub fn derive_catalog(binary: &[u8]) -> Option<serde_json::Value> {
    let slug = find(binary, b"\"slug\": \"")?;
    let models = memchr::memmem::rfind(&binary[..slug], b"\"models\"")?;
    let start = binary[..models].iter().rposition(|b| *b == b'{')?;
    let mut stream =
        serde_json::Deserializer::from_slice(&binary[start..]).into_iter::<serde_json::Value>();
    let mut catalog = stream.next()?.ok()?;
    let list = catalog.get_mut("models")?.as_array_mut()?;
    if list.is_empty() {
        return None;
    }
    for model in list.iter_mut() {
        let model = model.as_object_mut()?;
        model.get("slug")?.as_str()?;
        for field in STRIPPED_MODEL_FIELDS {
            model.remove(*field);
        }
        model.insert("experimental_supported_tools".into(), serde_json::json!([]));
    }
    Some(catalog)
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    memchr::memmem::find(haystack, needle)
}

/// The derived catalog for this binary, written once per pinned hash.
fn catalog_file(
    specification: &BackendSpecification,
    executable: &Path,
    state_root: &Path,
) -> Result<PathBuf, Refusal> {
    let path = state_root.join(format!(
        "codex-catalog-{}.json",
        &specification.sha256[..16]
    ));
    if path.is_file() {
        return Ok(path);
    }
    let binary = fs::read(executable).map_err(|_| Refusal::CatalogUnavailable)?;
    let catalog = derive_catalog(&binary).ok_or(Refusal::CatalogUnavailable)?;
    let temporary = path.with_extension("tmp");
    fs::write(
        &temporary,
        serde_json::to_vec(&catalog).map_err(|_| Refusal::CatalogUnavailable)?,
    )
    .and_then(|_| fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600)))
    .and_then(|_| fs::rename(&temporary, &path))
    .map_err(|_| Refusal::CatalogUnavailable)?;
    Ok(path)
}

/// The fixed app-server argument list. Nothing here comes from a caller.
pub fn arguments(test: Option<&TestProvider>, catalog: &Path) -> Vec<String> {
    let mut args: Vec<String> = ["app-server", "--listen", "stdio://", "--strict-config"]
        .into_iter()
        .map(String::from)
        .collect();
    for feature in DISABLED_FEATURES {
        args.push("--disable".into());
        args.push((*feature).into());
    }
    for config in [
        // Never fall back to a plaintext credential file.
        "cli_auth_credentials_store=\"keyring\"",
        "web_search=\"disabled\"",
        "history.persistence=\"none\"",
        "analytics.enabled=false",
        "check_for_update_on_startup=false",
    ] {
        args.push("-c".into());
        args.push(config.into());
    }
    args.push("-c".into());
    args.push(format!(
        "model_catalog_json={:?}",
        catalog.to_string_lossy()
    ));
    if let Some(test) = test {
        args.push("-c".into());
        args.push(format!(
            "model_providers.ditto_test={{name=\"ditto-test\",base_url=\"{}\",wire_api=\"responses\",env_key=\"DITTO_TEST_PROVIDER_KEY\"}}",
            test.base_url
        ));
        args.push("-c".into());
        args.push("model_provider=\"ditto_test\"".into());
    }
    args
}

pub struct Launched {
    /// `ditto-confine`, the supervisor. Killing it kills the program's group.
    pub supervisor: Child,
    /// The confined app-server itself.
    pub program_pid: u32,
    /// The controller's end of the private stdio channel.
    pub channel: OwnedFd,
    pub session_bus_proxy: bool,
    /// Private state of this generation, cleared when it stops.
    pub root: PathBuf,
}

/// Why the backend could not start, as a closed vocabulary for diagnostics.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    BinaryMismatch,
    CatalogUnavailable,
    IsolationUnavailable,
    LaunchFailed,
}
impl Refusal {
    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::BinaryMismatch => "backend_binary_mismatch",
            Refusal::CatalogUnavailable => "backend_catalog_unavailable",
            Refusal::IsolationUnavailable => "isolation_unavailable",
            Refusal::LaunchFailed => "backend_launch_failed",
        }
    }
}

/// (canonical path, size, mtime) of the last binary whose hash matched.
static VERIFIED: Mutex<Option<(PathBuf, u64, i64)>> = Mutex::new(None);

fn verify_binary(specification: &BackendSpecification) -> Result<PathBuf, Refusal> {
    use std::os::unix::fs::MetadataExt;
    let path = specification
        .executable
        .canonicalize()
        .map_err(|_| Refusal::BinaryMismatch)?;
    let metadata = fs::metadata(&path).map_err(|_| Refusal::BinaryMismatch)?;
    let key = (path.clone(), metadata.size(), metadata.mtime());
    if VERIFIED.lock().expect("verified binary").as_ref() == Some(&key) {
        return Ok(path);
    }
    let mut file = fs::File::open(&path).map_err(|_| Refusal::BinaryMismatch)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let n = file
            .read(&mut buffer)
            .map_err(|_| Refusal::BinaryMismatch)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    let digest: String = hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    if digest != specification.sha256 {
        return Err(Refusal::BinaryMismatch);
    }
    *VERIFIED.lock().expect("verified binary") = Some(key);
    Ok(path)
}

/// Empty a private directory without following symlinks out of it.
fn reset_directory(path: &Path) -> io::Result<()> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if !metadata.is_dir() {
            fs::remove_file(path)?;
        } else {
            fs::remove_dir_all(path)?;
        }
    }
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

/// The filtering session-bus proxy: the pinned build installed next to Core
/// (tools/dbus-proxy), else a distribution one that is new enough. Releases
/// before 0.1.6 drop sd-bus and zbus clients (Codex's keyring store) after
/// authentication, which would look like a locked keyring.
fn session_bus_proxy() -> Option<PathBuf> {
    let adjacent = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join("ditto-dbus-proxy")));
    adjacent
        .into_iter()
        .chain([PathBuf::from("/usr/bin/xdg-dbus-proxy")])
        .find(|candidate| {
            candidate.is_file()
                && std::process::Command::new(candidate)
                    .arg("--version")
                    .output()
                    .ok()
                    .and_then(|o| String::from_utf8(o.stdout).ok())
                    .and_then(|text| proxy_version_supported(&text))
                    .unwrap_or(false)
        })
}

fn proxy_version_supported(text: &str) -> Option<bool> {
    let version = text.trim().strip_prefix("xdg-dbus-proxy ")?;
    let parts: Vec<u32> = version
        .split('.')
        .map(|p| p.parse().ok())
        .collect::<Option<_>>()?;
    Some(parts >= vec![0, 1, 6])
}

/// Empty the backend's private directories after its processes are gone.
pub fn clear(root: &Path) {
    for name in ["home", "codex", "work"] {
        let _ = reset_directory(&root.join(name));
    }
    let _ = fs::remove_file(root.join("bus"));
}

pub fn launch(
    specification: &BackendSpecification,
    state_root: &Path,
    quota: Option<&Quota>,
) -> Result<Launched, Refusal> {
    let executable = verify_binary(specification)?;
    let confine = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join("ditto-confine")))
        .filter(|path| path.is_file())
        .ok_or(Refusal::IsolationUnavailable)?;
    let root = state_root.join("backend");
    fs::create_dir_all(&root).map_err(|_| Refusal::LaunchFailed)?;
    fs::set_permissions(state_root, fs::Permissions::from_mode(0o700))
        .map_err(|_| Refusal::LaunchFailed)?;
    // Without the derived catalog the backend would run with code mode and
    // sub-agents on: refuse rather than start it.
    let catalog = catalog_file(specification, &executable, state_root)?;
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
        .map_err(|_| Refusal::LaunchFailed)?;
    let (home, codex, work) = (root.join("home"), root.join("codex"), root.join("work"));
    // The app-server keeps logs and thread state in CODEX_HOME. Ditto's Core
    // is the conversation authority, so every start begins empty. The account
    // itself lives in the keyring, keyed by this unchanged CODEX_HOME path.
    for directory in [&home, &codex, &work] {
        reset_directory(directory).map_err(|_| Refusal::LaunchFailed)?;
    }
    let bus = root.join("bus");
    let _ = fs::remove_file(&bus);
    let mut policy: Vec<String> = vec!["--status-fd".into(), "3".into()];
    let mut read = |path: &str| {
        if Path::new(path).exists() {
            policy.push("--read".into());
            policy.push(path.into());
        }
    };
    read("/etc/ssl");
    read("/etc/ca-certificates");
    read("/usr/share/ca-certificates");
    read("/etc/resolv.conf");
    read("/run/systemd/resolve");
    read("/etc/hosts");
    read("/dev/urandom");
    policy.push("--read".into());
    policy.push(catalog.to_string_lossy().into_owned());
    let executable_dir = executable.parent().ok_or(Refusal::LaunchFailed)?;
    policy.extend([
        "--read".into(),
        executable_dir.to_string_lossy().into_owned(),
        "--write".into(),
        "/dev/null".into(),
        "--write".into(),
        root.to_string_lossy().into_owned(),
        // HTTPS to the provider and DNS. Sign-in is by device code, so the
        // backend listens on nothing (no browser callback port).
        "--tcp".into(),
        "443".into(),
        "--udp-dns".into(),
        "--cwd".into(),
        work.to_string_lossy().into_owned(),
    ]);
    let mut environment = vec![
        format!("HOME={}", home.display()),
        format!("CODEX_HOME={}", codex.display()),
        format!("TMPDIR={}", home.display()),
        "PATH=/usr/bin:/bin".to_string(),
        "LANG=C.UTF-8".to_string(),
    ];
    let proxy = session_bus_proxy();
    let session_bus = std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some() && proxy.is_some();
    if let (true, Some(proxy)) = (session_bus, proxy) {
        // The program's only session-bus endpoint: Secret Service, nothing
        // else. Without it the keyring store fails closed (no file fallback).
        policy.extend([
            "--dbus-proxy".into(),
            proxy.to_string_lossy().into_owned(),
            bus.to_string_lossy().into_owned(),
        ]);
        environment.push(format!(
            "DBUS_SESSION_BUS_ADDRESS=unix:path={}",
            bus.display()
        ));
    }
    if let Some(test) = &specification.test_provider {
        policy.extend(["--tcp-loopback".into(), test.port.to_string()]);
        environment.push("DITTO_TEST_PROVIDER_KEY=ditto-test".into());
    }
    for entry in environment {
        policy.push("--env".into());
        policy.push(entry);
    }
    policy.push("--".into());
    policy.push(executable.to_string_lossy().into_owned());
    policy.extend(arguments(specification.test_provider.as_ref(), &catalog));

    let (controller, program) = UnixStream::pair().map_err(|_| Refusal::LaunchFailed)?;
    let mut fds = [0; 2];
    // SAFETY: pipe2 fills two new descriptors.
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(Refusal::LaunchFailed);
    }
    // SAFETY: both descriptors were just created and are owned here.
    let (status_read, status_write) =
        unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    let stderr = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(root.join("backend.log"))
        .map_err(|_| Refusal::LaunchFailed)?;
    let mut command = launcher::scoped_command("agent-backend", &confine, quota)
        .map_err(|_| Refusal::LaunchFailed)?;
    let program_fd: OwnedFd = program.into();
    let stdin = program_fd.try_clone().map_err(|_| Refusal::LaunchFailed)?;
    command
        .args(&policy)
        .stdin(Stdio::from(stdin))
        .stdout(Stdio::from(program_fd))
        .stderr(Stdio::from(stderr))
        .env_remove("DITTO_DEV_TOKEN")
        .env_remove("NOTIFY_SOCKET")
        .env_remove("WATCHDOG_PID")
        .env_remove("WATCHDOG_USEC")
        .env_remove("DITTO_LAUNCH_SCOPE_PREFIX");
    let raw = status_write.as_raw_fd();
    // SAFETY: dup2 is async-signal-safe.
    unsafe {
        command.pre_exec(move || {
            if libc::dup2(raw, 3) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut supervisor = command.spawn().map_err(|_| Refusal::LaunchFailed)?;
    drop(status_write);
    let status = read_status(&status_read, Duration::from_secs(5));
    let refuse = |mut supervisor: Child, reason: Refusal| {
        let _ = supervisor.kill();
        let _ = supervisor.wait();
        Err(reason)
    };
    let Some(status) = status else {
        return refuse(supervisor, Refusal::IsolationUnavailable);
    };
    let value: serde_json::Value = match serde_json::from_str(&status) {
        Ok(value) => value,
        Err(_) => return refuse(supervisor, Refusal::IsolationUnavailable),
    };
    let program_pid = value["pid"].as_u64().and_then(|p| u32::try_from(p).ok());
    let confined = value["confined"] == true && value["seccomp"] == "connect-broker";
    let Some(program_pid) =
        program_pid.filter(|pid| confined && parent_of(*pid) == Some(supervisor.id()))
    else {
        return refuse(supervisor, Refusal::IsolationUnavailable);
    };
    if let Ok(Some(_)) = supervisor.try_wait() {
        return Err(Refusal::LaunchFailed);
    }
    Ok(Launched {
        supervisor,
        program_pid,
        channel: controller.into(),
        session_bus_proxy: value["session_bus_proxy"] == true,
        root,
    })
}

fn read_status(fd: &OwnedFd, timeout: Duration) -> Option<String> {
    let deadline = Instant::now() + timeout;
    let mut text = Vec::new();
    while !text.contains(&b'\n') && text.len() < 4096 {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return None;
        }
        let mut poll = libc::pollfd {
            fd: fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one valid pollfd.
        if unsafe { libc::poll(&mut poll, 1, remaining.as_millis() as i32) } <= 0 {
            return None;
        }
        let mut buffer = [0u8; 512];
        // SAFETY: buffer is valid for its length.
        let n = unsafe { libc::read(fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
        if n <= 0 {
            break;
        }
        text.extend_from_slice(&buffer[..n as usize]);
    }
    let line = text.split(|b| *b == b'\n').next()?;
    String::from_utf8(line.to_vec()).ok()
}

fn parent_of(pid: u32) -> Option<u32> {
    let text = fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    text.lines()
        .find_map(|l| l.strip_prefix("PPid:"))
        .and_then(|p| p.trim().parse().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn specification_accepts_only_the_pinned_release() {
        let sha = "a".repeat(64);
        assert!(parse(&format!("codex-app-server 0.160.0 {sha} /x/codex")).is_ok());
        assert!(parse(&format!("codex-app-server 0.161.0 {sha} /x/codex")).is_err());
        assert!(parse(&format!("other 0.160.0 {sha} /x/codex")).is_err());
        assert!(parse(&format!(
            "codex-app-server 0.160.0 {} /x/codex",
            "A".repeat(64)
        ))
        .is_err());
        assert!(parse("codex-app-server 0.160.0 short /x/codex").is_err());
    }

    #[test]
    fn test_provider_must_be_loopback_http() {
        assert_eq!(
            parse_test_provider("http://127.0.0.1:8080/v1")
                .unwrap()
                .port,
            8080
        );
        for bad in [
            "https://127.0.0.1:8080/v1",
            "http://localhost:8080/v1",
            "http://127.0.0.1:0/v1",
            "http://127.0.0.1:8080/v2",
            "http://10.0.0.1:8080/v1",
        ] {
            assert!(parse_test_provider(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn catalog_is_derived_without_forbidden_tool_modes() {
        let binary = br#"junk\0{"models": [{"slug": "a", "tool_mode": "code_mode_only", "multi_agent_version": "v2", "apply_patch_tool_type": "freeform", "experimental_supported_tools": ["clock"], "context_window": 5}, {"slug": "b"}]}\0more"#;
        let catalog = derive_catalog(binary).unwrap();
        let first = &catalog["models"][0];
        assert_eq!(first["slug"], "a");
        assert_eq!(first["context_window"], 5);
        assert!(first.get("tool_mode").is_none() && first.get("multi_agent_version").is_none());
        assert!(first.get("apply_patch_tool_type").is_none());
        assert_eq!(first["experimental_supported_tools"], serde_json::json!([]));
        assert_eq!(catalog["models"][1]["slug"], "b");
        assert!(derive_catalog(b"no catalog here").is_none());
        assert!(derive_catalog(br#"{"models": []} "slug": ""#).is_none());
    }

    #[test]
    fn old_session_bus_proxies_are_refused() {
        assert_eq!(
            proxy_version_supported("xdg-dbus-proxy 0.1.5\n"),
            Some(false)
        );
        assert_eq!(
            proxy_version_supported("xdg-dbus-proxy 0.1.9\n"),
            Some(true)
        );
        assert_eq!(proxy_version_supported("xdg-dbus-proxy 0.2.0"), Some(true));
        assert_eq!(proxy_version_supported("something else"), None);
    }

    #[test]
    fn arguments_disable_builtins_and_force_keyring() {
        let catalog = Path::new("/state/catalog.json");
        let args = arguments(None, catalog);
        assert!(args
            .iter()
            .any(|a| a == "model_catalog_json=\"/state/catalog.json\""));
        assert!(args.windows(2).any(|w| w == ["--disable", "shell_tool"]));
        assert!(args.windows(2).any(|w| w == ["--disable", "unified_exec"]));
        assert!(args
            .iter()
            .any(|a| a == "cli_auth_credentials_store=\"keyring\""));
        assert!(args.iter().any(|a| a == "--strict-config"));
        assert!(!args.iter().any(|a| a.contains("ditto_test")));
        assert!(arguments(
            Some(&parse_test_provider("http://127.0.0.1:9/v1").unwrap()),
            catalog
        )
        .iter()
        .any(|a| a == "model_provider=\"ditto_test\""));
    }
}
