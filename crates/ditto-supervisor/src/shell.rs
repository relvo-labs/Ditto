//! The Shell side: the ping over `shell.sock`, finding the Shell's
//! processes, killing them, and the rescue request file.

use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::monitor::{Outcome, Pinger};

/// One connection kept across pings: a new connection every two seconds makes
/// Quickshell log a `PeerClosedError` warning for each. After any miss the
/// connection is dropped and the next ping reconnects, so a Shell restart or
/// a half-read reply cannot carry over.
pub struct SocketPinger {
    pub path: PathBuf,
    stream: Option<UnixStream>,
    received: Vec<u8>,
}

impl SocketPinger {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            stream: None,
            received: Vec::new(),
        }
    }
}

/// Non-blocking connect: a stopped Shell stops accepting, and once its
/// listen backlog is full a blocking connect would hang the supervisor.
fn connect(path: &Path) -> io::Result<UnixStream> {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: zeroed sockaddr_un is valid; the path is length-checked below.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= address.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket path too long",
        ));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (slot, byte) in address.sun_path.iter_mut().zip(bytes) {
        *slot = *byte as libc::c_char;
    }
    // SAFETY: plain socket syscalls on a descriptor this function owns.
    unsafe {
        let fd = libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        );
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let owned = OwnedFd::from_raw_fd(fd);
        let length = std::mem::size_of::<libc::sa_family_t>() + bytes.len() + 1;
        if libc::connect(
            fd,
            (&address as *const libc::sockaddr_un).cast(),
            length as libc::socklen_t,
        ) != 0
        {
            return Err(io::Error::last_os_error());
        }
        let stream = UnixStream::from(owned);
        stream.set_nonblocking(false)?;
        Ok(stream)
    }
}

impl Pinger for SocketPinger {
    fn ping(&mut self, sequence: u64, timeout: Duration) -> Outcome {
        let outcome = self.exchange(sequence, timeout);
        if outcome != Outcome::Pong {
            self.stream = None;
            self.received.clear();
        }
        outcome
    }
}

