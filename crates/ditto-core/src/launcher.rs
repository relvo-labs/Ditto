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

use ditto_core::identity::{fresh_token, ClientIdentity, IdentityRegistry};
use ditto_protocol::{
    LAUNCHER_KIND_ENV, LAUNCHER_SOCKET_ENV, LAUNCHER_TOKEN_FD, LAUNCHER_TOKEN_FD_ENV,
    LAUNCHER_VERSION_ENV,
};

const TOKEN_FD: RawFd = LAUNCHER_TOKEN_FD;

/// `<kind> <version> <executable> [args...]`, whitespace separated.
struct Specification {
    kind: String,
    version: String,
    executable: PathBuf,
    arguments: Vec<OsString>,
}

fn parse(specification: &str) -> io::Result<Specification> {
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

/// Spawn the client, bind its PID, then hand over the token. The order matters:
/// nothing usable reaches the client before Core knows which process may use it.
pub fn launch(
    registry: &Arc<IdentityRegistry>,
    specification: &str,
    socket: &Path,
) -> io::Result<Child> {
    let parsed = parse(specification)?;
    let executable = parsed.executable.canonicalize()?;
    let (mut launcher_end, client_end) = UnixStream::pair()?;
    let client_fd: OwnedFd = client_end.into();
    let inherited = client_fd.as_raw_fd();

    let mut command = Command::new(&executable);
    command
        .args(&parsed.arguments)
        .env_remove("DITTO_DEV_TOKEN")
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
