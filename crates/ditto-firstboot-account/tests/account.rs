use ditto_firstboot_account::{validate, AccountTools, Code, Engine, Request, Response};
use std::{
    fs,
    io::{self, Read, Write},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Barrier,
    },
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "ditto-212-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        for d in ["etc", "home", "var/mail", "var/lib/ditto/firstboot"] {
            fs::create_dir_all(p.join(d)).unwrap();
        }
        for (f,s) in [("passwd","root:x:0:0:root:/root:/bin/bash\n_greetd:x:995:995::/var/lib/greetd:/usr/sbin/nologin\n"),("shadow","root:!:0:0:99999:7:::\n"),("group","root:x:0:\nsudo:x:27:\n"),("gshadow","root:!::\nsudo:!::\n"),("subuid",""),("subgid",""),("login.defs","UID_MIN 1000\nUID_MAX 60000\n")] { fs::write(p.join("etc").join(f),s).unwrap(); }
        for relative in ["", "var", "var/lib", "var/lib/ditto"] {
            fs::set_permissions(p.join(relative), fs::Permissions::from_mode(0o755)).unwrap();
        }
        fs::set_permissions(
            p.join("var/lib/ditto/firstboot"),
            fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        Self(p)
    }
    fn state(&self, name: &str) -> PathBuf {
        self.0.join("var/lib/ditto/firstboot").join(name)
    }
    fn engine(&self, fault: &'static str) -> Engine<Fake> {
        Engine {
            root: self.0.clone(),
            tools: Fake(fault),
        }
    }
    fn consistent(&self, present: bool) {
        let passwd = fs::read_to_string(self.0.join("etc/passwd")).unwrap();
        let shadow = fs::read_to_string(self.0.join("etc/shadow")).unwrap();
        let group = fs::read_to_string(self.0.join("etc/group")).unwrap();
        assert_eq!(passwd.lines().any(|s| s.starts_with("alice:")), present);
        assert_eq!(shadow.lines().any(|s| s.starts_with("alice:$y$")), present);
        assert_eq!(group.lines().any(|s| s.starts_with("alice:")), present);
        assert_eq!(self.0.join("home/alice").exists(), present);
        assert_eq!(self.state("account-created").is_file(), present);
        assert!(!self.state("pending").exists());
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
struct Fake(&'static str);
fn append(root: &Path, file: &str, line: &str) {
    let mut f = fs::OpenOptions::new()
        .append(true)
        .open(root.join("etc").join(file))
        .unwrap();
    f.write_all(line.as_bytes()).unwrap();
}
fn fail() -> io::Result<()> {
    Err(io::Error::other("injected"))
}
impl AccountTools for Fake {
    fn create(&self, root: &Path, name: &str, display: &str) -> io::Result<()> {
        append(
            root,
            "passwd",
            &format!("{name}:x:1000:1000:{display}:/home/{name}:/bin/bash\n"),
        );
        append(root, "shadow", &format!("{name}:!:0:0:99999:7:::\n"));
        append(root, "group", &format!("{name}:x:1000:\n"));
        append(root, "gshadow", &format!("{name}:!::\n"));
        append(root, "subuid", &format!("{name}:100000:65536\n"));
        append(root, "subgid", &format!("{name}:100000:65536\n"));
        let group = fs::read_to_string(root.join("etc/group"))?
            .replace("sudo:x:27:", &format!("sudo:x:27:{name}"));
        fs::write(root.join("etc/group"), group)?;
        fs::create_dir(root.join("home").join(name))?;
        fs::set_permissions(
            root.join("home").join(name),
            fs::Permissions::from_mode(0o750),
        )?;
        if self.0 == "crash" {
            std::process::exit(73);
        }
        if self.0 == "useradd" {
            return fail();
        }
        Ok(())
    }
    fn password(&self, root: &Path, name: &str, _: &[u8]) -> io::Result<()> {
        if self.0 == "chpasswd" {
            return fail();
        }
        let hash = if self.0 == "readback" {
            "$6$incorrect"
        } else {
            "$y$test$hash"
        };
        let shadow = fs::read_to_string(root.join("etc/shadow"))?
            .replace(&format!("{name}:!:"), &format!("{name}:{hash}:"));
        fs::write(root.join("etc/shadow"), shadow)?;
        if self.0 == "marker" {
            fs::create_dir(root.join("var/lib/ditto/firstboot/account-created.tmp"))?;
        }
        Ok(())
    }
    fn delete(&self, root: &Path, name: &str) -> io::Result<()> {
        if self.0 == "delete" {
            return fail();
        }
        for file in ["passwd", "shadow", "group", "gshadow", "subuid", "subgid"] {
            let text = fs::read_to_string(root.join("etc").join(file))?;
            let text = text
                .lines()
                .filter(|s| !s.starts_with(&format!("{name}:")))
                .map(|s| {
                    if s.starts_with("sudo:") {
                        s.replace(name, "")
                    } else {
                        s.into()
                    }
                })
                .collect::<Vec<_>>()
                .join("\n")
                + "\n";
            fs::write(root.join("etc").join(file), text)?;
        }
        if root.join("home").join(name).exists() {
            fs::remove_dir_all(root.join("home").join(name))?;
        }
        Ok(())
    }
}
fn request() -> Request {
    serde_json::from_str(
        r#"{"display_name":"小愛","username":"alice","password":"Unique-Test-Secret!42"}"#,
    )
    .unwrap()
}
fn error(code: Code) -> Response {
    Response::Error {
        ok: false,
        error: code,
    }
}
#[test]
fn validation_table() {
    for username in [
        "Hsiao",
        "1abc",
        "a$",
        "",
        "a_b",
        "root",
        "sudo",
        "ditto",
        "_greetd",
        "aabcdefghijklmnopqrstuvwxyz123456",
    ] {
        let mut r = request();
        r.username = username.into();
        assert_eq!(validate(&r), Err(Code::InvalidUsername), "{username}");
    }
    for username in ["a", "a-b0", "alice", "abcdefghijklmnopqrstuvwxyz12345"] {
        let mut r = request();
        r.username = username.into();
        assert!(validate(&r).is_ok(), "{username}");
    }
    for display in ["a:b", "a,b", "a=b", "a\nb", "a\0b", "a\rb", "a\tb"] {
        let mut r = request();
        r.display_name = display.into();
        assert_eq!(validate(&r), Err(Code::DisplayNameInvalid));
    }
    let mut r = request();
    r.display_name = "名".repeat(129);
    assert_eq!(validate(&r), Err(Code::DisplayNameInvalid));
    for p in ["1234567", "一二三四五六七"] {
        let mut r = request();
        r.password = p.into();
        assert_eq!(validate(&r), Err(Code::PasswordTooShort));
    }
    for p in ["12345678", "一二三四五六七八", "aaaaaaaa"] {
        let mut r = request();
        r.password = p.into();
        assert_eq!(validate(&r), Ok(true));
    }
    for p in ["1234567\0x", "1234567\nx", "1234567\rx"] {
        let mut r = request();
        r.password = p.into();
        assert_eq!(validate(&r), Err(Code::PasswordInvalid));
    }
    let mut r = request();
    r.password = "x".repeat(1025).into();
    assert_eq!(validate(&r), Err(Code::PasswordInvalid));
    assert_eq!(validate(&request()), Ok(false));
}
#[test]
fn transaction_faults_and_success_are_read_back() {
    for fault in ["useradd", "chpasswd", "readback", "marker", ""] {
        let root = Root::new();
        let response = root.engine(fault).handle(&request(), &mut Vec::new());
        if fault.is_empty() {
            assert!(matches!(response, Response::Success { .. }));
        } else {
            assert_eq!(response, error(Code::InternalRolledBack), "{fault}");
        }
        root.consistent(fault.is_empty());
    }
}
#[test]
fn recovery_rolls_back_pending_before_new_attempt() {
    let root = Root::new();
    Fake("").create(&root.0, "alice", "").unwrap();
    fs::write(
        root.state("pending"),
        r#"{"version":1,"username":"alice","timestamp":1}"#,
    )
    .unwrap();
    root.engine("").recover(&mut Vec::new()).unwrap();
    root.consistent(false);
    assert!(matches!(
        root.engine("").handle(&request(), &mut Vec::new()),
        Response::Success { .. }
    ));
    root.consistent(true);
}
#[test]
fn rollback_failure_keeps_journal_for_recovery() {
    let root = Root::new();
    Fake("").create(&root.0, "alice", "").unwrap();
    fs::write(
        root.state("pending"),
        r#"{"version":1,"username":"alice","timestamp":1}"#,
    )
    .unwrap();
    assert_eq!(
        root.engine("delete").recover(&mut Vec::new()),
        Err(Code::InternalRollbackFailed)
    );
    assert!(root.state("pending").exists());
    root.engine("").recover(&mut Vec::new()).unwrap();
    root.consistent(false);
}
fn protocol(root: &Root, body: &[u8], expected_uid: u32) -> (Response, Vec<u8>) {
    let engine = root.engine("");
    let (mut client, server) = UnixStream::pair().unwrap();
    std::thread::scope(|s| {
        let h = s.spawn(move || {
            let mut logs = Vec::new();
            engine.serve(server, expected_uid, &mut logs).unwrap();
            logs
        });
        client.write_all(body).unwrap();
        client.shutdown(std::net::Shutdown::Write).unwrap();
        let mut bytes = Vec::new();
        loop {
            let mut b = [0];
            client.read_exact(&mut b).unwrap();
            bytes.push(b[0]);
            if b[0] == b'\n' {
                break;
            }
        }
        let response = serde_json::from_slice(&bytes).unwrap();
        (response, h.join().unwrap())
    })
}
#[test]
fn protocol_limits_identity_and_malformed_json() {
    let uid = unsafe { libc::geteuid() };
    for body in [
        vec![b'x'; 4097],
        b"{bad json}".to_vec(),
        vec![0xff],
        br#"{"display_name":"","username":"alice","password":"12345678","uid":0}"#.to_vec(),
    ] {
        let root = Root::new();
        assert_eq!(
            protocol(&root, &body, uid).0,
            error(Code::InternalRolledBack)
        );
        root.consistent(false);
    }
    let root = Root::new();
    assert_eq!(
        protocol(&root, b"{}", uid.wrapping_add(1)).0,
        error(Code::Unauthorized)
    );
    root.consistent(false);
}
#[test]
fn already_provisioned_and_name_collisions() {
    let root = Root::new();
    append(&root.0, "passwd", "bob:x:1000:1000::/home/bob:/bin/bash\n");
    assert_eq!(
        root.engine("").handle(&request(), &mut Vec::new()),
        error(Code::AlreadyProvisioned)
    );
    for file in ["passwd", "group"] {
        let root = Root::new();
        append(&root.0, file, "alice:x:900:900::::\n");
        assert_eq!(
            root.engine("").handle(&request(), &mut Vec::new()),
            error(Code::UsernameTaken)
        );
    }
    let root = Root::new();
    fs::write(root.state("account-created"), "{}").unwrap();
    assert_eq!(
        protocol(
            &root,
            br#"{"display_name":"","username":"alice","password":"12345678"}"#,
            unsafe { libc::geteuid() }
        )
        .0,
        error(Code::AlreadyProvisioned)
    );
}
#[test]
fn concurrent_requests_exactly_one_success() {
    let root = Root::new();
    let barrier = Arc::new(Barrier::new(2));
    std::thread::scope(|s| {
        let mut handles = Vec::new();
        let mut clients = Vec::new();
        for _ in 0..2 {
            let b = barrier.clone();
            let engine = root.engine("");
            let (mut client, server) = UnixStream::pair().unwrap();
            client.write_all("{\"display_name\":\"小愛\",\"username\":\"alice\",\"password\":\"Unique-Test-Secret!42\"}\n".as_bytes()).unwrap();
            clients.push(client);
            handles.push(s.spawn(move || {
                b.wait();
                engine
                    .serve(server, unsafe { libc::geteuid() }, &mut Vec::new())
                    .unwrap();
            }));
        }
        let responses = clients
            .into_iter()
            .map(|mut client| {
                let mut bytes = Vec::new();
                loop {
                    let mut b = [0];
                    client.read_exact(&mut b).unwrap();
                    bytes.push(b[0]);
                    if b[0] == b'\n' {
                        break;
                    }
                }
                serde_json::from_slice::<Response>(&bytes).unwrap()
            })
            .collect::<Vec<_>>();
        for handle in handles {
            handle.join().unwrap();
        }
        assert_eq!(
            responses
                .iter()
                .filter(|r| matches!(r, Response::Success { .. }))
                .count(),
            1
        );
        assert!(responses.contains(&error(Code::AlreadyProvisioned)));
    });
    root.consistent(true);
}
#[test]
fn logs_never_contain_password_or_display_name() {
    let root = Root::new();
    let (response, logs) = protocol(
        &root,
        br#"{"display_name":"private-name","username":"alice","password":"Unique-Test-Secret!42"}"#,
        unsafe { libc::geteuid() },
    );
    assert!(matches!(response, Response::Success { .. }));
    let text = String::from_utf8(logs).unwrap();
    assert!(!text.is_empty());
    assert!(!text.contains("Unique-Test-Secret!42"));
    assert!(!text.contains("private-name"));
    assert!(!text.contains("alice"));
}

#[test]
fn yescrypt_password_byte_cap_and_unicode_boundary() {
    let mut r = request();
    r.password = "a".repeat(511).into();
    assert!(validate(&r).is_ok());
    r.password = "a".repeat(512).into();
    assert_eq!(validate(&r), Err(Code::PasswordInvalid));
    r.password = "名".repeat(171).into();
    assert_eq!(validate(&r), Err(Code::PasswordInvalid));
    r.display_name.clear();
    r.password = "12345678".into();
    assert_eq!(validate(&r), Ok(true));
}
#[test]
fn recovery_does_not_remove_committed_account() {
    let root = Root::new();
    assert!(matches!(
        root.engine("").handle(&request(), &mut Vec::new()),
        Response::Success { .. }
    ));
    fs::write(
        root.state("pending"),
        r#"{"version":1,"username":"alice","timestamp":1}"#,
    )
    .unwrap();
    root.engine("").recover(&mut Vec::new()).unwrap();
    assert!(fs::read_to_string(root.0.join("etc/passwd"))
        .unwrap()
        .contains("alice:"));
    assert!(root.state("account-created").is_file());
}
#[test]
fn malformed_recovery_and_preexisting_home_fail_closed() {
    for journal in [
        r#"{"version":1,"username":"root","timestamp":1}"#,
        r#"{"version":2,"username":"alice","timestamp":1}"#,
        "{bad}",
    ] {
        let root = Root::new();
        fs::write(root.state("pending"), journal).unwrap();
        assert_eq!(
            root.engine("").recover(&mut Vec::new()),
            Err(Code::InternalRollbackFailed)
        );
        assert!(fs::read_to_string(root.0.join("etc/passwd"))
            .unwrap()
            .contains("root:x:0:"));
        assert!(root.state("pending").is_file());
    }
    let root = Root::new();
    fs::create_dir(root.0.join("home/alice")).unwrap();
    fs::write(root.0.join("home/alice/keep"), "data").unwrap();
    assert_eq!(
        root.engine("").handle(&request(), &mut Vec::new()),
        error(Code::UsernameTaken)
    );
    assert_eq!(
        fs::read_to_string(root.0.join("home/alice/keep")).unwrap(),
        "data"
    );
}
#[test]
fn newline_frame_and_escaped_password_are_supported() {
    let root = Root::new();
    let (response,logs)=protocol(&root,br#"{"display_name":"\u5c0f\u611b","username":"alice","password":"\u4e00\u4e8c\u4e09\u56db\u4e94\u516d\u4e03\u516b"}
"#,unsafe {libc::geteuid()});
    assert_eq!(
        response,
        Response::Success {
            ok: true,
            weak_password: true
        }
    );
    root.consistent(true);
    assert!(!String::from_utf8(logs)
        .unwrap()
        .contains("一二三四五六七八"));
}
#[test]
fn log_scan_includes_failure_paths() {
    for fault in ["useradd", "chpasswd", "readback", "marker", ""] {
        let root = Root::new();
        let mut log = Vec::new();
        root.engine(fault).handle(&request(), &mut log);
        let text = String::from_utf8(log).unwrap();
        assert!(!text.contains("Unique-Test-Secret!42"));
        assert!(!text.contains("小愛"));
        assert!(text
            .lines()
            .all(|l| l.starts_with("phase=") && l.contains(" result=")));
    }
}

#[test]
fn crash_child() {
    if let Some(root) = std::env::var_os("DITTO_212_CRASH_ROOT") {
        let engine = Engine {
            root: root.into(),
            tools: Fake("crash"),
        };
        engine.handle(&request(), &mut Vec::new());
        panic!("crash injection did not terminate");
    }
}
#[test]
fn process_exit_after_useradd_recovers_from_durable_pending() {
    let root = Root::new();
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "crash_child", "--nocapture"])
        .env("DITTO_212_CRASH_ROOT", &root.0)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(73));
    assert!(root.state("pending").is_file());
    assert!(!root.state("account-created").exists());
    assert!(fs::read_to_string(root.0.join("etc/passwd"))
        .unwrap()
        .contains("alice:"));
    root.engine("").recover(&mut Vec::new()).unwrap();
    root.consistent(false);
}

#[test]
fn unsafe_state_ancestor_is_rejected_without_account_changes() {
    let root = Root::new();
    let parent = root.0.join("var/lib/ditto");
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(
        root.engine("").handle(&request(), &mut Vec::new()),
        error(Code::InternalRolledBack)
    );
    root.consistent(false);
}
#[test]
fn exact_four_kib_frame_is_accepted() {
    let root = Root::new();
    let mut bytes = br#"{"display_name":"","username":"alice","password":"12345678"}"#.to_vec();
    bytes.resize(4096, b' ');
    bytes.push(b'\n');
    assert_eq!(
        protocol(&root, &bytes, unsafe { libc::geteuid() }).0,
        Response::Success {
            ok: true,
            weak_password: true
        }
    );
    root.consistent(true);
}