impl SocketPinger {
    fn exchange(&mut self, sequence: u64, timeout: Duration) -> Outcome {
        let deadline = Instant::now() + timeout;
        if self.stream.is_none() {
            match connect(&self.path) {
                Ok(stream) => self.stream = Some(stream),
                Err(error) => {
                    return match error.raw_os_error() {
                        Some(libc::ENOENT | libc::ECONNREFUSED | libc::ENOTDIR) => Outcome::Absent,
                        Some(libc::EAGAIN) => Outcome::NoReply("listen backlog full".into()),
                        _ => Outcome::NoReply(format!("connect: {error}")),
                    };
                }
            }
        }
        let stream = self.stream.as_mut().expect("connected above");
        let remaining = || {
            deadline
                .saturating_duration_since(Instant::now())
                .max(Duration::from_millis(1))
        };
        let _ = stream.set_write_timeout(Some(remaining()));
        if let Err(error) = stream.write_all(format!("ping {sequence}\n").as_bytes()) {
            // The Shell exited since the last ping: its end is gone.
            if error.kind() == io::ErrorKind::BrokenPipe {
                return match connect(&self.path) {
                    Err(_) => Outcome::Absent,
                    Ok(_) => Outcome::NoReply("connection reset".into()),
                };
            }
            return Outcome::NoReply(format!("write: {error}"));
        }
        let expected = format!("pong {sequence}");
        let mut buffer = [0u8; 128];
        loop {
            if Instant::now() >= deadline {
                return Outcome::NoReply("timeout".into());
            }
            let _ = stream.set_read_timeout(Some(remaining()));
            match stream.read(&mut buffer) {
                Ok(0) => return Outcome::NoReply("closed without reply".into()),
                Ok(read) => {
                    self.received.extend_from_slice(&buffer[..read]);
                    // Other lines (a late pong, a future broadcast) are skipped.
                    while let Some(end) = self.received.iter().position(|b| *b == b'\n') {
                        let line: Vec<u8> = self.received.drain(..=end).collect();
                        if String::from_utf8_lossy(&line).trim_end() == expected {
                            return Outcome::Pong;
                        }
                    }
                    if self.received.len() > 4096 {
                        return Outcome::NoReply("reply too long".into());
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
                {
                    return Outcome::NoReply("timeout".into());
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Outcome::NoReply(format!("read: {error}")),
            }
        }
    }
}

pub struct Locator {
    /// Where the user manager's cgroup tree starts.
    pub cgroup_root: PathBuf,
    /// Scope names to look for, first match wins. Core's launcher names the
    /// Shell scope `<prefix>-<kind>.scope`, so `ditto-quickshell.scope` is the
    /// name while the Shell's launch kind is `quickshell`.
    pub scopes: Vec<String>,
    /// `<pid>\n` or `<pid> <starttime>\n`, written by Core.
    pub pid_file: PathBuf,
}

impl Locator {
    pub fn for_user(pid_file: PathBuf) -> Self {
        // SAFETY: getuid has no preconditions.
        let uid = unsafe { libc::getuid() };
        Self {
            cgroup_root: format!("/sys/fs/cgroup/user.slice/user-{uid}.slice/user@{uid}.service")
                .into(),
            scopes: vec!["ditto-shell.scope".into(), "ditto-quickshell.scope".into()],
            pid_file,
        }
    }

    fn find_scope(&self) -> Option<PathBuf> {
        fn search(dir: &Path, name: &str, depth: usize) -> Option<PathBuf> {
            let candidate = dir.join(name);
            if candidate.join("cgroup.procs").is_file() {
                return Some(candidate);
            }
            if depth == 0 {
                return None;
            }
            fs::read_dir(dir)
                .ok()?
                .flatten()
                .filter(|entry| entry.file_type().is_ok_and(|t| t.is_dir()))
                .filter(|entry| entry.file_name().to_string_lossy().ends_with(".slice"))
                .find_map(|entry| search(&entry.path(), name, depth - 1))
        }
        self.scopes
            .iter()
            .find_map(|scope| search(&self.cgroup_root, scope, 3))
    }

    /// The Shell's processes: every PID in its scope, else the PID file's
    /// process if it is still the same process and ours.
    pub fn find(&self) -> (Vec<u32>, &'static str) {
        if let Some(scope) = self.find_scope() {
            let pids: Vec<u32> = fs::read_to_string(scope.join("cgroup.procs"))
                .unwrap_or_default()
                .lines()
                .filter_map(|line| line.trim().parse().ok())
                .filter(|pid| safe_target(*pid))
                .collect();
            if !pids.is_empty() {
                return (pids, "scope");
            }
        }
        let Ok(text) = fs::read_to_string(&self.pid_file) else {
            return (Vec::new(), "none");
        };
        let mut fields = text.split_whitespace();
        let Some(pid) = fields.next().and_then(|p| p.parse::<u32>().ok()) else {
            return (Vec::new(), "none");
        };
        let start_matches = match fields.next() {
            Some(expected) => start_time(pid).as_deref() == Some(expected),
            None => true,
        };
        if start_matches && safe_target(pid) && owned_by_us(pid) {
            (vec![pid], "pid_file")
        } else {
            (Vec::new(), "stale_pid_file")
        }
    }
}

fn safe_target(pid: u32) -> bool {
    pid > 1 && pid != std::process::id()
}

fn owned_by_us(pid: u32) -> bool {
    // SAFETY: getuid has no preconditions.
    fs::metadata(format!("/proc/{pid}")).is_ok_and(|meta| meta.uid() == unsafe { libc::getuid() })
}

/// Field 22 of `/proc/<pid>/stat`, which tells a reused PID apart.
pub fn start_time(pid: u32) -> Option<String> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat.rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(19)
        .map(String::from)
}

pub struct Killed {
    pub pids: Vec<u32>,
    pub source: &'static str,
}

pub fn kill_shell(locator: &Locator) -> Killed {
    let (pids, source) = locator.find();
    let pids = pids
        .into_iter()
        // SAFETY: kill(2) with a validated PID and a constant signal.
        .filter(|pid| unsafe { libc::kill(*pid as libc::pid_t, libc::SIGKILL) } == 0)
        .collect();
    Killed { pids, source }
}

/// What the rescue UI and Core read to learn why rescue started. It is a
/// runtime note in `$DITTO_RUNTIME_DIR`, never configuration.
pub fn write_rescue_request(runtime_dir: &Path, reason: &str, killed: &Killed) {
    let at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let pids = killed
        .pids
        .iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let body = format!(
        "{{\"reason\":\"{reason}\",\"at_unix_ms\":{at},\"killed_pids\":[{pids}],\"found_by\":\"{}\"}}\n",
        killed.source
    );
    let path = runtime_dir.join("rescue-request.json");
    let temporary = runtime_dir.join(".rescue-request.json.tmp");
    let _ = fs::create_dir_all(runtime_dir);
    if fs::write(&temporary, body)
        .and_then(|()| fs::rename(&temporary, &path))
        .is_err()
    {
        eprintln!(
            "ditto-supervisor event=rescue_request_unwritten path={:?}",
            path.display().to_string()
        );
    }
}

/// A request younger than `within`, if there is one.
pub fn recent_rescue_request(runtime_dir: &Path, within: Duration) -> Option<String> {
    let path = runtime_dir.join("rescue-request.json");
    let age = fs::metadata(&path).ok()?.modified().ok()?.elapsed().ok()?;
    (age <= within)
        .then(|| fs::read_to_string(&path).ok())
        .flatten()
}

/// `--no-block`: the supervisor must keep watching while the unit starts.
pub fn start_unit(unit: &str) -> Result<(), String> {
    let output = Command::new("systemctl")
        .args(["--user", "start", "--no-block", unit])
        .output()
        .map_err(|error| format!("systemctl: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::unix::net::UnixListener;
    use std::process::Stdio;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    fn temp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("ditto-supervisor-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A Shell stand-in: `reply` maps each received line to what it sends.
    /// Returns the number of connections it has accepted so far.
    fn serve(path: &Path, reply: fn(&str) -> Option<String>) -> Arc<AtomicUsize> {
        let listener = UnixListener::bind(path).unwrap();
        let accepted = Arc::new(AtomicUsize::new(0));
        let counter = accepted.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                counter.fetch_add(1, Ordering::SeqCst);
                std::thread::spawn(move || {
                    let mut writer = stream.try_clone().unwrap();
                    for line in BufReader::new(stream).lines() {
                        let Ok(line) = line else { return };
                        if let Some(answer) = reply(&line) {
                            let _ = writer.write_all(answer.as_bytes());
                        }
                    }
                });
            }
        });
        accepted
    }

    #[test]
    fn pinger_outcomes() {
        let dir = temp("ping");
        let timeout = Duration::from_millis(200);
        let mut absent = SocketPinger::new(dir.join("missing.sock"));
        assert_eq!(absent.ping(1, timeout), Outcome::Absent);

        let good = dir.join("good.sock");
        let accepted = serve(&good, |line| {
            Some(format!("hello\n{}\n", line.replace("ping", "pong")))
        });
        let mut pinger = SocketPinger::new(good);
        assert_eq!(pinger.ping(7, timeout), Outcome::Pong);
        assert_eq!(pinger.ping(8, timeout), Outcome::Pong);
        assert_eq!(
            accepted.load(Ordering::SeqCst),
            1,
            "one connection across pings"
        );

        // A missed reply drops the connection; the next ping reconnects.
        let flaky = dir.join("flaky.sock");
        let accepted = serve(&flaky, |line| {
            (!line.ends_with(" 2")).then(|| format!("{}\n", line.replace("ping", "pong")))
        });
        let mut pinger = SocketPinger::new(flaky);
        assert_eq!(pinger.ping(1, timeout), Outcome::Pong);
        assert!(matches!(pinger.ping(2, timeout), Outcome::NoReply(_)));
        assert_eq!(pinger.ping(3, timeout), Outcome::Pong);
        assert_eq!(accepted.load(Ordering::SeqCst), 2);

        let silent = dir.join("silent.sock");
        serve(&silent, |_| None);
        let started = Instant::now();
        assert_eq!(
            SocketPinger::new(silent).ping(1, timeout),
            Outcome::NoReply("timeout".into())
        );
        assert!(started.elapsed() < Duration::from_millis(400));

        let wrong = dir.join("wrong.sock");
        serve(&wrong, |_| Some("pong 999\n".into()));
        assert!(matches!(
            SocketPinger::new(wrong).ping(1, timeout),
            Outcome::NoReply(_)
        ));

        // A socket file with nothing listening: the Shell exited.
        let stale = dir.join("stale.sock");
        drop(UnixListener::bind(&stale).unwrap());
        assert_eq!(SocketPinger::new(stale).ping(1, timeout), Outcome::Absent);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_stopped_listener_is_a_miss_not_a_hang() {
        // Bound and listening, but nobody accepts: what SIGSTOP looks like.
        let dir = temp("stopped");
        let path = dir.join("stopped.sock");
        let _listener = UnixListener::bind(&path).unwrap();
        let started = Instant::now();
        for sequence in 0..40 {
            let outcome = SocketPinger::new(path.clone()).ping(sequence, Duration::from_millis(20));
            assert!(matches!(outcome, Outcome::NoReply(_)), "{outcome:?}");
        }
        assert!(started.elapsed() < Duration::from_secs(5));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn finds_the_scope_before_the_pid_file() {
        let dir = temp("locate");
        let mut child = Command::new("sleep")
            .arg("30")
            .stdin(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id();
        let scope = dir.join("app.slice/ditto-shell.scope");
        fs::create_dir_all(&scope).unwrap();
        fs::write(
            scope.join("cgroup.procs"),
            format!("{pid}\n1\n{}\n", std::process::id()),
        )
        .unwrap();
        let mut locator = Locator {
            cgroup_root: dir.clone(),
            scopes: vec!["ditto-shell.scope".into()],
            pid_file: dir.join("shell.pid"),
        };
        assert_eq!(
            locator.find(),
            (vec![pid], "scope"),
            "PID 1 and ourselves are never targets"
        );

        locator.scopes = vec!["other.scope".into()];
        assert_eq!(locator.find(), (vec![], "none"));
        fs::write(&locator.pid_file, format!("{pid}\n")).unwrap();
        assert_eq!(locator.find(), (vec![pid], "pid_file"));
        fs::write(
            &locator.pid_file,
            format!("{pid} {}\n", start_time(pid).unwrap()),
        )
        .unwrap();
        assert_eq!(locator.find(), (vec![pid], "pid_file"));
        fs::write(&locator.pid_file, format!("{pid} 1\n")).unwrap();
        assert_eq!(
            locator.find(),
            (vec![], "stale_pid_file"),
            "a reused PID is not killed"
        );

        fs::write(&locator.pid_file, format!("{pid}\n")).unwrap();
        let killed = kill_shell(&locator);
        assert_eq!(killed.pids, [pid]);
        let status = child.wait().unwrap();
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(status.signal(), Some(libc::SIGKILL));

        write_rescue_request(&dir, "shell_unresponsive", &killed);
        let request = recent_rescue_request(&dir, Duration::from_secs(30)).unwrap();
        assert!(
            request.contains("\"reason\":\"shell_unresponsive\"")
                && request.contains(&pid.to_string())
        );
        assert!(recent_rescue_request(&dir.join("nowhere"), Duration::from_secs(30)).is_none());
        let _ = fs::remove_dir_all(&dir);
    }
}
