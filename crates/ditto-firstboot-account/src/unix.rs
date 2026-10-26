use crate::{
    input::MAX_PASSWORD, phase, AccountTools, Code, Engine, Request, Response, Secret, MAX_REQUEST,
};
use std::{
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    mem::{size_of, MaybeUninit},
    os::{
        fd::{AsRawFd, FromRawFd, RawFd},
        unix::{
            fs::OpenOptionsExt,
            net::{UnixListener, UnixStream},
        },
    },
    time::{Duration, Instant},
};

pub fn peer_uid(stream: &UnixStream) -> io::Result<u32> {
    let mut cred = MaybeUninit::<libc::ucred>::uninit();
    let mut size = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: buffers have the exact size supplied to getsockopt; stream is live.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            cred.as_mut_ptr().cast(),
            &mut size,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if size as usize != size_of::<libc::ucred>() {
        return Err(io::Error::other("invalid peer credential size"));
    }
    // SAFETY: getsockopt succeeded and filled the full ucred.
    Ok(unsafe { cred.assume_init() }.uid)
}
pub fn greetd_uid() -> io::Result<u32> {
    let mut entry = MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    // Local service account lookup; fail closed rather than guess a numeric UID.
    let mut buffer = vec![0u8; 65536];
    // SAFETY: all pointers refer to live buffers of the provided size; C name is terminated.
    let code = unsafe {
        libc::getpwnam_r(
            c"_greetd".as_ptr(),
            entry.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if code != 0 {
        return Err(io::Error::from_raw_os_error(code));
    }
    if result.is_null() {
        return Err(io::Error::other("missing greeter account"));
    }
    // SAFETY: a non-null result from successful getpwnam_r initialized entry.
    Ok(unsafe { entry.assume_init() }.pw_uid)
}
fn socket_option(fd: RawFd, option: libc::c_int) -> io::Result<libc::c_int> {
    let mut value = 0;
    let mut len = size_of::<libc::c_int>() as libc::socklen_t;
    // SAFETY: fd is checked by the kernel; value and length are valid buffers.
    if unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            option,
            (&mut value as *mut libc::c_int).cast(),
            &mut len,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(value)
}
pub fn activated_listener() -> io::Result<UnixListener> {
    if std::env::var("LISTEN_PID").ok().as_deref() != Some(&std::process::id().to_string())
        || std::env::var("LISTEN_FDS").ok().as_deref() != Some("1")
    {
        return Err(io::Error::other("expected one systemd listener"));
    }
    let fd = 3;
    if socket_option(fd, libc::SO_DOMAIN)? != libc::AF_UNIX
        || socket_option(fd, libc::SO_TYPE)? != libc::SOCK_STREAM
        || socket_option(fd, libc::SO_ACCEPTCONN)? != 1
    {
        return Err(io::Error::other("invalid listener"));
    }
    // SAFETY: after validation above, take sole ownership of the inherited fd.
    let listener = unsafe { UnixListener::from_raw_fd(fd) };
    listener.local_addr()?; // Reject a non-AF_UNIX socket.
                            // SAFETY: fd is live; prevent inherited listener leaking to account tools.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
        return Err(io::Error::last_os_error());
    }
    // Single-threaded binary, before spawning any tools.
    std::env::remove_var("LISTEN_PID");
    std::env::remove_var("LISTEN_FDS");
    std::env::remove_var("LISTEN_FDNAMES");
    Ok(listener)
}
/// Frame is compact JSON followed by LF, or EOF after shutdown(SHUT_WR).
/// The deadline covers the whole frame, including a slow sender.
fn read_frame(stream: &mut UnixStream) -> io::Result<Secret> {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut bytes = Secret::bounded(MAX_REQUEST + 1);
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "request deadline"))?;
        stream.set_read_timeout(Some(remaining))?;
        // Read directly into the zeroized allocation: no buffering layer copies.
        let old = bytes.0.len();
        bytes.0.resize(old + 1, 0);
        match stream.read(&mut bytes.0[old..]) {
            Ok(0) => {
                bytes.0.truncate(old);
                return Ok(bytes);
            }
            Ok(_) if bytes.0[old] == b'\n' => {
                bytes.0.truncate(old);
                return Ok(bytes);
            }
            Ok(_) if bytes.0.len() > MAX_REQUEST => {
                return Err(io::Error::other("oversize request"))
            }
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {
                bytes.0.truncate(old);
            }
            Err(e) => return Err(e),
        }
    }
}
impl<T: AccountTools> Engine<T> {
    pub fn serve(
        &self,
        mut stream: UnixStream,
        expected_uid: u32,
        log: &mut dyn Write,
    ) -> io::Result<()> {
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        let response = if peer_uid(&stream).ok() != Some(expected_uid) {
            phase(log, "authorize", "unauthorized");
            Response::error(Code::Unauthorized)
        } else {
            phase(log, "authorize", "ok");
            match read_frame(&mut stream) {
                Ok(bytes) => {
                    let request = serde_json::from_slice::<Request>(bytes.as_bytes());
                    drop(bytes);
                    match request {
                        Ok(request) => self.handle(&request, log),
                        Err(_) => {
                            phase(log, "parse", "internal_rolled_back");
                            Response::error(Code::InternalRolledBack)
                        }
                    }
                }
                Err(_) => {
                    phase(log, "frame", "internal_rolled_back");
                    Response::error(Code::InternalRolledBack)
                }
            }
        };
        serde_json::to_writer(&mut stream, &response)?;
        stream.write_all(b"\n")?;
        // Close without shutting down/unlinking the shared Accept=no listener.
        Ok(())
    }
}
static TTY_INTERRUPTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
extern "C" fn tty_signal(_: libc::c_int) {
    TTY_INTERRUPTED.store(true, std::sync::atomic::Ordering::Relaxed);
}
struct SignalGuard(Vec<(libc::c_int, libc::sigaction)>);
impl SignalGuard {
    fn install() -> io::Result<Self> {
        TTY_INTERRUPTED.store(false, std::sync::atomic::Ordering::Relaxed);
        let mut guard = Self(Vec::new());
        for signal in [libc::SIGINT, libc::SIGQUIT, libc::SIGTERM, libc::SIGHUP] {
            // SAFETY: zero is a valid initial sigaction; initialize the mask below.
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = tty_signal as *const () as libc::sighandler_t;
            let mut old = MaybeUninit::uninit();
            // No SA_RESTART: read returns EINTR, allowing EchoGuard to restore tty.
            // SAFETY: pointers refer to valid sigaction and sigset_t storage.
            unsafe {
                libc::sigemptyset(&mut action.sa_mask);
            }
            if unsafe { libc::sigaction(signal, &action, old.as_mut_ptr()) } != 0 {
                return Err(io::Error::last_os_error());
            }
            guard.0.push((signal, unsafe { old.assume_init() }));
        }
        Ok(guard)
    }
}
impl Drop for SignalGuard {
    fn drop(&mut self) {
        for (signal, action) in &self.0 {
            // SAFETY: each action was obtained from successful sigaction.
            unsafe {
                libc::sigaction(*signal, action, std::ptr::null_mut());
            }
        }
    }
}
pub(crate) fn check_tty_signal() -> io::Result<()> {
    if TTY_INTERRUPTED.load(std::sync::atomic::Ordering::Relaxed) {
        Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "tty interrupted",
        ))
    } else {
        Ok(())
    }
}
struct EchoGuard {
    fd: RawFd,
    original: libc::termios,
}
impl EchoGuard {
    fn disable(fd: RawFd) -> io::Result<Self> {
        let mut original = MaybeUninit::uninit();
        // SAFETY: termios buffer is valid, fd refers to the controlling tty.
        if unsafe { libc::tcgetattr(fd, original.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: successful tcgetattr initializes the complete structure.
        let original = unsafe { original.assume_init() };
        let mut hidden = original;
        hidden.c_lflag &= !(libc::ECHO | libc::ECHONL);
        // SAFETY: hidden is initialized and fd live.
        if unsafe { libc::tcsetattr(fd, libc::TCSAFLUSH, &hidden) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { fd, original })
    }
}
impl Drop for EchoGuard {
    fn drop(&mut self) {
        // SAFETY: tty File outlives the guard; restore echo even on read errors.
        unsafe {
            libc::tcsetattr(self.fd, libc::TCSAFLUSH, &self.original);
        }
    }
}
fn prompt(tty: &mut File, text: &str, hidden: bool, limit: usize) -> io::Result<Secret> {
    check_tty_signal()?;
    tty.write_all(text.as_bytes())?;
    tty.flush()?;
    let guard = if hidden {
        Some(EchoGuard::disable(tty.as_raw_fd())?)
    } else {
        None
    };
    let mut value = Secret::bounded(limit + 1);
    loop {
        check_tty_signal()?;
        let mut ready = libc::pollfd {
            fd: tty.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // A bounded kernel wait closes the signal-before-read race. It does not
        // consume or copy any terminal input and uses no watcher thread.
        // SAFETY: ready points to one initialized pollfd.
        let result = unsafe { libc::poll(&mut ready, 1, 1000) };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        if result == 0 {
            continue;
        }
        check_tty_signal()?;
        let old = value.0.len();
        value.0.resize(old + 1, 0);
        if tty.read(&mut value.0[old..])? == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "tty closed"));
        }
        if value.0[old] == b'\n' {
            value.0.truncate(old);
            break;
        }
        if value.0.len() > limit {
            return Err(io::Error::other("input too long"));
        }
    }
    drop(guard);
    if hidden {
        tty.write_all(b"\n")?;
    }
    Ok(value)
}
pub fn tty<T: AccountTools>(engine: &Engine<T>, log: &mut dyn Write) -> io::Result<()> {
    let _signals = SignalGuard::install()?;
    let mut tty = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY | libc::O_CLOEXEC)
        .open("/dev/tty")?;
    engine
        .recover(log)
        .map_err(|_| io::Error::other("recovery failed"))?;
    tty.write_all(b"Create your Ditto administrator account.\n")?;
    let display = prompt(&mut tty, "Your name (optional): ", false, 512)?;
    let username = prompt(
        &mut tty,
        "Username (lowercase letters, digits, hyphens): ",
        false,
        31,
    )?;
    let password = prompt(
        &mut tty,
        "Password (at least 8 characters): ",
        true,
        MAX_PASSWORD,
    )?;
    let confirm = prompt(&mut tty, "Confirm password: ", true, MAX_PASSWORD)?;
    if password.as_bytes() != confirm.as_bytes() {
        tty.write_all(b"Passwords differ. Please try again.\n")?;
        return Ok(());
    }
    let request = Request {
        display_name: display.as_str().map_err(io::Error::other)?.into(),
        username: username.as_str().map_err(io::Error::other)?.into(),
        password,
    };
    check_tty_signal()?;
    if crate::validate(&request) == Ok(true) {
        tty.write_all(
            b"Warning: this password is easy to guess. You may still create the account.\n",
        )?;
    }
    match engine.handle(&request, log) {
        Response::Success { .. } => {
            tty.write_all(b"Account created. Sign in with your new username and password.\n")?;
        }
        Response::Error { error, .. } => {
            writeln!(tty, "Account was not created: {}. Retry or ask an administrator to inspect the first-boot log.", error.as_str())?;
        }
    }
    Ok(())
}
/// Disable core dumps for both helper and child account tools. Other
/// copies in swap/kernel buffers remain outside the helper's control.
pub fn protect_process() -> io::Result<()> {
    let limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: pointer to initialized rlimit; prctl's argument is a scalar.
    if unsafe { libc::setrlimit(libc::RLIMIT_CORE, &limit) } != 0
        || unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0) } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tty_password_has_no_echo_and_restores_terminal() {
        let mut master = -1;
        let mut slave = -1;
        // SAFETY: output descriptors are valid pointers; optional settings null.
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    std::ptr::null(),
                )
            },
            0
        );
        // SAFETY: openpty returned unique owned descriptors.
        let mut master = unsafe { File::from_raw_fd(master) };
        let mut slave = unsafe { File::from_raw_fd(slave) };
        std::thread::scope(|scope| {
            let task =
                scope.spawn(|| prompt(&mut slave, "Password: ", true, MAX_PASSWORD).unwrap());
            let mut text = [0; 10];
            master.read_exact(&mut text).unwrap();
            assert_eq!(&text, b"Password: ");
            // The prompt is emitted before tcsetattr. Wait for the actual tty flag,
            // with a bounded poll in this test, before delivering input.
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                let mut state = MaybeUninit::<libc::termios>::uninit();
                // SAFETY: state is a valid output buffer, master is a live pty.
                assert_eq!(
                    unsafe { libc::tcgetattr(master.as_raw_fd(), state.as_mut_ptr()) },
                    0
                );
                if unsafe { state.assume_init() }.c_lflag & libc::ECHO == 0 {
                    break;
                }
                assert!(Instant::now() < deadline);
                std::thread::yield_now();
            }
            master.write_all(b"Pty-Test-Secret!\n").unwrap();
            assert_eq!(task.join().unwrap().as_bytes(), b"Pty-Test-Secret!");
        });
        let mut state = MaybeUninit::<libc::termios>::uninit();
        // SAFETY: live descriptor and output buffer.
        assert_eq!(
            unsafe { libc::tcgetattr(slave.as_raw_fd(), state.as_mut_ptr()) },
            0
        );
        assert_ne!(unsafe { state.assume_init() }.c_lflag & libc::ECHO, 0);
        let mut output = [0; 2];
        master.read_exact(&mut output).unwrap();
        assert_eq!(&output, b"\r\n");
    }

    // Isolate process-wide signal dispositions/flag from parallel libtest cases.
    #[test]
    fn tty_signal_guard_survives_and_restores_all_signals() {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "unix::tests::tty_signal_guard_child",
                "--nocapture",
            ])
            .env("DITTO_220_SIGNAL_CHILD", "1")
            .status()
            .unwrap();
        assert!(status.success(), "signal child: {status}");
    }
    #[test]
    fn tty_signal_guard_child() {
        if std::env::var_os("DITTO_220_SIGNAL_CHILD").is_none() {
            return;
        }
        protect_process().unwrap();
        for signal in [libc::SIGINT, libc::SIGQUIT, libc::SIGTERM, libc::SIGHUP] {
            // SAFETY: initialize the complete action, retaining the prior one.
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = libc::SIG_IGN;
            let mut original = MaybeUninit::uninit();
            unsafe {
                libc::sigemptyset(&mut action.sa_mask);
                assert_eq!(libc::sigaction(signal, &action, original.as_mut_ptr()), 0);
            }
            let guard = SignalGuard::install().unwrap();
            // SAFETY: installed guard must catch each signal, including QUIT.
            assert_eq!(unsafe { libc::raise(signal) }, 0);
            assert_eq!(
                check_tty_signal().unwrap_err().kind(),
                io::ErrorKind::Interrupted
            );
            drop(guard);
            let mut restored = MaybeUninit::<libc::sigaction>::uninit();
            unsafe {
                assert_eq!(
                    libc::sigaction(signal, std::ptr::null(), restored.as_mut_ptr()),
                    0
                );
                assert_eq!(restored.assume_init().sa_sigaction, libc::SIG_IGN);
                assert_eq!(
                    libc::sigaction(signal, &original.assume_init(), std::ptr::null_mut()),
                    0
                );
            }
        }
    }
    // Invoked only by the Python controlling-PTY test. This double uses the real
    // Rust guard, but its account markers do not stand for real account tools.
    #[test]
    fn tty_signal_helper_child() {
        let Some(root) = std::env::var_os("DITTO_220_PTY_ROOT") else {
            return;
        };
        let root = std::path::PathBuf::from(root);
        protect_process().unwrap();
        let _guard = SignalGuard::install().unwrap();
        assert_eq!(unsafe { libc::tcgetpgrp(0) }, unsafe { libc::getpgrp() });
        File::create(root.join("calls"))
            .unwrap()
            .write_all(b"call\n")
            .unwrap();
        io::stdout()
            .write_all(b"Fixture signal helper ready\n")
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(4);
        while check_tty_signal().is_ok() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        std::fs::write(root.join("received"), libc::SIGQUIT.to_string()).unwrap();
        std::thread::sleep(Duration::from_millis(600));
        std::fs::write(root.join("created"), "committed fixture\n").unwrap();
        std::fs::write(root.join("completed"), "finished after signal\n").unwrap();
    }
    #[test]
    fn transaction_defers_interrupts_to_a_coherent_end() {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "unix::tests::transaction_interrupt_child",
                "--nocapture",
            ])
            .env("DITTO_220_TRANSACTION_CHILD", "1")
            .status()
            .unwrap();
        assert!(status.success(), "transaction child: {status}");
    }
    #[test]
    fn transaction_interrupt_child() {
        if std::env::var_os("DITTO_220_TRANSACTION_CHILD").is_none() {
            return;
        }
        use std::{fs, os::unix::fs::PermissionsExt, path::Path};
        struct Tools {
            at: &'static str,
            signal: i32,
        }
        impl Tools {
            fn interrupt(&self, at: &str) {
                if self.at == at {
                    assert_eq!(unsafe { libc::raise(self.signal) }, 0);
                }
            }
        }
        impl AccountTools for Tools {
            fn create(&self, root: &Path, _: &str, _: &str) -> io::Result<()> {
                fs::write(
                    root.join("etc/passwd"),
                    "root:x:0:0::/root:/bin/bash\nalice:x:1000:1000::/home/alice:/bin/bash\n",
                )?;
                fs::write(root.join("etc/shadow"), "alice:!:0:0:99999:7:::\n")?;
                fs::write(root.join("etc/group"), "sudo:x:27:alice\nalice:x:1000:\n")?;
                fs::create_dir(root.join("home/alice"))?;
                fs::set_permissions(root.join("home/alice"), fs::Permissions::from_mode(0o750))?;
                self.interrupt("create");
                Ok(())
            }
            fn password(&self, root: &Path, _: &str, _: &[u8]) -> io::Result<()> {
                if self.at == "delete" {
                    return Err(io::Error::other("injected password failure"));
                }
                fs::write(
                    root.join("etc/shadow"),
                    "alice:$y$test$hash:0:0:99999:7:::\n",
                )?;
                self.interrupt("password");
                Ok(())
            }
            fn delete(&self, root: &Path, _: &str) -> io::Result<()> {
                // No interrupt may cause deletion of an initialized account.
                assert!(!fs::read_to_string(root.join("etc/shadow"))?.contains("$y$"));
                self.interrupt("delete");
                self.interrupt("delete"); // repeated interrupt during rollback
                fs::write(root.join("etc/passwd"), "root:x:0:0::/root:/bin/bash\n")?;
                fs::write(root.join("etc/shadow"), "")?;
                fs::write(root.join("etc/group"), "sudo:x:27:\n")?;
                fs::remove_dir(root.join("home/alice"))
            }
        }
        struct Log<'a> {
            tools: &'a Tools,
            bytes: Vec<u8>,
        }
        impl Write for Log<'_> {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                self.bytes.extend_from_slice(bytes);
                // phase() formats across multiple writes; inject at whole line.
                if bytes.ends_with(b"\n") {
                    let text = String::from_utf8_lossy(&self.bytes);
                    if text.ends_with("phase=chpasswd result=begin\n") {
                        self.tools.interrupt("between");
                    }
                    if text.ends_with("phase=commit result=ok\n") {
                        self.tools.interrupt("committed");
                    }
                }
                Ok(bytes.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        protect_process().unwrap();
        for signal in [libc::SIGINT, libc::SIGQUIT, libc::SIGTERM, libc::SIGHUP] {
            for at in ["create", "between", "password", "delete", "committed"] {
                let _guard = SignalGuard::install().unwrap();
                let root = std::env::temp_dir()
                    .join(format!("ditto-220-{}-{signal}-{at}", std::process::id()));
                for dir in ["etc", "home", "var/mail", "var/lib/ditto/firstboot"] {
                    fs::create_dir_all(root.join(dir)).unwrap();
                }
                for dir in ["", "var", "var/lib", "var/lib/ditto"] {
                    fs::set_permissions(root.join(dir), fs::Permissions::from_mode(0o755)).unwrap();
                }
                fs::set_permissions(
                    root.join("var/lib/ditto/firstboot"),
                    fs::Permissions::from_mode(0o700),
                )
                .unwrap();
                for (file, text) in [
                    ("passwd", "root:x:0:0::/root:/bin/bash\n"),
                    ("shadow", ""),
                    ("group", "sudo:x:27:\n"),
                    ("gshadow", ""),
                    ("login.defs", "UID_MIN 1000\nUID_MAX 60000\n"),
                ] {
                    fs::write(root.join("etc").join(file), text).unwrap();
                }
                let engine = Engine {
                    root: root.clone(),
                    tools: Tools { at, signal },
                };
                let mut log = Log {
                    tools: &engine.tools,
                    bytes: Vec::new(),
                };
                let request = Request {
                    display_name: "".into(),
                    username: "alice".into(),
                    password: "Unique-Test-Secret!42".into(),
                };
                let response = engine.handle(&request, &mut log);
                let committed = at != "delete";
                assert_eq!(
                    matches!(response, Response::Success { .. }),
                    committed,
                    "{signal} {at}: {response:?}"
                );
                if !committed {
                    assert_eq!(response, Response::error(Code::InternalRolledBack));
                }
                assert_eq!(
                    fs::read_to_string(root.join("etc/passwd"))
                        .unwrap()
                        .contains("alice:"),
                    committed
                );
                assert_eq!(
                    fs::read_to_string(root.join("etc/shadow"))
                        .unwrap()
                        .contains("$y$"),
                    committed
                );
                assert_eq!(root.join("home/alice").exists(), committed);
                assert_eq!(
                    root.join("var/lib/ditto/firstboot/account-created")
                        .exists(),
                    committed
                );
                assert!(!root.join("var/lib/ditto/firstboot/pending").exists());
                assert!(check_tty_signal().is_err(), "signal injection missed {at}");
                if matches!(at, "create" | "between" | "password") {
                    assert!(
                        String::from_utf8(log.bytes)
                            .unwrap()
                            .contains("phase=interrupt result=deferred\n"),
                        "transaction did not observe {signal} {at}"
                    );
                }
                fs::remove_dir_all(root).unwrap();
            }
        }
    }
}
