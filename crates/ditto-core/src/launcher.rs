//! Controlled launcher. A client receives its one-use token on an inherited
//! descriptor, never in its environment, and the token is bound to the PID the
//! launcher spawned. A process that Core did not start has no way to present a
//! valid identity, and a copy of another client's token does not match its PID.

use std::{
    ffi::OsString,
    io::{self, Write},
    os::unix::{
        io::{AsRawFd, OwnedFd, RawFd},
        net::UnixStream,
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, Command},
    sync::Arc,
};

use crate::identity::{fresh_token, ClientIdentity, IdentityRegistry};
use ditto_protocol::{
    LAUNCHER_KIND_ENV, LAUNCHER_SOCKET_ENV, LAUNCHER_TOKEN_FD, LAUNCHER_TOKEN_FD_ENV,
    LAUNCHER_VERSION_ENV,
};

const TOKEN_FD: RawFd = LAUNCHER_TOKEN_FD;

/// `<kind> <version> <executable> [args...]`, whitespace separated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Specification {
    pub kind: String,
    pub version: String,
    pub executable: PathBuf,
    pub arguments: Vec<OsString>,
}

/// cgroup limits applied through `systemd-run --scope -p …` (D-06b). When a
/// quota is required and cannot be applied, the client is not started.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Quota {
    pub memory_max: String,
    pub cpu_quota: String,
    pub tasks_max: u32,
}

impl Quota {
    /// D-06b's short-tool class, used for the resident hostd until a service
    /// class is decided (recorded as plan feedback, not a new budget).
    pub fn service() -> Self {
        Self {
            memory_max: "256M".into(),
            cpu_quota: "50%".into(),
            tasks_max: 32,
        }
    }

    /// D-06b's build class, for package unpacking jobs.
    pub fn build() -> Self {
        Self {
            memory_max: "2G".into(),
            cpu_quota: "200%".into(),
            tasks_max: 256,
        }
    }

    pub fn properties(&self) -> Vec<String> {
        vec![
            format!("MemoryMax={}", self.memory_max),
            format!("CPUQuota={}", self.cpu_quota),
            format!("TasksMax={}", self.tasks_max),
        ]
    }
}

pub fn parse(specification: &str) -> io::Result<Specification> {
    let mut fields = specification.split_whitespace();
    let (Some(kind), Some(version), Some(executable)) =
        (fields.next(), fields.next(), fields.next())
    else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "launch specification needs kind, version and an executable path",
        ));
    };
    Ok(Specification {
        kind: kind.into(),
        version: version.into(),
        executable: PathBuf::from(executable),
        arguments: fields.map(OsString::from).collect(),
    })
}

