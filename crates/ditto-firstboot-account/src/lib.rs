//! First-boot OS account provisioning, separate from desktop Profile authority.
//! Production accepts no configurable root, executable, group, shell, or UID.
mod input;
mod transaction;
pub mod unix;
pub use input::{validate, Request, Secret, MAX_REQUEST};
use serde::{Deserialize, Serialize};
pub use transaction::{AccountTools, Engine, SystemTools};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Code {
    InvalidUsername,
    UsernameTaken,
    PasswordTooShort,
    PasswordInvalid,
    DisplayNameInvalid,
    AlreadyProvisioned,
    Unauthorized,
    InternalRolledBack,
    InternalRollbackFailed,
}
impl Code {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidUsername => "invalid_username",
            Self::UsernameTaken => "username_taken",
            Self::PasswordTooShort => "password_too_short",
            Self::PasswordInvalid => "password_invalid",
            Self::DisplayNameInvalid => "display_name_invalid",
            Self::AlreadyProvisioned => "already_provisioned",
            Self::Unauthorized => "unauthorized",
            Self::InternalRolledBack => "internal_rolled_back",
            Self::InternalRollbackFailed => "internal_rollback_failed",
        }
    }
}
#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged, deny_unknown_fields)]
pub enum Response {
    Success { ok: bool, weak_password: bool },
    Error { ok: bool, error: Code },
}
impl Response {
    pub fn error(error: Code) -> Self {
        Self::Error { ok: false, error }
    }
}
pub(crate) fn phase(log: &mut dyn std::io::Write, phase: &str, result: &str) {
    // All callers supply constants; never format input or tool/parser errors.
    let _ = writeln!(log, "phase={phase} result={result}");
}
