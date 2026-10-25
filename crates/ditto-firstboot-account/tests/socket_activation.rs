use ditto_firstboot_account::{unix, Engine, SystemTools};
use std::{
    fs,
    io::{BufRead, BufReader},
    os::{
        fd::AsRawFd,
        unix::{
            net::{UnixListener, UnixStream},
            process::CommandExt,
        },
    },
    path::PathBuf,
    process::Command,
};
#[test]
fn activation_child() {
    let Some(root) = std::env::var_os("DITTO_212_LISTENER_ROOT") else {
        return;
    };
    // This child test is the launcher: the real binary never synthesizes PID.
    std::env::set_var("LISTEN_PID", std::process::id().to_string());
    let listener = unix::activated_listener().unwrap();
    assert_eq!(listener.as_raw_fd(), 3);
    // SAFETY: listener owns fd 3, F_GETFD only reads its descriptor flags.
    assert_ne!(
        unsafe { libc::fcntl(3, libc::F_GETFD) } & libc::FD_CLOEXEC,
        0
    );
    let (stream, _) = listener.accept().unwrap();
    // A deliberately different trusted UID forces rejection before any account IO.
    let engine = Engine {
        root: PathBuf::from(root),
        tools: SystemTools,
    };
    engine
        .serve(
            stream,
            unsafe { libc::geteuid() }.wrapping_add(1),
            &mut Vec::new(),
        )
        .unwrap();
}
#[test]
fn inherited_accept_no_listener_is_adopted_and_peer_is_rejected() {
    let dir = std::env::temp_dir().join(format!("ditto-212-listener-{}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    let path = dir.join("account.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let source = listener.as_raw_fd();
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args(["--exact", "activation_child", "--nocapture"])
        .env("LISTEN_FDS", "1")
        .env("DITTO_212_LISTENER_ROOT", &dir);
    // SAFETY: pre_exec uses only async-signal-safe dup2/fcntl. The inherited
    // descriptor is owned by listener and remains live until the child exits.
    unsafe {
        command.pre_exec(move || {
            if source != 3 && libc::dup2(source, 3) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::fcntl(3, libc::F_SETFD, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn().unwrap();
    let client = UnixStream::connect(&path).unwrap();
    client
        .set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .unwrap();
    let mut line = String::new();
    BufReader::new(client).read_line(&mut line).unwrap();
    assert_eq!(line, "{\"ok\":false,\"error\":\"unauthorized\"}\n");
    assert!(child.wait().unwrap().success());
    assert!(!dir.join("var").exists());
    fs::remove_dir_all(dir).unwrap();
}
