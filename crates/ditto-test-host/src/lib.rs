//! G3 infrastructure diagnostics, deliberately separate from the frozen G2
//! protocol and Core. These reports attest to `diagnostic-v1`, NOT to the
//! as-yet-unimplemented generated-code execution/activation policy.
use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path};

pub const POLICY: &str = "diagnostic-v1";
pub const MEMORY_MAX: u64 = 512 * 1024 * 1024;
pub const TASKS_MAX: u64 = 64;
pub const DEFAULT_DEADLINE_MS: u64 = 30_000;
pub const MAX_DEADLINE_MS: u64 = 120_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Enforcement {
    Full,
    Partial,
    Unavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceEvidence {
    pub cgroup: String,
    pub memory_max: String,
    pub memory_swap_max: String,
    pub cpu_max: String,
    pub pids_max: String,
}

impl ResourceEvidence {
    pub fn read() -> io::Result<Self> {
        let process = fs::read_to_string("/proc/self/cgroup")?;
        let cgroup = process
            .lines()
            .find_map(|l| l.strip_prefix("0::"))
            .filter(|p| p.starts_with('/') && !p.split('/').any(|s| s == ".."))
            .ok_or_else(|| io::Error::other("cgroup v2 unavailable"))?;
        Self::read_at(Path::new("/sys/fs/cgroup"), cgroup)
    }

    pub fn read_at(root: &Path, cgroup: &str) -> io::Result<Self> {
        let dir = root.join(cgroup.trim_start_matches('/'));
        let read = |file| fs::read_to_string(dir.join(file)).map(|s| s.trim().to_owned());
        Ok(Self {
            cgroup: cgroup.to_owned(),
            memory_max: read("memory.max")?,
            memory_swap_max: read("memory.swap.max")?,
            cpu_max: read("cpu.max")?,
            pids_max: read("pids.max")?,
        })
    }

    /// Readback must match D-06b, not merely be present or nonzero. No probe
    /// that can exhaust resources starts before this check succeeds.
    pub fn matches_policy(&self) -> bool {
        let cpu: Vec<&str> = self.cpu_max.split_whitespace().collect();
        self.memory_max.parse::<u64>() == Ok(MEMORY_MAX)
            && self.memory_swap_max == "0"
            && self.pids_max.parse::<u64>() == Ok(TASKS_MAX)
            && cpu.len() == 2
            && cpu[0]
                .parse::<u64>()
                .ok()
                .is_some_and(|quota| quota > 0 && cpu[1].parse::<u64>() == Ok(quota))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Boundary {
    pub policy: String,
    pub enforcement: Enforcement,
    pub landlock_abi: i64,
    pub files: bool,
    pub network: bool,
    pub processes: bool,
    pub time: bool,
    pub resources: Option<ResourceEvidence>,
    pub reasons: Vec<String>,
}

impl Boundary {
    pub fn unavailable(reason: &str) -> Self {
        Self {
            policy: POLICY.into(),
            enforcement: Enforcement::Unavailable,
            landlock_abi: landlock_abi(),
            files: false,
            network: false,
            processes: false,
            time: false,
            resources: None,
            reasons: vec![reason.into()],
        }
    }

    pub fn verified(
        resources: ResourceEvidence,
        abi: i64,
        confined: bool,
        network: bool,
        deadline_verified: bool,
    ) -> Self {
        let limits = resources.matches_policy();
        let full = limits && abi >= 6 && confined && network && deadline_verified;
        let mut reasons = Vec::new();
        if !limits {
            reasons.push("cgroup_readback_mismatch".into());
        }
        if abi < 6 {
            reasons.push("landlock_abi_below_6".into());
        }
        if !confined {
            reasons.push("confinement_not_verified".into());
        }
        if !network {
            reasons.push("network_filter_unavailable".into());
        }
        if !deadline_verified {
            reasons.push("deadline_not_verified".into());
        }
        Self {
            policy: POLICY.into(),
            enforcement: if full {
                Enforcement::Full
            } else {
                Enforcement::Partial
            },
            landlock_abi: abi,
            files: abi >= 6 && confined,
            network,
            processes: limits,
            time: deadline_verified,
            resources: Some(resources),
            reasons,
        }
    }
}

pub fn landlock_abi() -> i64 {
    // SAFETY: version query takes no pointer and never changes the process.
    unsafe { libc::syscall(libc::SYS_landlock_create_ruleset, 0usize, 0usize, 1u32) }
}

/// The G2 connect broker is not a general "no networking" policy: unconnected
/// UDP sends do not pass through connect(). For G3 diagnostic-v1, disallow
/// creating ANY non-Unix socket before starting the helper, inherited by its
/// whole tree. The helper closes inherited fds and then further restricts Unix
/// sockets. This does not change the G2 backend or its DNS requirements.
pub fn deny_inet_sockets() -> io::Result<()> {
    #[cfg(not(target_arch = "x86_64"))]
    return Err(io::Error::other("unsupported architecture"));
    #[cfg(target_arch = "x86_64")]
    {
        let s = |code, k| libc::sock_filter {
            code,
            jt: 0,
            jf: 0,
            k,
        };
        let j = |k, jt, jf| libc::sock_filter {
            code: 0x15,
            jt,
            jf,
            k,
        };
        let mut filter = [
            s(0x20, 4),
            j(0xc000003e, 1, 0),
            s(0x06, 0x80000000),
            s(0x20, 0),
            // Kill x32 syscall numbers as well as foreign architectures.
            libc::sock_filter {
                code: 0x35,
                jt: 0,
                jf: 1,
                k: 0x40000000,
            },
            s(0x06, 0x80000000),
            j(libc::SYS_socket as u32, 0, 3),
            s(0x20, 16),
            j(libc::AF_UNIX as u32, 1, 0),
            s(0x06, 0x00050000 | libc::EAFNOSUPPORT as u32),
            s(0x06, 0x7fff0000),
        ];
        let program = libc::sock_fprog {
            len: filter.len() as u16,
            filter: filter.as_mut_ptr(),
        };
        // SAFETY: valid BPF buffer; filter is installed on the caller and
        // inherited by children. Called before the runner starts threads.
        unsafe {
            if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
                || libc::syscall(libc::SYS_seccomp, 1u32, 0u32, &program) < 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn evidence() -> ResourceEvidence {
        ResourceEvidence {
            cgroup: "/test.service".into(),
            memory_max: MEMORY_MAX.to_string(),
            memory_swap_max: "0".into(),
            cpu_max: "100000 100000".into(),
            pids_max: "64".into(),
        }
    }

    #[test]
    fn unknown_enforcement_and_extra_fields_are_rejected() {
        assert!(serde_json::from_str::<Enforcement>("\"mostly\"").is_err());
        for level in [
            Enforcement::Full,
            Enforcement::Partial,
            Enforcement::Unavailable,
        ] {
            assert_eq!(
                serde_json::from_str::<Enforcement>(&serde_json::to_string(&level).unwrap())
                    .unwrap(),
                level
            );
        }
        let mut value = serde_json::to_value(Boundary::unavailable("test")).unwrap();
        value["trusted"] = serde_json::json!(true);
        assert!(serde_json::from_value::<Boundary>(value).is_err());
    }

    #[test]
    fn missing_or_unlimited_resources_never_attest_full() {
        let base = evidence();
        assert!(base.matches_policy());
        for (field, value) in [
            ("memory_max", "max"),
            ("memory_swap_max", "max"),
            ("cpu_max", "max 100000"),
            ("cpu_max", "200000 100000"),
            ("cpu_max", "0 0"),
            ("pids_max", "max"),
            ("pids_max", "128"),
        ] {
            let mut json = serde_json::to_value(&base).unwrap();
            json[field] = value.into();
            let bad: ResourceEvidence = serde_json::from_value(json).unwrap();
            assert_ne!(
                Boundary::verified(bad, 6, true, true, true).enforcement,
                Enforcement::Full,
                "{field}"
            );
        }
    }

    #[test]
    fn abi_and_private_handshake_are_required() {
        assert_eq!(
            Boundary::verified(evidence(), 5, true, true, true).enforcement,
            Enforcement::Partial
        );
        assert_eq!(
            Boundary::verified(evidence(), 6, false, true, true).enforcement,
            Enforcement::Partial
        );
        assert_eq!(
            Boundary::verified(evidence(), 6, true, false, true).enforcement,
            Enforcement::Partial
        );
        assert_eq!(
            Boundary::verified(evidence(), 6, true, true, true).enforcement,
            Enforcement::Full
        );
        assert_eq!(
            Boundary::verified(evidence(), 6, true, true, false).enforcement,
            Enforcement::Partial
        );
    }
}