/// With `DITTO_LAUNCH_SCOPE_PREFIX` set, the client runs in its own systemd
/// user scope `<prefix>-<kind>.scope`, so a resource sampler can attribute it
/// to its layer by cgroup. `systemd-run --scope` execs the client in place:
/// the PID bound below, the inherited token descriptor and the executable that
/// identity checks read from `/proc/<pid>/exe` are all the client's own.
fn scoped_command(kind: &str, executable: &Path, quota: Option<&Quota>) -> io::Result<Command> {
    let Some(prefix) = std::env::var_os("DITTO_LAUNCH_SCOPE_PREFIX") else {
        if quota.is_some() && std::env::var_os("DITTO_REQUIRE_QUOTA").is_some() {
            // Fail closed: a quota that cannot be applied means no start.
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "a resource quota is required but no systemd scope is available",
            ));
        }
        return Ok(Command::new(executable));
    };
    let valid = |value: &str| {
        !value.is_empty()
            && value
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    };
    let prefix = prefix.to_string_lossy().into_owned();
    if !valid(&prefix) || !valid(kind) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "launch scope names allow only ASCII letters, digits, '-' and '_'",
        ));
    }
    let unit = format!("{prefix}-{kind}");
    // A client from an earlier Core (whose token is spent) must not survive
    // next to the one started now: stop the old scope of the same name.
    // A scope whose processes were killed can stay loaded as `failed`
    // (seen after the supervisor's SIGKILL): stopping it is not enough, and
    // systemd-run then refuses the name. Reset it and wait until it is gone.
    let scope = format!("{unit}.scope");
    let _ = Command::new("/usr/bin/systemctl")
        .env_remove("NOTIFY_SOCKET")
        .args(["--user", "stop", &scope])
        .stderr(std::process::Stdio::null())
        .status();
    let _ = Command::new("/usr/bin/systemctl")
        .env_remove("NOTIFY_SOCKET")
        .args(["--user", "reset-failed", &scope])
        .stderr(std::process::Stdio::null())
        .status();
    for _ in 0..40 {
        let loaded = Command::new("/usr/bin/systemctl")
            .env_remove("NOTIFY_SOCKET")
            .args(["--user", "show", "-p", "LoadState", "--value", &scope])
            .output()
            .map(|output| String::from_utf8_lossy(&output.stdout).trim() == "loaded")
            .unwrap_or(false);
        if !loaded {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let mut command = Command::new("/usr/bin/systemd-run");
    command
        .args(["--user", "--scope", "--quiet", "--collect"])
        .arg(format!("--unit={unit}"));
    if let Some(quota) = quota {
        for property in quota.properties() {
            command.arg("-p").arg(property);
        }
    }
    command.arg("--").arg(executable);
    Ok(command)
}

/// Spawn the client, bind its PID, then hand over the token. The order matters:
/// nothing usable reaches the client before Core knows which process may use it.
pub fn launch(
    registry: &Arc<IdentityRegistry>,
    specification: &str,
    socket: &Path,
) -> io::Result<Child> {
    launch_parsed(registry, &parse(specification)?, socket, None, &[])
}

/// Launch a parsed specification with an optional quota and extra
/// environment (never secrets: the token goes over the inherited descriptor).
pub fn launch_parsed(
    registry: &Arc<IdentityRegistry>,
    parsed: &Specification,
    socket: &Path,
    quota: Option<&Quota>,
    environment: &[(String, String)],
) -> io::Result<Child> {
    let parsed = parsed.clone();
    let executable = parsed.executable.canonicalize()?;
    let (mut launcher_end, client_end) = UnixStream::pair()?;
    let client_fd: OwnedFd = client_end.into();
    let inherited = client_fd.as_raw_fd();

    let mut command = scoped_command(&parsed.kind, &executable, quota)?;
    command.envs(environment.iter().map(|(key, value)| (key, value)));
    command
        .args(&parsed.arguments)
        .env_remove("DITTO_DEV_TOKEN")
        // Core's own service-manager channel: a client that inherits it
        // would send notifications systemd refuses (only Core is MainPID).
        .env_remove("NOTIFY_SOCKET")
        .env_remove("WATCHDOG_PID")
        .env_remove("WATCHDOG_USEC")
        // Scopes are Core's to create; a Core the client itself starts (a
        // test fixture, say) must not reuse the session's scope names.
        .env_remove("DITTO_LAUNCH_SCOPE_PREFIX")
        .env(LAUNCHER_TOKEN_FD_ENV, TOKEN_FD.to_string())
        .env(LAUNCHER_SOCKET_ENV, socket)
        .env(LAUNCHER_KIND_ENV, &parsed.kind)
        .env(LAUNCHER_VERSION_ENV, &parsed.version);
    // SAFETY: dup2 is async-signal-safe and does not block, so the parent's
    // spawn() is not held up waiting for the child.
    unsafe {
        command.pre_exec(move || {
            if libc::dup2(inherited, TOKEN_FD) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = command.spawn()?;
    drop(client_fd);

    let token = fresh_token()?;
    registry.bind_issued_token(
        token.clone(),
        ClientIdentity {
            // SAFETY: getuid has no memory preconditions.
            uid: unsafe { libc::getuid() },
            pid: child.id(),
            kind: parsed.kind,
            version: parsed.version,
            executable,
        },
    )?;
    launcher_end.write_all(format!("{token}\n").as_bytes())?;
    Ok(child)
}
