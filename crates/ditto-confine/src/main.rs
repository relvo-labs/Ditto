//! `ditto-confine`: start one backend program inside an OS boundary that does
//! not depend on user namespaces, which the reference platform's AppArmor
//! policy denies to unprivileged processes (so bubblewrap cannot run there).
//!
//! * Landlock confines the file system to the listed paths, denies every TCP
//!   bind except the listed ports, and scopes abstract Unix sockets and
//!   signals to the confined process tree.
//! * A seccomp filter permits only IPv4/IPv6 and stream Unix sockets and sends
//!   every `connect()` to this supervisor. The supervisor duplicates the very
//!   socket object the program named, checks that object's own family, and
//!   connects it itself to an allowed endpoint. It never answers "continue",
//!   so a program that rewrites the address or swaps the descriptor after the
//!   check cannot reach anything else.
//! * An optional `xdg-dbus-proxy` gives the program one filtered session-bus
//!   socket that can talk only to the Secret Service.
//!
//! On success one JSON status line goes to `--status-fd`. Only the process
//! that started this helper (Core) may treat that line as evidence; nothing
//! the confined program says about itself counts.

use std::{
    ffi::{CString, OsStr},
    fs,
    io::{self, Read, Write},
    mem,
    net::{Ipv4Addr, Ipv6Addr},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
        unix::{ffi::OsStrExt, net::UnixStream, process::CommandExt},
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

#[cfg(not(target_arch = "x86_64"))]
compile_error!("ditto-confine's seccomp filter is written for x86_64 only");

const USAGE: &str = "usage: ditto-confine [--status-fd N] [--read PATH]... [--write PATH]...\n\
    \x20      [--tcp PORT]... [--tcp-loopback PORT]... [--bind-tcp PORT]... [--udp-dns]\n\
    \x20      [--unix PATH]... [--dbus-proxy EXECUTABLE SOCKET] [--env KEY=VALUE]...\n\
    \x20      [--cwd DIR] -- PROGRAM [ARGS...]";

#[derive(Default)]
struct Policy {
    status_fd: Option<RawFd>,
    read: Vec<PathBuf>,
    write: Vec<PathBuf>,
    tcp_any: Vec<u16>,
    tcp_loopback: Vec<u16>,
    bind_tcp: Vec<u16>,
    udp_dns: bool,
    unix: Vec<PathBuf>,
    dbus_proxy: Option<(PathBuf, PathBuf)>,
    env: Vec<(String, String)>,
    cwd: Option<PathBuf>,
    program: PathBuf,
    arguments: Vec<String>,
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.to_string())
}

fn parse() -> io::Result<Policy> {
    let mut arguments = std::env::args().skip(1);
    let mut policy = Policy::default();
    let port = |value: Option<String>| -> io::Result<u16> {
        value
            .and_then(|v| v.parse::<u16>().ok())
            .filter(|p| *p != 0)
            .ok_or_else(|| invalid(USAGE))
    };
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--status-fd" => {
                let fd = arguments
                    .next()
                    .and_then(|v| v.parse::<RawFd>().ok())
                    .filter(|fd| *fd > 2)
                    .ok_or_else(|| invalid(USAGE))?;
                policy.status_fd = Some(fd);
            }
            "--read" => policy.read.push(absolute(arguments.next())?),
            "--write" => policy.write.push(absolute(arguments.next())?),
            "--unix" => policy.unix.push(absolute(arguments.next())?),
            "--tcp" => policy.tcp_any.push(port(arguments.next())?),
            "--tcp-loopback" => policy.tcp_loopback.push(port(arguments.next())?),
            "--bind-tcp" => policy.bind_tcp.push(port(arguments.next())?),
            "--udp-dns" => policy.udp_dns = true,
            "--dbus-proxy" => {
                let executable = absolute(arguments.next())?;
                let socket = absolute(arguments.next())?;
                policy.unix.push(socket.clone());
                policy.dbus_proxy = Some((executable, socket));
            }
            "--env" => {
                let value = arguments.next().ok_or_else(|| invalid(USAGE))?;
                let (key, value) = value.split_once('=').ok_or_else(|| invalid(USAGE))?;
                if key.is_empty() || key.contains('\0') || value.contains('\0') {
                    return Err(invalid("invalid environment entry"));
                }
                policy.env.push((key.into(), value.into()));
            }
            "--cwd" => policy.cwd = Some(absolute(arguments.next())?),
            "--" => {
                policy.program = absolute(arguments.next())?;
                policy.arguments = arguments.collect();
                return Ok(policy);
            }
            _ => return Err(invalid(USAGE)),
        }
    }
    Err(invalid(USAGE))
}

