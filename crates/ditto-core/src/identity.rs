//! Controlled-launcher binding primitive. The current development server does
//! not use this registry yet; it becomes authoritative only when the session
//! launcher registers each spawned client and the socket handshake consumes it.

use std::{
    collections::HashMap,
    fs::File,
    io::{self, Read},
    path::PathBuf,
    sync::Mutex,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientIdentity {
    pub uid: u32,
    pub pid: u32,
    pub kind: String,
    pub version: String,
    pub executable: PathBuf,
}

/// 256 bits from the kernel CSPRNG; never derived from the client's own input.
pub fn fresh_token() -> io::Result<String> {
    let mut random = [0_u8; 32];
    File::open("/dev/urandom")?.read_exact(&mut random)?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

struct Pending {
    identity: ClientIdentity,
    expires_at: Instant,
}

pub struct IdentityRegistry {
    pending: Mutex<HashMap<String, Pending>>,
}

impl Default for IdentityRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl IdentityRegistry {
    pub fn new() -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
        }
    }

    /// Called only by the trusted launcher after it spawns a client. The token
    /// must already have been passed to the child over a private channel before
    /// it is allowed to connect; the launcher registers its PID before release.
    pub fn issue_for_spawned_client(&self, identity: ClientIdentity) -> io::Result<String> {
        let token = fresh_token()?;
        self.bind_issued_token(token.clone(), identity)?;
        Ok(token)
    }

    /// The launcher must hand the token to the child before the child's PID
    /// exists, so it generates the token itself and binds it once the child is
    /// spawned but still held before `exec`.
    pub fn bind_issued_token(&self, token: String, identity: ClientIdentity) -> io::Result<()> {
        if identity.pid == 0 || identity.kind.is_empty() || identity.version.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "incomplete client binding",
            ));
        }
        self.pending
            .lock()
            .expect("identity registry poisoned")
            .insert(
                token.clone(),
                Pending {
                    identity,
                    expires_at: Instant::now() + Duration::from_secs(30),
                },
            );
        Ok(())
    }

    /// Peer UID and PID must come from SO_PEERCRED, never from JSON params.
    /// The token is consumed once. A failed match does not consume a valid
    /// client's token, so another same-UID process cannot deny its launch.
    pub fn verify_once(
        &self,
        token: &str,
        peer_uid: u32,
        peer_pid: u32,
        kind: &str,
        version: &str,
    ) -> Result<ClientIdentity, &'static str> {
        let mut pending = self
            .pending
            .lock()
            .map_err(|_| "identity registry unavailable")?;
        pending.retain(|_, binding| binding.expires_at > Instant::now());
        let binding = pending.get(token).ok_or("unknown or expired token")?;
        let identity = &binding.identity;
        if identity.uid != peer_uid
            || identity.pid != peer_pid
            || identity.kind != kind
            || identity.version != version
        {
            return Err("peer does not match launcher binding");
        }
        let actual_executable = std::fs::read_link(format!("/proc/{peer_pid}/exe"))
            .map_err(|_| "peer executable unavailable")?;
        if actual_executable != identity.executable {
            return Err("peer executable does not match launcher binding");
        }
        Ok(pending.remove(token).expect("binding existed").identity)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn own_identity() -> ClientIdentity {
        ClientIdentity {
            // SAFETY: getuid has no memory preconditions.
            uid: unsafe { libc::getuid() },
            pid: std::process::id(),
            kind: "dittoctl".into(),
            version: "0.1.0".into(),
            executable: std::fs::read_link("/proc/self/exe").unwrap(),
        }
    }

    #[test]
    fn rejects_same_uid_wrong_pid_and_consumes_correct_binding_once() {
        let registry = IdentityRegistry::new();
        let expected = own_identity();
        let token = registry.issue_for_spawned_client(expected.clone()).unwrap();
        assert!(registry
            .verify_once(&token, expected.uid, expected.pid + 1, "dittoctl", "0.1.0")
            .is_err());
        assert_eq!(
            registry
                .verify_once(&token, expected.uid, expected.pid, "dittoctl", "0.1.0")
                .unwrap(),
            expected
        );
        assert!(registry
            .verify_once(&token, expected.uid, expected.pid, "dittoctl", "0.1.0")
            .is_err());
    }

    #[test]
    fn self_declared_kind_cannot_override_binding() {
        let registry = IdentityRegistry::new();
        let expected = own_identity();
        let token = registry.issue_for_spawned_client(expected.clone()).unwrap();
        assert!(registry
            .verify_once(
                &token,
                expected.uid,
                expected.pid,
                "privileged-plugin",
                "0.1.0"
            )
            .is_err());
    }
}
