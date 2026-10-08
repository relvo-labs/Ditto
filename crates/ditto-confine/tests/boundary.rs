//! Positive and negative checks of the boundary with a real program. Python is
//! only the probe: the mechanism under test is the helper's Landlock ruleset
//! and its connect() broker, which apply to any executable the same way.
use std::{
    collections::HashMap,
    io::{Read, Write},
    net::TcpListener,
    os::unix::net::UnixListener,
    path::{Path, PathBuf},
    process::Command,
    thread,
};

fn scratch(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("ditto-confine-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::create_dir_all(&path).unwrap();
    path
}

fn serve_unix(path: &Path) {
    let listener = UnixListener::bind(path).unwrap();
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut stream = stream;
            let mut buffer = [0u8; 4];
            if stream.read_exact(&mut buffer).is_ok() {
                let _ = stream.write_all(b"pong");
            }
        }
    });
}

/// The helper refuses to run below Landlock ABI 6 (no abstract-socket or
/// signal scoping); on such a kernel these tests have nothing to observe.
fn landlock_ready() -> bool {
    // SAFETY: the version query takes no pointer.
    let abi = unsafe { syscall(444, 0usize, 0usize, 1u32) };
    if abi < 6 {
        eprintln!("Landlock ABI {abi} < 6: ditto-confine refuses to start here; skipped");
    }
    abi >= 6
}