fn absolute(value: Option<String>) -> io::Result<PathBuf> {
    let path = PathBuf::from(value.ok_or_else(|| invalid(USAGE))?);
    if !path.is_absolute() || path.as_os_str().as_bytes().contains(&0) {
        return Err(invalid("paths must be absolute"));
    }
    Ok(path)
}

// ---- Landlock ---------------------------------------------------------------

mod landlock {
    use super::*;

    const EXECUTE: u64 = 1 << 0;
    const WRITE_FILE: u64 = 1 << 1;
    const READ_FILE: u64 = 1 << 2;
    const READ_DIR: u64 = 1 << 3;
    const MAKE_CHAR: u64 = 1 << 6;
    const MAKE_BLOCK: u64 = 1 << 11;
    const TRUNCATE: u64 = 1 << 14;
    const IOCTL_DEV: u64 = 1 << 15;
    /// Every file-system right of ABI 5 and later.
    const ALL_FS: u64 = (1 << 16) - 1;
    const FILE_ONLY: u64 = EXECUTE | WRITE_FILE | READ_FILE | TRUNCATE | IOCTL_DEV;
    const NET_BIND_TCP: u64 = 1 << 0;
    const NET_CONNECT_TCP: u64 = 1 << 1;
    const SCOPE_ABSTRACT_UNIX: u64 = 1 << 0;
    const SCOPE_SIGNAL: u64 = 1 << 1;
    const RULE_PATH_BENEATH: libc::c_int = 1;
    const RULE_NET_PORT: libc::c_int = 2;
    /// Abstract-socket and signal scoping arrived in ABI 6. Without them a
    /// confined program could reach abstract sockets or signal Core's tree.
    pub const MINIMUM_ABI: i64 = 6;

    #[repr(C)]
    struct RulesetAttr {
        fs: u64,
        net: u64,
        scoped: u64,
    }
    #[repr(C, packed)]
    struct PathBeneath {
        allowed: u64,
        parent_fd: i32,
    }
    #[repr(C)]
    struct NetPort {
        allowed: u64,
        port: u64,
    }

    pub fn abi() -> i64 {
        // SAFETY: the version query takes no pointer.
        unsafe { libc::syscall(libc::SYS_landlock_create_ruleset, 0usize, 0usize, 1u32) }
    }

