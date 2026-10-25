use crate::{
    input::{valid_username, Secret},
    phase, validate, Code, Request, Response,
};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

/// Tests inject tools that write only a task-owned root. The binary always uses
/// SystemTools and `/`; there is no command-line/environment override.
pub trait AccountTools: Send + Sync {
    fn create(&self, root: &Path, name: &str, display: &str) -> io::Result<()>;
    fn password(&self, root: &Path, name: &str, password: &[u8]) -> io::Result<()>;
    fn delete(&self, root: &Path, name: &str) -> io::Result<()>;
    fn nss_passwd(&self) -> io::Result<Option<String>> {
        Ok(None)
    }
    fn nss_name_taken(&self, _name: &str) -> io::Result<bool> {
        Ok(false)
    }
}
pub struct SystemTools;
fn command(executable: &str) -> Command {
    let mut c = Command::new(executable);
    c.env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    c
}
fn require_system_root(root: &Path) -> io::Result<()> {
    if root != Path::new("/") {
        return Err(io::Error::other("system tools require system root"));
    }
    Ok(())
}
fn status_ok(status: std::process::ExitStatus) -> io::Result<()> {
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other("account tool failed"))
    }
}
impl AccountTools for SystemTools {
    fn create(&self, root: &Path, name: &str, display: &str) -> io::Result<()> {
        require_system_root(root)?;
        status_ok(
            command("/usr/sbin/useradd")
                .args([
                    "-m",
                    "--no-log-init",
                    "-U",
                    "-G",
                    "sudo",
                    "-s",
                    "/bin/bash",
                    "-K",
                    "HOME_MODE=0750",
                    "-c",
                    display,
                    name,
                ])
                .status()?,
        )
    }
    fn password(&self, root: &Path, name: &str, password: &[u8]) -> io::Result<()> {
        require_system_root(root)?;
        // Explicit crypt method bypasses PAM strength rejection: weak passwords
        // are allowed by owner policy. No password in argv, env or tool output.
        let mut child = command("/usr/sbin/chpasswd")
            .args(["--crypt-method", "YESCRYPT"])
            .stdin(Stdio::piped())
            .spawn()?;
        let sent = (|| {
            let mut input = child
                .stdin
                .take()
                .ok_or_else(|| io::Error::other("missing stdin"))?;
            input.write_all(name.as_bytes())?;
            input.write_all(b":")?;
            input.write_all(password)?;
            input.write_all(b"\n")
        })();
        // Always reap, including broken pipe. No child outlives the transaction.
        let status = child.wait();
        sent?;
        status_ok(status?)
    }
    fn delete(&self, root: &Path, name: &str) -> io::Result<()> {
        require_system_root(root)?;
        status_ok(command("/usr/sbin/userdel").args(["-r", name]).status()?)
    }
    fn nss_passwd(&self) -> io::Result<Option<String>> {
        let output = command("/usr/bin/getent")
            .arg("passwd")
            .stdout(Stdio::piped())
            .output()?;
        status_ok(output.status)?;
        String::from_utf8(output.stdout)
            .map(Some)
            .map_err(io::Error::other)
    }
    fn nss_name_taken(&self, name: &str) -> io::Result<bool> {
        for database in ["passwd", "group"] {
            let status = command("/usr/bin/getent").args([database, name]).status()?;
            match status.code() {
                Some(0) => return Ok(true),
                Some(2) => {}
                _ => return Err(io::Error::other("NSS lookup failed")),
            }
        }
        Ok(false)
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    version: u32,
    username: String,
    timestamp: u64,
}
impl Journal {
    fn new(name: &str) -> Self {
        Self {
            version: 1,
            username: name.into(),
            timestamp: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        }
    }
}
pub struct Engine<T> {
    pub root: PathBuf,
    pub tools: T,
}
struct Lock(File);
impl Drop for Lock {
    fn drop(&mut self) {
        // SAFETY: the file is live until after Drop; unlocking has no memory effects.
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
fn internal<T>(_: T) -> Code {
    Code::InternalRolledBack
}
fn exists(path: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}
impl<T: AccountTools> Engine<T> {
    fn state(&self, name: &str) -> PathBuf {
        self.root.join("var/lib/ditto/firstboot").join(name)
    }
    fn lock(&self) -> io::Result<Lock> {
        let dir = self.state("");
        // Check every ancestor inside the bound root before creating state.
        // A private final directory is insufficient if its parent can be renamed.
        // SAFETY: geteuid has no preconditions.
        let uid = unsafe { libc::geteuid() };
        for relative in ["", "var", "var/lib", "var/lib/ditto"] {
            let path = self.root.join(relative);
            if relative == "var/lib/ditto" && !exists(&path)? {
                fs::DirBuilder::new().mode(0o755).create(&path)?;
            }
            let meta = fs::symlink_metadata(path)?;
            if !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o022 != 0 {
                return Err(io::Error::other("unsafe state ancestor"));
            }
        }
        if !exists(&dir)? {
            fs::DirBuilder::new().mode(0o700).create(&dir)?;
        }
        let meta = fs::symlink_metadata(&dir)?;
        if !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
            return Err(io::Error::other("unsafe state directory"));
        }
        let f = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(self.state("lock"))?;
        loop {
            // SAFETY: f is a live descriptor; flock is process-safe on this file.
            if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) } == 0 {
                break;
            }
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted {
                return Err(e);
            }
        }
        Ok(Lock(f))
    }
    fn sync_dir(&self) -> io::Result<()> {
        File::open(self.state(""))?.sync_all()
    }
    fn atomic_journal(&self, name: &str, journal: &Journal) -> io::Result<()> {
        let tmp = self.state(&format!("{name}.tmp"));
        let mut f = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&tmp)?;
        serde_json::to_writer(&mut f, journal)?;
        f.write_all(b"\n")?;
        f.sync_all()?;
        fs::rename(tmp, self.state(name))?;
        self.sync_dir()
    }
    fn remove_state(&self, name: &str) -> io::Result<()> {
        match fs::remove_file(self.state(name)) {
            Ok(()) => self.sync_dir(),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e),
        }
    }
    pub fn handle(&self, request: &Request, log: &mut dyn Write) -> Response {
        match self.transact(request, log) {
            Ok(weak_password) => {
                phase(log, "commit", "ok");
                Response::Success {
                    ok: true,
                    weak_password,
                }
            }
            Err(code) => {
                phase(log, "finish", code.as_str());
                Response::error(code)
            }
        }
    }
    fn transact(&self, request: &Request, log: &mut dyn Write) -> Result<bool, Code> {
        let _lock = self.lock().map_err(internal)?;
        self.recover_locked(log)?;
        if exists(&self.state("account-created")).map_err(internal)? {
            return Err(Code::AlreadyProvisioned);
        }
        let (min, max) =
            uid_range(&fs::read_to_string(self.root.join("etc/login.defs")).map_err(internal)?)
                .map_err(internal)?;
        let passwd = fs::read_to_string(self.root.join("etc/passwd")).map_err(internal)?;
        if human_exists(&passwd, min, max).map_err(internal)? {
            return Err(Code::AlreadyProvisioned);
        }
        if let Some(nss) = self.tools.nss_passwd().map_err(internal)? {
            if human_exists(&nss, min, max).map_err(internal)? {
                return Err(Code::AlreadyProvisioned);
            }
        }
        let weak = validate(request)?;
        for file in ["passwd", "shadow", "group", "gshadow", "subuid", "subgid"] {
            if named_entry(
                &self.read_optional(file).map_err(internal)?,
                &request.username,
            ) {
                return Err(Code::UsernameTaken);
            }
        }
        if self
            .tools
            .nss_name_taken(&request.username)
            .map_err(internal)?
            || exists(&self.root.join("home").join(&request.username)).map_err(internal)?
            || exists(&self.root.join("var/mail").join(&request.username)).map_err(internal)?
        {
            return Err(Code::UsernameTaken);
        }
        let journal = Journal::new(&request.username);
        phase(log, "prepare", "begin");
        if self.atomic_journal("pending", &journal).is_err() {
            // useradd has not run: never delete any account on preparation error.
            if self.remove_state("pending").is_err() {
                return Err(Code::InternalRollbackFailed);
            }
            return Err(Code::InternalRolledBack);
        }
        let applied = (|| -> io::Result<()> {
            phase(log, "useradd", "begin");
            self.tools
                .create(&self.root, &request.username, &request.display_name)?;
            phase(log, "chpasswd", "begin");
            self.tools
                .password(&self.root, &request.username, request.password.as_bytes())?;
            phase(log, "readback", "begin");
            self.verify_created(request, min, max)?;
            self.sync_account_files(&request.username)?;
            phase(log, "marker", "begin");
            self.atomic_journal("account-created", &journal)
        })();
        if applied.is_err() {
            return Err(self.rollback(&request.username, log));
        }
        // The durable marker is the commit point. Failure to unlink pending must
        // not delete a committed account; recovery gives the marker precedence.
        if self.remove_state("pending").is_err() {
            phase(log, "pending_cleanup", "deferred");
        }
        Ok(weak)
    }
    fn sync_databases(&self) -> io::Result<()> {
        for file in ["passwd", "shadow", "group", "gshadow", "subuid", "subgid"] {
            let path = self.root.join("etc").join(file);
            if exists(&path)? {
                File::open(path)?.sync_all()?;
            }
        }
        for relative in ["etc", "home", "var/mail"] {
            File::open(self.root.join(relative))?.sync_all()?;
        }
        Ok(())
    }
    fn sync_account_files(&self, name: &str) -> io::Result<()> {
        self.sync_databases()?;
        File::open(self.root.join("home").join(name))?.sync_all()?;
        let mail = self.root.join("var/mail").join(name);
        if exists(&mail)? {
            File::open(mail)?.sync_all()?;
        }
        Ok(())
    }
    fn read_optional(&self, name: &str) -> io::Result<String> {
        match fs::read_to_string(self.root.join("etc").join(name)) {
            Ok(s) => Ok(s),
            Err(e)
                if e.kind() == io::ErrorKind::NotFound && matches!(name, "subuid" | "subgid") =>
            {
                Ok(String::new())
            }
            Err(e) => Err(e),
        }
    }
    fn verify_created(&self, request: &Request, min: u32, max: u32) -> io::Result<()> {
        let text = self.read_optional("passwd")?;
        let entries: Vec<_> = text
            .lines()
            .filter(|l| l.split(':').next() == Some(&request.username))
            .collect();
        if entries.len() != 1 {
            return Err(io::Error::other("passwd readback mismatch"));
        }
        let p: Vec<_> = entries[0].split(':').collect();
        if p.len() != 7 {
            return Err(io::Error::other("invalid passwd entry"));
        }
        let uid: u32 = p[2].parse().map_err(io::Error::other)?;
        let gid: u32 = p[3].parse().map_err(io::Error::other)?;
        let home = format!("/home/{}", request.username);
        if p[1] != "x"
            || !(min..=max).contains(&uid)
            || p[4] != request.display_name
            || p[5] != home
            || p[6] != "/bin/bash"
        {
            return Err(io::Error::other("passwd readback mismatch"));
        }
        let shadow = Secret::from(self.read_optional("shadow")?);
        let hashes: Vec<_> = shadow
            .as_str()
            .map_err(io::Error::other)?
            .lines()
            .filter(|l| l.split(':').next() == Some(&request.username))
            .collect();
        if hashes.len() != 1
            || !hashes[0]
                .split(':')
                .nth(1)
                .is_some_and(|h| h.starts_with("$y$") && h.len() > 3)
        {
            return Err(io::Error::other("shadow readback mismatch"));
        }
        let groups = self.read_optional("group")?;
        let primary = groups.lines().any(|l| {
            let f: Vec<_> = l.split(':').collect();
            f.len() == 4 && f[0] == request.username && f[2].parse::<u32>() == Ok(gid)
        });
        let sudo = groups.lines().any(|l| {
            let f: Vec<_> = l.split(':').collect();
            f.len() == 4
                && f[0] == "sudo"
                && (f[2].parse::<u32>() == Ok(gid)
                    || f[3].split(',').any(|n| n == request.username))
        });
        let meta = fs::symlink_metadata(self.root.join(home.trim_start_matches('/')))?;
        // Fake roots run without chown privilege; production additionally checks owner.
        let owner = self.root != Path::new("/") || (meta.uid() == uid && meta.gid() == gid);
        if !primary || !sudo || !meta.is_dir() || meta.mode() & 0o7777 != 0o750 || !owner {
            return Err(io::Error::other("group or home readback mismatch"));
        }
        Ok(())
    }
    fn removed(&self, name: &str) -> io::Result<bool> {
        for file in ["passwd", "shadow", "group", "gshadow", "subuid", "subgid"] {
            let text = Secret::from(self.read_optional(file)?);
            let text = text.as_str().map_err(io::Error::other)?;
            if named_entry(text, name) {
                return Ok(false);
            }
            if matches!(file, "group" | "gshadow")
                && text.lines().any(|l| {
                    l.split(':')
                        .skip(2)
                        .any(|f| f.split(',').any(|n| n == name))
                })
            {
                return Ok(false);
            }
        }
        Ok(!exists(&self.root.join("home").join(name))?
            && !exists(&self.root.join("var/mail").join(name))?)
    }
    fn rollback(&self, name: &str, log: &mut dyn Write) -> Code {
        phase(log, "rollback", "begin");
        // Remove even a renamed marker whose directory fsync failed. Keep pending
        // until all state is absent, so interruption remains recoverable.
        if self.remove_state("account-created").is_err() {
            return Code::InternalRollbackFailed;
        }
        let _ = self.tools.delete(&self.root, name);
        let code = if self.removed(name).unwrap_or(false)
            && self.sync_databases().is_ok()
            && self.remove_state("pending").is_ok()
        {
            Code::InternalRolledBack
        } else {
            Code::InternalRollbackFailed
        };
        phase(log, "rollback", code.as_str());
        code
    }
    pub fn recover(&self, log: &mut dyn Write) -> Result<(), Code> {
        let _lock = self.lock().map_err(|_| Code::InternalRollbackFailed)?;
        self.recover_locked(log)
    }
    fn recover_locked(&self, log: &mut dyn Write) -> Result<(), Code> {
        if exists(&self.state("account-created")).map_err(|_| Code::InternalRollbackFailed)? {
            return Ok(());
        }
        if !exists(&self.state("pending")).map_err(|_| Code::InternalRollbackFailed)? {
            return Ok(());
        }
        phase(log, "recovery", "begin");
        let f = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(self.state("pending"))
            .map_err(|_| Code::InternalRollbackFailed)?;
        let mut bytes = Vec::new();
        f.take(1025)
            .read_to_end(&mut bytes)
            .map_err(|_| Code::InternalRollbackFailed)?;
        if bytes.len() > 1024 {
            return Err(Code::InternalRollbackFailed);
        }
        let journal: Journal =
            serde_json::from_slice(&bytes).map_err(|_| Code::InternalRollbackFailed)?;
        if journal.version != 1 || !valid_username(&journal.username) {
            return Err(Code::InternalRollbackFailed);
        }
        match self.rollback(&journal.username, log) {
            Code::InternalRolledBack => Ok(()),
            _ => Err(Code::InternalRollbackFailed),
        }
    }
}
fn named_entry(text: &str, name: &str) -> bool {
    text.lines().any(|l| l.split(':').next() == Some(name))
}
fn uid_range(text: &str) -> io::Result<(u32, u32)> {
    let mut min = None;
    let mut max = None;
    for line in text.lines() {
        let mut f = line
            .split('#')
            .next()
            .unwrap_or_default()
            .split_whitespace();
        match f.next() {
            Some("UID_MIN") => {
                if min.is_some() {
                    return Err(io::Error::other("duplicate UID_MIN"));
                }
                min = Some(
                    f.next()
                        .ok_or_else(|| io::Error::other("missing UID_MIN"))?
                        .parse::<u32>()
                        .map_err(io::Error::other)?,
                );
            }
            Some("UID_MAX") => {
                if max.is_some() {
                    return Err(io::Error::other("duplicate UID_MAX"));
                }
                max = Some(
                    f.next()
                        .ok_or_else(|| io::Error::other("missing UID_MAX"))?
                        .parse::<u32>()
                        .map_err(io::Error::other)?,
                );
            }
            _ => {}
        }
    }
    match (min, max) {
        (Some(a), Some(b)) if a > 0 && a <= b => Ok((a, b)),
        _ => Err(io::Error::other("invalid human UID range")),
    }
}
fn human_exists(text: &str, min: u32, max: u32) -> io::Result<bool> {
    let mut found = false;
    for line in text.lines().filter(|l| !l.is_empty()) {
        let uid = line
            .split(':')
            .nth(2)
            .ok_or_else(|| io::Error::other("invalid passwd database"))?
            .parse::<u32>()
            .map_err(io::Error::other)?;
        found |= (min..=max).contains(&uid);
    }
    Ok(found)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn uid_range_fails_closed_and_boundaries_are_inclusive() {
        for s in [
            "",
            "UID_MIN 0\nUID_MAX 60000",
            "UID_MIN 2000\nUID_MAX 1000",
            "UID_MIN x\nUID_MAX 60000",
            "UID_MIN 1000\nUID_MIN 1000\nUID_MAX 60000",
        ] {
            assert!(uid_range(s).is_err());
        }
        assert_eq!(
            uid_range("# comment\nUID_MIN 1000 # min\nUID_MAX 60000").unwrap(),
            (1000, 60000)
        );
        assert!(human_exists("a:x:1000:1::/:/bin/bash", 1000, 60000).unwrap());
        assert!(human_exists("a:x:60000:1::/:/bin/bash", 1000, 60000).unwrap());
        assert!(!human_exists("a:x:999:1::/:/bin/false", 1000, 60000).unwrap());
        assert!(human_exists("malformed", 1000, 60000).is_err());
    }
}