#[test]
fn boundary_enforces_files_sockets_ports_and_signals() {
    if !landlock_ready() {
        return;
    }
    if !Path::new("/usr/bin/python3").exists() {
        eprintln!("python3 is not installed; probe skipped");
        return;
    }
    let root = scratch("boundary");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let allowed = root.join("allowed.sock");
    let denied = root.join("denied.sock");
    serve_unix(&allowed);
    serve_unix(&denied);
    // An abstract socket held by this (unconfined) test process.
    let abstract_name = format!("ditto-confine-test-{}", std::process::id());
    let abstract_listener = {
        use std::os::linux::net::SocketAddrExt;
        let address =
            std::os::unix::net::SocketAddr::from_abstract_name(abstract_name.as_bytes()).unwrap();
        UnixListener::bind_addr(&address).unwrap()
    };
    let tcp_ok = TcpListener::bind("127.0.0.1:0").unwrap();
    let tcp_denied = TcpListener::bind("127.0.0.1:0").unwrap();
    let ok_port = tcp_ok.local_addr().unwrap().port();
    let denied_port = tcp_denied.local_addr().unwrap().port();
    let bind_port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    thread::spawn(move || for _ in tcp_ok.incoming() {});
    let _ = std::fs::remove_file("/tmp/ditto-confine-escape");

    // The supervisor's PID is the helper's own: it is what `$PPID` is to the
    // probe. Pass a placeholder; the probe receives the real one below.
    let probe = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/probe.py");
    let script = format!(
        "import os,sys,runpy; sys.argv=['probe',{home:?},{allowed:?},{denied:?},{abstract_name:?},'{ok_port}','{denied_port}','{bind_port}',str(os.getppid())]; runpy.run_path({probe:?})",
        home = home.to_str().unwrap(),
        allowed = allowed.to_str().unwrap(),
        denied = denied.to_str().unwrap(),
    );
    let output = Command::new(env!("CARGO_BIN_EXE_ditto-confine"))
        .args(["--read", "/usr", "--read", "/etc", "--read", probe])
        .arg("--write")
        .arg(&home)
        .args(["--tcp-loopback", &ok_port.to_string()])
        .args(["--bind-tcp", &bind_port.to_string()])
        .arg("--unix")
        .arg(&allowed)
        .arg("--cwd")
        .arg(&home)
        .args(["--env", "PATH=/usr/bin", "--env", "LANG=C.UTF-8"])
        .args(["--", "/usr/bin/python3", "-c", &script])
        .output()
        .unwrap();
    drop(abstract_listener);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "probe failed: {stdout}\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let results: HashMap<&str, &str> = stdout
        .lines()
        .filter_map(|line| line.split_once(' '))
        .collect();
    let expect = |check: &str, wanted: &[&str]| {
        let got = results.get(check).copied().unwrap_or("missing");
        assert!(
            wanted.contains(&got),
            "{check}: got {got}, wanted {wanted:?}\n{stdout}"
        );
    };
    expect("read_home", &["EACCES"]);
    expect("write_inside", &["ok"]);
    expect("write_outside", &["EACCES"]);
    assert!(!Path::new("/tmp/ditto-confine-escape").exists());
    expect("unix_allowed", &["ok"]);
    expect("unix_denied", &["EACCES"]);
    expect("unix_abstract", &["EPERM", "EACCES"]);
    expect("socket_netlink", &["EAFNOSUPPORT"]);
    expect("socket_unix_dgram", &["EAFNOSUPPORT"]);
    expect("socket_packet", &["EAFNOSUPPORT"]);
    expect("tcp_allowed", &["ok"]);
    expect("tcp_allowed_nonblocking", &["ok"]);
    expect("tcp_denied", &["EACCES"]);
    expect("bind_allowed", &["ok"]);
    expect("bind_denied", &["EACCES"]);
    expect("inet_socket_unix_address", &["EACCES", "EAFNOSUPPORT"]);
    expect("unix_socket_inet_address", &["EACCES"]);
    expect("signal_supervisor", &["EPERM"]);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn status_line_is_written_only_after_confinement() {
    if !landlock_ready() {
        return;
    }
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let mut fds = [0; 2];
    // SAFETY: pipe2 fills two descriptors.
    assert_eq!(unsafe { libc_pipe(&mut fds) }, 0);
    // SAFETY: descriptors just created.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    let raw = write.as_raw_fd();
    let mut command = Command::new(env!("CARGO_BIN_EXE_ditto-confine"));
    command.args(["--status-fd", "3", "--read", "/usr", "--", "/usr/bin/true"]);
    // SAFETY: dup2 into the child's fd 3.
    unsafe {
        use std::os::unix::process::CommandExt;
        command.pre_exec(move || {
            if dup2(raw, 3) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let status = command.status().unwrap();
    drop(write);
    let mut text = String::new();
    std::fs::File::from(read).read_to_string(&mut text).unwrap();
    assert!(status.success());
    assert!(text.starts_with("{\"confined\":true,"), "{text}");
    assert!(text.contains("\"seccomp\":\"connect-broker\""), "{text}");

    // A program outside the readable set cannot even be executed.
    let denied = Command::new(env!("CARGO_BIN_EXE_ditto-confine"))
        .args(["--read", "/etc", "--", "/usr/bin/true"])
        .status()
        .unwrap();
    assert_eq!(denied.code(), Some(71));
}

#[test]
fn session_bus_proxy_reaches_only_the_secret_service() {
    if !landlock_ready() {
        return;
    }
    let Ok(address) = std::env::var("DBUS_SESSION_BUS_ADDRESS") else {
        eprintln!("no session bus; proxy probe skipped");
        return;
    };
    if !Path::new("/usr/bin/xdg-dbus-proxy").exists() || !Path::new("/usr/bin/gdbus").exists() {
        eprintln!("xdg-dbus-proxy or gdbus missing; proxy probe skipped");
        return;
    }
    let root = scratch("bus");
    let socket = root.join("bus");
    let real = address
        .strip_prefix("unix:path=")
        .map(|p| p.split(',').next().unwrap().to_string());
    // gdbus speaks the handshake the proxy expects (sd-bus's busctl does not,
    // even without confinement). The confined program sees only the proxy.
    let call = |bus: &str, destination: &str, path: &str, method: &str, label: &str| {
        format!(
            "DBUS_SESSION_BUS_ADDRESS=unix:path={bus} gdbus call --session --timeout 3 --dest {destination} --object-path {path} --method {method} >/dev/null 2>&1 && echo {label}=ok || echo {label}=denied"
        )
    };
    let proxy = socket.to_str().unwrap();
    let mut script = format!(
        "{}; {}",
        call(
            proxy,
            "org.freedesktop.secrets",
            "/org/freedesktop/secrets",
            "org.freedesktop.DBus.Peer.Ping",
            "secrets"
        ),
        call(
            proxy,
            "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications",
            "org.freedesktop.DBus.Peer.Ping",
            "notifications"
        ),
    );
    if let Some(real) = &real {
        script.push_str("; ");
        script.push_str(&call(
            real,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus.ListNames",
            "real",
        ));
    }
    let output = Command::new(env!("CARGO_BIN_EXE_ditto-confine"))
        .args(["--read", "/usr", "--read", "/etc", "--write", "/dev/null"])
        .arg("--dbus-proxy")
        .arg("/usr/bin/xdg-dbus-proxy")
        .arg(&socket)
        .args(["--env", "PATH=/usr/bin"])
        .args(["--", "/bin/sh", "-c", &script])
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{stdout}");
    // Secrets is reachable only where a Secret Service is running.
    let has_secrets = Command::new("busctl")
        .args(["--user", "status", "org.freedesktop.secrets"])
        .output()
        .is_ok_and(|o| o.status.success());
    if has_secrets {
        assert!(stdout.contains("secrets=ok"), "{stdout}");
    }
    assert!(stdout.contains("notifications=denied"), "{stdout}");
    if real.is_some() {
        assert!(stdout.contains("real=denied"), "{stdout}");
    }
    let _ = std::fs::remove_dir_all(&root);
}

extern "C" {
    fn syscall(number: i64, ...) -> i64;
    #[link_name = "pipe"]
    fn libc_pipe(fds: &mut [i32; 2]) -> i32;
    fn dup2(old: i32, new: i32) -> i32;
}