    /// Runs in the forked child, before exec.
    pub fn restrict(policy: &Policy) -> io::Result<()> {
        let attr = RulesetAttr {
            fs: ALL_FS,
            // Every connect() is brokered by the supervisor; handling the
            // connect right here also denies TCP connects that would not pass
            // through connect(), such as a fast-open send.
            net: NET_BIND_TCP | NET_CONNECT_TCP,
            scoped: SCOPE_ABSTRACT_UNIX | SCOPE_SIGNAL,
        };
        // SAFETY: attr is a valid ruleset attribute of the given size.
        let ruleset = unsafe {
            libc::syscall(
                libc::SYS_landlock_create_ruleset,
                &attr as *const RulesetAttr,
                mem::size_of::<RulesetAttr>(),
                0u32,
            )
        };
        if ruleset < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the kernel returned a new descriptor that we now own.
        let ruleset = unsafe { OwnedFd::from_raw_fd(ruleset as RawFd) };
        let read = EXECUTE | READ_FILE | READ_DIR;
        let write = ALL_FS & !(MAKE_CHAR | MAKE_BLOCK);
        for (paths, rights) in [(&policy.read, read), (&policy.write, write)] {
            for path in paths {
                path_rule(&ruleset, path, rights)?;
            }
        }
        for port in &policy.bind_tcp {
            let rule = NetPort {
                allowed: NET_BIND_TCP,
                port: u64::from(*port),
            };
            // SAFETY: rule is a valid net-port rule for this ruleset.
            let result = unsafe {
                libc::syscall(
                    libc::SYS_landlock_add_rule,
                    ruleset.as_raw_fd(),
                    RULE_NET_PORT,
                    &rule as *const NetPort,
                    0u32,
                )
            };
            if result < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        // SAFETY: restrict_self takes the ruleset descriptor and no pointer.
        if unsafe { libc::syscall(libc::SYS_landlock_restrict_self, ruleset.as_raw_fd(), 0u32) } < 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn path_rule(ruleset: &OwnedFd, path: &Path, rights: u64) -> io::Result<()> {
        let file = fs::File::options()
            .read(true)
            .custom_flags(libc::O_PATH | libc::O_CLOEXEC)
            .open(path)?;
        let directory = file.metadata()?.is_dir();
        let rule = PathBeneath {
            allowed: if directory {
                rights
            } else {
                rights & FILE_ONLY
            },
            parent_fd: file.as_raw_fd(),
        };
        // SAFETY: rule is a valid path-beneath rule; the fd stays open.
        let result = unsafe {
            libc::syscall(
                libc::SYS_landlock_add_rule,
                ruleset.as_raw_fd(),
                RULE_PATH_BENEATH,
                &rule as *const PathBeneath,
                0u32,
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    use std::os::unix::fs::OpenOptionsExt;
}

// ---- seccomp ----------------------------------------------------------------

mod seccomp {
    use super::*;

    const AUDIT_ARCH_X86_64: u32 = 0xc000_003e;
    const X32_SYSCALL_BIT: u32 = 0x4000_0000;
    const RET_KILL_PROCESS: u32 = 0x8000_0000;
    const RET_ERRNO: u32 = 0x0005_0000;
    const RET_USER_NOTIF: u32 = 0x7fc0_0000;
    const RET_ALLOW: u32 = 0x7fff_0000;
    const SET_MODE_FILTER: libc::c_uint = 1;
    const FILTER_FLAG_NEW_LISTENER: libc::c_ulong = 1 << 3;
    pub const IOCTL_NOTIF_RECV: libc::c_ulong = 0xc050_2100;
    pub const IOCTL_NOTIF_SEND: libc::c_ulong = 0xc018_2101;
    pub const IOCTL_NOTIF_ID_VALID: libc::c_ulong = 0x4008_2102;

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct Data {
        pub nr: i32,
        pub arch: u32,
        pub instruction_pointer: u64,
        pub args: [u64; 6],
    }
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct Notif {
        pub id: u64,
        pub pid: u32,
        pub flags: u32,
        pub data: Data,
    }
    #[repr(C)]
    #[derive(Default)]
    pub struct Response {
        pub id: u64,
        pub val: i64,
        pub error: i32,
        pub flags: u32,
    }

    fn statement(code: u16, k: u32) -> libc::sock_filter {
        libc::sock_filter {
            code,
            jt: 0,
            jf: 0,
            k,
        }
    }
    fn jump(k: u32, jt: u8, jf: u8) -> libc::sock_filter {
        // BPF_JMP | BPF_JEQ | BPF_K
        libc::sock_filter {
            code: 0x15,
            jt,
            jf,
            k,
        }
    }
    const LOAD: u16 = 0x20; // BPF_LD | BPF_W | BPF_ABS
    const RETURN: u16 = 0x06; // BPF_RET | BPF_K
    const AND: u16 = 0x54; // BPF_ALU | BPF_AND | BPF_K
    const JUMP_GE: u16 = 0x35; // BPF_JMP | BPF_JGE | BPF_K

    fn program() -> Vec<libc::sock_filter> {
        let errno = |e: i32| RET_ERRNO | (e as u32 & 0xffff);
        let mut p = vec![
            statement(LOAD, 4), // arch
            jump(AUDIT_ARCH_X86_64, 1, 0),
            statement(RETURN, RET_KILL_PROCESS),
            statement(LOAD, 0), // syscall number
            libc::sock_filter {
                code: JUMP_GE,
                jt: 0,
                jf: 1,
                k: X32_SYSCALL_BIT,
            },
            statement(RETURN, RET_KILL_PROCESS),
        ];
        let simple: [(libc::c_long, u32); 14] = [
            (libc::SYS_connect, RET_USER_NOTIF),
            // io_uring could perform a connect without the syscall above.
            (libc::SYS_io_uring_setup, errno(libc::ENOSYS)),
            (libc::SYS_io_uring_enter, errno(libc::ENOSYS)),
            (libc::SYS_io_uring_register, errno(libc::ENOSYS)),
            (libc::SYS_ptrace, errno(libc::EPERM)),
            (libc::SYS_process_vm_readv, errno(libc::EPERM)),
            (libc::SYS_process_vm_writev, errno(libc::EPERM)),
            (libc::SYS_pidfd_getfd, errno(libc::EPERM)),
            (libc::SYS_bpf, errno(libc::EPERM)),
            (libc::SYS_perf_event_open, errno(libc::EPERM)),
            (libc::SYS_userfaultfd, errno(libc::EPERM)),
            (libc::SYS_keyctl, errno(libc::EPERM)),
            (libc::SYS_add_key, errno(libc::EPERM)),
            (libc::SYS_request_key, errno(libc::EPERM)),
        ];
        for (number, action) in simple {
            p.push(jump(number as u32, 0, 1));
            p.push(statement(RETURN, action));
        }
        // socket(): IPv4, IPv6, or a Unix *stream* socket only. Datagram and
        // seqpacket Unix sockets could send to a named endpoint without
        // connect(); netlink and the rest have no use here.
        p.extend([
            jump(libc::SYS_socket as u32, 0, 9),
            statement(LOAD, 16), // args[0], low 32 bits
            jump(libc::AF_INET as u32, 7, 0),
            jump(libc::AF_INET6 as u32, 6, 0),
            jump(libc::AF_UNIX as u32, 1, 0),
            statement(RETURN, errno(libc::EAFNOSUPPORT)),
            statement(LOAD, 24), // args[1], low 32 bits
            statement(AND, 0xf),
            jump(libc::SOCK_STREAM as u32, 1, 0),
            statement(RETURN, errno(libc::EAFNOSUPPORT)),
            statement(RETURN, RET_ALLOW),
        ]);
        p
    }

    /// Install the filter in the calling (child) process and return the
    /// listener descriptor that the supervisor answers from.
    pub fn install() -> io::Result<OwnedFd> {
        let mut filter = program();
        let program = libc::sock_fprog {
            len: filter.len() as u16,
            filter: filter.as_mut_ptr(),
        };
        // SAFETY: program points to a filter that outlives the call.
        let fd = unsafe {
            libc::syscall(
                libc::SYS_seccomp,
                SET_MODE_FILTER,
                FILTER_FLAG_NEW_LISTENER,
                &program as *const libc::sock_fprog,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a new listener descriptor that we own.
        Ok(unsafe { OwnedFd::from_raw_fd(fd as RawFd) })
    }

    pub fn id_valid(listener: RawFd, id: u64) -> bool {
        // SAFETY: id is a valid u64 for the ioctl to read.
        unsafe { libc::ioctl(listener, IOCTL_NOTIF_ID_VALID, &id as *const u64) == 0 }
    }
}

// ---- descriptor passing -----------------------------------------------------

fn send_fd(socket: RawFd, fd: RawFd) -> io::Result<()> {
    let mut byte = [0u8; 1];
    let mut iov = libc::iovec {
        iov_base: byte.as_mut_ptr().cast(),
        iov_len: 1,
    };
    // SAFETY: CMSG_SPACE is a pure size computation.
    let space = unsafe { libc::CMSG_SPACE(mem::size_of::<RawFd>() as u32) } as usize;
    let mut control = vec![0u8; space];
    // SAFETY: zeroed msghdr is a valid starting value.
    let mut message: libc::msghdr = unsafe { mem::zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = space;
    // SAFETY: the control buffer is large enough for one descriptor.
    unsafe {
        let header = libc::CMSG_FIRSTHDR(&message);
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = libc::CMSG_LEN(mem::size_of::<RawFd>() as u32) as usize;
        std::ptr::write_unaligned(libc::CMSG_DATA(header).cast::<RawFd>(), fd);
        if libc::sendmsg(socket, &message, 0) < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

fn receive_fd(socket: RawFd) -> io::Result<OwnedFd> {
    let mut byte = [0u8; 1];
    let mut iov = libc::iovec {
        iov_base: byte.as_mut_ptr().cast(),
        iov_len: 1,
    };
    // SAFETY: CMSG_SPACE is a pure size computation.
    let space = unsafe { libc::CMSG_SPACE(mem::size_of::<RawFd>() as u32) } as usize;
    let mut control = vec![0u8; space];
    // SAFETY: zeroed msghdr is a valid starting value.
    let mut message: libc::msghdr = unsafe { mem::zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = space;
    // SAFETY: buffers above are valid for the declared lengths.
    unsafe {
        if libc::recvmsg(socket, &mut message, libc::MSG_CMSG_CLOEXEC) <= 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "confinement did not complete",
            ));
        }
        let header = libc::CMSG_FIRSTHDR(&message);
        if header.is_null()
            || (*header).cmsg_level != libc::SOL_SOCKET
            || (*header).cmsg_type != libc::SCM_RIGHTS
        {
            return Err(io::Error::other("no listener descriptor received"));
        }
        let fd = std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<RawFd>());
        Ok(OwnedFd::from_raw_fd(fd))
    }
}

// ---- the confined child -----------------------------------------------------

fn cstring(value: &OsStr) -> io::Result<CString> {
    CString::new(value.as_bytes()).map_err(|_| invalid("NUL in argument"))
}

/// Runs between fork and exec in a single-threaded child. Any failure exits
/// without exec: an unconfined program must never start.
fn child(policy: &Policy, channel: RawFd, parent: libc::pid_t) -> ! {
    let fail = |stage: &str, error: io::Error| -> ! {
        let _ = writeln!(io::stderr(), "ditto-confine: {stage}: {error}");
        // SAFETY: immediate exit in the forked child.
        unsafe { libc::_exit(71) }
    };
    // SAFETY: plain process-attribute syscalls on the calling process.
    unsafe {
        libc::setpgid(0, 0);
        if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 || libc::getppid() != parent {
            libc::_exit(71);
        }
        if libc::dup2(channel, 3) < 0 {
            fail("descriptor", io::Error::last_os_error());
        }
        // Nothing but stdio and the listener channel crosses into the program.
        if libc::syscall(libc::SYS_close_range, 4u32, u32::MAX, 0u32) != 0 {
            fail("descriptor", io::Error::last_os_error());
        }
    }
    if let Some(cwd) = &policy.cwd {
        if let Err(error) = std::env::set_current_dir(cwd) {
            fail("cwd", error);
        }
    }
    let program = cstring(policy.program.as_os_str()).unwrap_or_else(|e| fail("program", e));
    let mut argv = vec![program.clone()];
    for argument in &policy.arguments {
        argv.push(cstring(OsStr::new(argument)).unwrap_or_else(|e| fail("argument", e)));
    }
    let envp: Vec<CString> = policy
        .env
        .iter()
        .map(|(k, v)| {
            CString::new(format!("{k}={v}")).unwrap_or_else(|_| fail("env", invalid("NUL")))
        })
        .collect();
    let mut argv_ptrs: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
    argv_ptrs.push(std::ptr::null());
    let mut envp_ptrs: Vec<*const libc::c_char> = envp.iter().map(|a| a.as_ptr()).collect();
    envp_ptrs.push(std::ptr::null());
    // SAFETY: no_new_privs is required by both Landlock and seccomp.
    if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
        fail("no_new_privs", io::Error::last_os_error());
    }
    if let Err(error) = landlock::restrict(policy) {
        fail("landlock", error);
    }
    let listener = seccomp::install().unwrap_or_else(|e| fail("seccomp", e));
    if let Err(error) = send_fd(3, listener.as_raw_fd()) {
        fail("listener", error);
    }
    drop(listener);
    // SAFETY: the channel is no longer needed; argv/envp are NUL-terminated.
    unsafe {
        libc::close(3);
        libc::execve(program.as_ptr(), argv_ptrs.as_ptr(), envp_ptrs.as_ptr());
    }
    fail("exec", io::Error::last_os_error())
}

// ---- the supervisor ---------------------------------------------------------

static TERMINATE: AtomicBool = AtomicBool::new(false);
extern "C" fn on_terminate(_: libc::c_int) {
    TERMINATE.store(true, Ordering::SeqCst);
}

fn start_proxy(executable: &Path, socket: &Path) -> io::Result<(Child, UnixStream)> {
    let address = std::env::var("DBUS_SESSION_BUS_ADDRESS")
        .map_err(|_| io::Error::new(io::ErrorKind::NotFound, "no session bus"))?;
    let _ = fs::remove_file(socket);
    let (mut ours, theirs) = UnixStream::pair()?;
    let inherited: OwnedFd = theirs.into();
    let raw = inherited.as_raw_fd();
    let mut command = Command::new(executable);
    command
        .arg(format!("--fd={raw}"))
        .arg(&address)
        .arg(socket)
        .args(["--filter", "--talk=org.freedesktop.secrets"])
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    // SAFETY: clearing CLOEXEC on the one inherited descriptor in the child.
    unsafe {
        command.pre_exec(move || {
            let flags = libc::fcntl(raw, libc::F_GETFD);
            if flags < 0 || libc::fcntl(raw, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = command.spawn()?;
    drop(inherited);
    ours.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut ready = [0u8; 1];
    ours.read_exact(&mut ready)?;
    if ready[0] != b'x' {
        return Err(io::Error::other("session-bus proxy did not start"));
    }
    Ok((child, ours))
}

fn main() {
    let policy = match parse() {
        Ok(policy) => policy,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(64);
        }
    };
    let status = policy
        .status_fd
        // SAFETY: the caller hands this descriptor to us for writing.
        .map(|fd| unsafe { fs::File::from_raw_fd(fd) });
    let report_failure = |status: Option<fs::File>, reason: &str| -> ! {
        if let Some(mut file) = status {
            let _ = writeln!(file, "{{\"confined\":false,\"error\":\"{reason}\"}}");
        }
        eprintln!("ditto-confine: {reason}");
        std::process::exit(70);
    };
    // The process that started this helper (Core). When it is gone this
    // helper has been reparented, and the program it holds must not outlive
    // it: a Core that is killed cannot stop its backend.
    // SAFETY: getppid has no preconditions.
    let launcher = unsafe { libc::getppid() };
    let abi = landlock::abi();
    if abi < landlock::MINIMUM_ABI {
        report_failure(status, "landlock_unavailable");
    }
    let proxy = match &policy.dbus_proxy {
        Some((executable, socket)) => match start_proxy(executable, socket) {
            Ok(proxy) => Some(proxy),
            Err(_) => report_failure(status, "session_bus_proxy_unavailable"),
        },
        None => None,
    };
    let (ours, theirs) = match UnixStream::pair() {
        Ok(pair) => pair,
        Err(_) => report_failure(status, "channel"),
    };
    // SAFETY: getpid has no preconditions.
    let parent = unsafe { libc::getpid() };
    // SAFETY: the supervisor is single-threaded here (no thread has been
    // spawned yet), so the child may run ordinary code until exec.
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        report_failure(status, "fork");
    }
    if pid == 0 {
        drop(ours);
        child(&policy, theirs.as_raw_fd(), parent);
    }
    drop(theirs);
    let listener = match receive_fd(ours.as_raw_fd()) {
        Ok(fd) => fd,
        Err(_) => {
            // SAFETY: reap the child that failed before exec.
            unsafe {
                libc::kill(pid, libc::SIGKILL);
                libc::waitpid(pid, std::ptr::null_mut(), 0);
            }
            report_failure(status, "confinement_failed");
        }
    };
    drop(ours);
    if let Some(mut file) = status {
        let _ = writeln!(
            file,
            "{{\"confined\":true,\"pid\":{pid},\"landlock_abi\":{abi},\"seccomp\":\"connect-broker\",\"session_bus_proxy\":{}}}",
            proxy.is_some()
        );
    }
    // SAFETY: async-signal-safe handler that only stores an atomic.
    unsafe {
        let mut action: libc::sigaction = mem::zeroed();
        action.sa_sigaction = on_terminate as *const () as usize;
        libc::sigemptyset(&mut action.sa_mask);
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
    let code = supervise(&policy, listener, pid, launcher);
    // SAFETY: remove anything the program left in its process group.
    unsafe {
        libc::kill(-pid, libc::SIGKILL);
    }
    if let Some((mut child, channel)) = proxy {
        drop(channel);
        let _ = child.kill();
        let _ = child.wait();
    }
    std::process::exit(code);
}

fn supervise(policy: &Policy, listener: OwnedFd, pid: libc::pid_t, launcher: libc::pid_t) -> i32 {
    let policy = Arc::new(Endpoints::from(policy));
    let listener = Arc::new(listener);
    let in_flight = Arc::new(AtomicUsize::new(0));
    let mut kill_at: Option<Instant> = None;
    loop {
        // A parent change means the launcher exited: stop as if told to.
        // SAFETY: getppid has no preconditions.
        if unsafe { libc::getppid() } != launcher {
            TERMINATE.store(true, Ordering::SeqCst);
        }
        if TERMINATE.load(Ordering::SeqCst) && kill_at.is_none() {
            // SAFETY: signal the program's own process group.
            unsafe { libc::kill(-pid, libc::SIGTERM) };
            kill_at = Some(Instant::now() + Duration::from_secs(3));
        }
        if kill_at.is_some_and(|at| Instant::now() >= at) {
            // SAFETY: as above.
            unsafe { libc::kill(-pid, libc::SIGKILL) };
        }
        let mut wait_status = 0;
        // SAFETY: non-blocking wait on our own child.
        let reaped = unsafe { libc::waitpid(pid, &mut wait_status, libc::WNOHANG) };
        if reaped == pid {
            return if libc::WIFEXITED(wait_status) {
                libc::WEXITSTATUS(wait_status)
            } else {
                128 + libc::WTERMSIG(wait_status)
            };
        }
        let mut poll = libc::pollfd {
            fd: listener.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one valid pollfd.
        let ready = unsafe { libc::poll(&mut poll, 1, 200) };
        if ready <= 0 || poll.revents & libc::POLLIN == 0 {
            if poll.revents & (libc::POLLHUP | libc::POLLERR) != 0 {
                std::thread::sleep(Duration::from_millis(50));
            }
            continue;
        }
        let mut notif = seccomp::Notif::default();
        // SAFETY: notif is zeroed and sized as the kernel's seccomp_notif.
        if unsafe { libc::ioctl(listener.as_raw_fd(), seccomp::IOCTL_NOTIF_RECV, &mut notif) } != 0
        {
            continue;
        }
        if in_flight.fetch_add(1, Ordering::SeqCst) >= 32 {
            in_flight.fetch_sub(1, Ordering::SeqCst);
            respond(listener.as_raw_fd(), notif.id, libc::EAGAIN);
            continue;
        }
        let (policy, listener, in_flight) = (
            Arc::clone(&policy),
            Arc::clone(&listener),
            Arc::clone(&in_flight),
        );
        // A blocking TCP connect must not hold up every other request.
        std::thread::spawn(move || {
            let error = broker(listener.as_raw_fd(), &notif, &policy);
            respond(listener.as_raw_fd(), notif.id, error);
            in_flight.fetch_sub(1, Ordering::SeqCst);
        });
    }
}

fn respond(listener: RawFd, id: u64, error: i32) {
    let response = seccomp::Response {
        id,
        val: 0,
        error: -error,
        flags: 0,
    };
    // SAFETY: response is sized as the kernel's seccomp_notif_resp. A target
    // that died meanwhile makes this fail harmlessly.
    unsafe { libc::ioctl(listener, seccomp::IOCTL_NOTIF_SEND, &response) };
}

struct Endpoints {
    tcp_any: Vec<u16>,
    tcp_loopback: Vec<u16>,
    udp_dns: bool,
    unix: Vec<PathBuf>,
}
impl From<&Policy> for Endpoints {
    fn from(policy: &Policy) -> Self {
        Self {
            tcp_any: policy.tcp_any.clone(),
            tcp_loopback: policy.tcp_loopback.clone(),
            udp_dns: policy.udp_dns,
            unix: policy.unix.clone(),
        }
    }
}

fn last_errno() -> i32 {
    io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(libc::EIO)
}

/// Returns 0 or a positive errno for the program's connect().
fn broker(listener: RawFd, notif: &seccomp::Notif, endpoints: &Endpoints) -> i32 {
    if notif.data.nr != libc::SYS_connect as i32 {
        return libc::EPERM;
    }
    let (target_fd, address, length) = (
        notif.data.args[0] as RawFd,
        notif.data.args[1],
        notif.data.args[2] as usize,
    );
    if !(2..=mem::size_of::<libc::sockaddr_storage>()).contains(&length) {
        return libc::EINVAL;
    }
    // The thread id names a live thread only while the notification is
    // pending; check validity after every lookup that relies on it.
    let Some(tgid) = thread_group(notif.pid) else {
        return libc::ESRCH;
    };
    // SAFETY: pidfd_open takes a pid and flags.
    let pidfd = unsafe { libc::syscall(libc::SYS_pidfd_open, tgid, 0u32) };
    if pidfd < 0 {
        return libc::ESRCH;
    }
    // SAFETY: a new descriptor that we own.
    let pidfd = unsafe { OwnedFd::from_raw_fd(pidfd as RawFd) };
    if !seccomp::id_valid(listener, notif.id) {
        return libc::ESRCH;
    }
    let mut copied = vec![0u8; length];
    let Ok(memory) = fs::File::open(format!("/proc/{}/mem", notif.pid)) else {
        return libc::EFAULT;
    };
    if std::os::unix::fs::FileExt::read_exact_at(&memory, &mut copied, address).is_err() {
        return libc::EFAULT;
    }
    if !seccomp::id_valid(listener, notif.id) {
        return libc::ESRCH;
    }
    // SAFETY: pidfd_getfd duplicates the target's descriptor into ours.
    let socket =
        unsafe { libc::syscall(libc::SYS_pidfd_getfd, pidfd.as_raw_fd(), target_fd, 0u32) };
    if socket < 0 {
        return last_errno();
    }
    // SAFETY: a new descriptor that we own; it refers to the target's socket.
    let socket = unsafe { OwnedFd::from_raw_fd(socket as RawFd) };
    let (Some(domain), Some(kind)) = (
        socket_option(&socket, libc::SO_DOMAIN),
        socket_option(&socket, libc::SO_TYPE),
    ) else {
        return libc::ENOTSOCK;
    };
    let family = i32::from(u16::from_ne_bytes([copied[0], copied[1]]));
    match domain {
        libc::AF_UNIX => {
            if family != libc::AF_UNIX {
                return libc::EACCES;
            }
            let path = &copied[2..];
            let path = &path[..path.iter().position(|b| *b == 0).unwrap_or(path.len())];
            // Unnamed and abstract endpoints are refused; a named endpoint
            // must be one of the policy's exact paths.
            let Some(allowed) = endpoints
                .unix
                .iter()
                .find(|p| !path.is_empty() && p.as_os_str().as_bytes() == path)
            else {
                return libc::EACCES;
            };
            connect_unix(&socket, allowed)
        }
        libc::AF_INET | libc::AF_INET6 => {
            if family == libc::AF_UNSPEC {
                // Dissolves a datagram association; reaches nothing.
                return connect_raw(&socket, &copied);
            }
            if family != domain {
                return libc::EAFNOSUPPORT;
            }
            let Some((port, loopback)) = inet_endpoint(&copied, domain) else {
                return libc::EINVAL;
            };
            let allowed = match kind {
                libc::SOCK_STREAM => {
                    endpoints.tcp_any.contains(&port)
                        || loopback && endpoints.tcp_loopback.contains(&port)
                }
                libc::SOCK_DGRAM => endpoints.udp_dns && port == 53,
                _ => false,
            };
            if !allowed {
                return libc::EACCES;
            }
            connect_raw(&socket, &copied)
        }
        _ => libc::EAFNOSUPPORT,
    }
}

fn thread_group(tid: u32) -> Option<libc::pid_t> {
    let text = fs::read_to_string(format!("/proc/{tid}/status")).ok()?;
    text.lines()
        .find_map(|line| line.strip_prefix("Tgid:"))
        .and_then(|value| value.trim().parse().ok())
}

fn socket_option(socket: &OwnedFd, option: libc::c_int) -> Option<i32> {
    let mut value: libc::c_int = 0;
    let mut length = mem::size_of::<libc::c_int>() as libc::socklen_t;
    // SAFETY: value/length are valid out-parameters for an int option.
    let result = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            option,
            (&mut value as *mut libc::c_int).cast(),
            &mut length,
        )
    };
    (result == 0).then_some(value)
}

fn inet_endpoint(address: &[u8], domain: i32) -> Option<(u16, bool)> {
    if domain == libc::AF_INET && address.len() >= mem::size_of::<libc::sockaddr_in>() {
        let port = u16::from_be_bytes([address[2], address[3]]);
        let ip = Ipv4Addr::new(address[4], address[5], address[6], address[7]);
        return Some((port, ip.is_loopback()));
    }
    if domain == libc::AF_INET6 && address.len() >= mem::size_of::<libc::sockaddr_in6>() {
        let port = u16::from_be_bytes([address[2], address[3]]);
        let mut bytes = [0u8; 16];
        bytes.copy_from_slice(&address[8..24]);
        let ip = Ipv6Addr::from(bytes);
        let loopback = ip.is_loopback() || ip.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback());
        return Some((port, loopback));
    }
    None
}

fn connect_raw(socket: &OwnedFd, address: &[u8]) -> i32 {
    // SAFETY: address is our own copy of the program's sockaddr bytes.
    let result = unsafe {
        libc::connect(
            socket.as_raw_fd(),
            address.as_ptr().cast(),
            address.len() as libc::socklen_t,
        )
    };
    if result == 0 {
        0
    } else {
        last_errno()
    }
}

fn connect_unix(socket: &OwnedFd, path: &Path) -> i32 {
    // SAFETY: zeroed sockaddr_un is valid; the path is copied in below.
    let mut address: libc::sockaddr_un = unsafe { mem::zeroed() };
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let bytes = path.as_os_str().as_bytes();
    if bytes.len() >= address.sun_path.len() {
        return libc::ENAMETOOLONG;
    }
    for (slot, byte) in address.sun_path.iter_mut().zip(bytes) {
        *slot = *byte as libc::c_char;
    }
    let length = mem::size_of::<libc::sa_family_t>() + bytes.len() + 1;
    // SAFETY: address is a valid sockaddr_un of the given length.
    let result = unsafe {
        libc::connect(
            socket.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            length as libc::socklen_t,
        )
    };
    if result == 0 {
        0
    } else {
        last_errno()
    }
}
