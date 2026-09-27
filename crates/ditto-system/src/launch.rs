//! Application launch: `systemd-run --user --scope` in a double fork, so the
//! application is neither a child of Core nor inside Core's cgroup. A Core,
//! Shell or hostd restart therefore never takes an application with it
//! (DES-09), and the scope name tells a resource report which app it is.

use std::ffi::OsString;
use std::io::{self, Read};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::desktop_entry::{self, ExecContext, ExecError, Locale};
use crate::index::Indexed;
use crate::{SystemError, SystemResult};

/// Variables that belong to Core's own service and must not reach an app:
/// an inherited `NOTIFY_SOCKET` would let any app send `WATCHDOG=1` for Core.
const SCRUBBED: &[&str] = &[
    "NOTIFY_SOCKET",
    "WATCHDOG_PID",
    "WATCHDOG_USEC",
    "LISTEN_FDS",
    "LISTEN_PID",
    "LISTEN_FDNAMES",
    "INVOCATION_ID",
    "JOURNAL_STREAM",
    "MANAGERPID",
    "SYSTEMD_EXEC_PID",
];

/// Per-launch extras the contract does not carry yet.
#[derive(Clone, Debug, Default)]
pub struct LaunchOptions {
    /// `xdg_activation_v1` token from the requesting surface (C-09). The app
    /// reads it from `XDG_ACTIVATION_TOKEN` and activates its first window.
    pub activation_token: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchPlan {
    /// Without `.scope`; `systemd-run --unit` takes the bare name.
    pub unit: String,
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub set_env: Vec<(String, String)>,
    pub remove_env: Vec<String>,
    pub working_dir: Option<PathBuf>,
}

/// systemd unit names allow `[A-Za-z0-9:_.\\-]`; `-` separates the fields
/// of `app-ditto-<app>-<random>`, so it is replaced inside the app id too.
pub fn sanitize_unit_part(app_id: &str) -> String {
    let cleaned: String = app_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .take(100)
        .collect();
    if cleaned.is_empty() {
        "app".into()
    } else {
        cleaned
    }
}

pub fn random_suffix() -> String {
    let mut bytes = [0u8; 4];
    // SAFETY: the buffer is valid for its length; flags 0 blocks only until
    // the kernel pool is initialized, which is long past at login.
    let read = unsafe { libc::getrandom(bytes.as_mut_ptr().cast(), bytes.len(), 0) };
    if read != bytes.len() as isize {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or_default();
        bytes = (nanos ^ std::process::id()).to_le_bytes();
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub struct PlanInput<'a> {
    pub app: &'a Indexed,
    pub target: Option<&'a str>,
    pub locale: &'a Locale,
    pub systemd_run: &'a Path,
    pub terminal: &'a [String],
    pub suffix: &'a str,
    pub options: &'a LaunchOptions,
}

pub fn plan(input: &PlanInput<'_>) -> SystemResult<LaunchPlan> {
    let entry = &input.app.entry;
    let exec = entry
        .exec
        .as_deref()
        .ok_or_else(|| SystemError::Invalid(format!("{} has no Exec line", input.app.app_id)))?;
    let context = ExecContext {
        target: input.target,
        icon: entry.icon.as_deref(),
        translated_name: entry.name.get(input.locale),
        desktop_file: Some(&input.app.path),
    };
    let mut command = desktop_entry::expand_exec(exec, &context).map_err(|error| match error {
        ExecError::NonLocalFile(uri) => SystemError::Invalid(format!(
            "{} opens local files only, not {uri}",
            input.app.app_id
        )),
        other => SystemError::Invalid(format!(
            "{}: Exec line is not usable ({other:?})",
            input.app.app_id
        )),
    })?;
    if entry.terminal {
        if input.terminal.is_empty() {
            return Err(SystemError::Unavailable(
                "no terminal configured for Terminal=true entries".into(),
            ));
        }
        let mut wrapped = input.terminal.to_vec();
        wrapped.append(&mut command);
        command = wrapped;
    }
    let unit = format!(
        "app-ditto-{}-{}",
        sanitize_unit_part(&input.app.app_id),
        input.suffix
    );
    let mut args: Vec<OsString> = ["--user", "--scope", "--quiet", "--collect"]
        .map(OsString::from)
        .into();
    args.push(format!("--unit={unit}").into());
    // The scope's description is what `systemctl --user status` shows.
    args.push(format!("--description={}", entry.name.default).into());
    args.push("--".into());
    args.extend(command.into_iter().map(OsString::from));
    let mut set_env = Vec::new();
    if let Some(token) = &input.options.activation_token {
        set_env.push(("XDG_ACTIVATION_TOKEN".into(), token.clone()));
    }
    let mut remove_env: Vec<String> = SCRUBBED.iter().map(|s| s.to_string()).collect();
    remove_env.extend(
        std::env::vars_os()
            .filter_map(|(key, _)| key.into_string().ok())
            .filter(|key| key.starts_with("DITTO_")),
    );
    if input.options.activation_token.is_none() {
        // A token Core itself received must not be replayed onto an app.
        remove_env.push("XDG_ACTIVATION_TOKEN".into());
    }
    Ok(LaunchPlan {
        unit,
        program: input.systemd_run.to_path_buf(),
        args,
        set_env,
        remove_env,
        working_dir: entry
            .working_dir
            .as_deref()
            .map(PathBuf::from)
            .filter(|p| p.is_dir()),
    })
}

/// Start `plan` as a grandchild in a new session and return its PID. The
/// intermediate child forks, reports the grandchild PID on a pipe and exits,
/// so Core reaps it at once and the grandchild is reparented to the nearest
/// subreaper (the systemd user manager under `ditto-core.service`). Because
/// the grandchild inherits the standard library's exec-status pipe, a failed
/// `exec` still reaches `spawn()` as an error.
pub fn spawn_detached(plan: &LaunchPlan) -> io::Result<u32> {
    let mut command = Command::new(&plan.program);
    command.args(&plan.args).stdin(Stdio::null());
    for key in &plan.remove_env {
        command.env_remove(key);
    }
    for (key, value) in &plan.set_env {
        command.env(key, value);
    }
    if let Some(dir) = &plan.working_dir {
        command.current_dir(dir);
    }
    let mut fds = [0; 2];
    // SAFETY: `fds` has room for the two descriptors pipe2 writes.
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let (read_fd, write_fd) = (fds[0], fds[1]);
    // SAFETY: only async-signal-safe calls (fork, setsid, write, _exit, close)
    // run between fork and exec.
    unsafe {
        command.pre_exec(move || match libc::fork() {
            -1 => Err(io::Error::last_os_error()),
            0 => {
                libc::close(write_fd);
                libc::close(read_fd);
                libc::setsid();
                Ok(())
            }
            grandchild => {
                let bytes = (grandchild as u32).to_ne_bytes();
                libc::write(write_fd, bytes.as_ptr().cast(), bytes.len());
                libc::_exit(0);
            }
        });
    }
    let spawned = command.spawn();
    // SAFETY: the write end is ours; closing it lets the read below see EOF.
    unsafe { libc::close(write_fd) };
    // SAFETY: read_fd is an open descriptor that nothing else owns.
    let mut reader = unsafe { <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(read_fd) };
    let mut child = spawned?;
    let _ = child.wait();
    let mut bytes = [0u8; 4];
    reader.read_exact(&mut bytes).map_err(|_| {
        io::Error::other("the launch helper exited before reporting the application PID")
    })?;
    Ok(u32::from_ne_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop_entry;

    fn indexed(body: &str) -> Indexed {
        let entry =
            desktop_entry::parse(&format!("[Desktop Entry]\nType=Application\n{body}")).unwrap();
        Indexed {
            app_id: "org.kde.kate".into(),
            path: "/usr/share/applications/org.kde.kate.desktop".into(),
            entry,
            listed: true,
        }
    }

    fn build(
        app: &Indexed,
        target: Option<&str>,
        options: &LaunchOptions,
    ) -> SystemResult<LaunchPlan> {
        plan(&PlanInput {
            app,
            target,
            locale: &Locale::default(),
            systemd_run: Path::new("/usr/bin/systemd-run"),
            terminal: &["foot".into()],
            suffix: "0a1b2c3d",
            options,
        })
    }

    fn strings(args: &[OsString]) -> Vec<String> {
        args.iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn builds_a_systemd_run_scope_command() {
        let app = indexed("Name=Kate\nExec=kate -b %U\n");
        let plan = build(&app, Some("/tmp/a b.txt"), &LaunchOptions::default()).unwrap();
        assert_eq!(plan.unit, "app-ditto-org.kde.kate-0a1b2c3d");
        assert_eq!(plan.program, Path::new("/usr/bin/systemd-run"));
        assert_eq!(
            strings(&plan.args),
            [
                "--user",
                "--scope",
                "--quiet",
                "--collect",
                "--unit=app-ditto-org.kde.kate-0a1b2c3d",
                "--description=Kate",
                "--",
                "kate",
                "-b",
                "file:///tmp/a%20b.txt",
            ]
        );
        assert!(plan.remove_env.contains(&"NOTIFY_SOCKET".to_string()));
        assert!(plan
            .remove_env
            .contains(&"XDG_ACTIVATION_TOKEN".to_string()));
        assert!(plan.set_env.is_empty());
    }

    #[test]
    fn passes_an_activation_token_through() {
        let app = indexed("Name=Kate\nExec=kate\n");
        let options = LaunchOptions {
            activation_token: Some("token-1".into()),
        };
        let plan = build(&app, None, &options).unwrap();
        assert_eq!(
            plan.set_env,
            [("XDG_ACTIVATION_TOKEN".to_string(), "token-1".to_string())]
        );
        assert!(!plan
            .remove_env
            .contains(&"XDG_ACTIVATION_TOKEN".to_string()));
    }

    #[test]
    fn terminal_entries_are_wrapped_and_bad_exec_refused() {
        let app = indexed("Name=Htop\nExec=htop\nTerminal=true\n");
        let plan = build(&app, None, &LaunchOptions::default()).unwrap();
        assert_eq!(strings(&plan.args[7..]), ["foot", "htop"]);
        let app = indexed("Name=Local\nExec=viewer %f\n");
        assert!(matches!(
            build(&app, Some("https://example.org"), &LaunchOptions::default()),
            Err(SystemError::Invalid(_))
        ));
        let app = indexed("Name=Broken\nExec=\"unterminated\n");
        assert!(matches!(
            build(&app, None, &LaunchOptions::default()),
            Err(SystemError::Invalid(_))
        ));
    }

    #[test]
    fn unit_names_are_sanitized() {
        assert_eq!(sanitize_unit_part("google-chrome"), "google_chrome");
        assert_eq!(sanitize_unit_part("firefox_firefox"), "firefox_firefox");
        assert_eq!(sanitize_unit_part("編輯器"), "___");
        assert_eq!(sanitize_unit_part(""), "app");
        assert_eq!(random_suffix().len(), 8);
        assert_ne!(random_suffix(), random_suffix());
    }

    fn parent_of(pid: u32) -> Option<u32> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        // Field 4 follows the parenthesized command name, which may hold spaces.
        stat.rsplit_once(')')?
            .1
            .split_whitespace()
            .nth(1)?
            .parse()
            .ok()
    }

    #[test]
    fn detached_process_is_not_our_child() {
        // `sleep` stands in for systemd-run: the double fork is the same.
        let plan = LaunchPlan {
            unit: "unused".into(),
            program: "/bin/sleep".into(),
            args: vec!["5".into()],
            set_env: vec![],
            remove_env: vec![],
            working_dir: None,
        };
        let pid = spawn_detached(&plan).expect("spawn");
        let parent = parent_of(pid).expect("the process is running");
        assert_ne!(
            parent,
            std::process::id(),
            "the launched process must not be a child of the caller"
        );
        let sid = unsafe { libc::getsid(pid as libc::pid_t) };
        assert_eq!(
            sid, pid as libc::pid_t,
            "the launched process leads its own session"
        );
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    }

    #[test]
    fn exec_failure_reaches_the_caller() {
        let plan = LaunchPlan {
            unit: "unused".into(),
            program: "/nonexistent/systemd-run".into(),
            args: vec![],
            set_env: vec![],
            remove_env: vec![],
            working_dir: None,
        };
        assert!(spawn_detached(&plan).is_err());
    }
}
