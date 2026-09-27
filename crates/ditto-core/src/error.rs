//! Errors a capability handler returns, already in the protocol's closed set.

use ditto_protocol::{
    change::PreflightReason, rpc::RpcResponse, ConflictReason, ErrorName, PermissionDeniedReason,
    UnavailableReason,
};
use ditto_store::StoreError;
use serde_json::{json, Value};

#[derive(Clone, Debug, PartialEq)]
pub struct CoreError {
    pub name: ErrorName,
    pub message: String,
    pub data: Option<Value>,
}

impl CoreError {
    pub fn new(name: ErrorName, message: impl Into<String>) -> Self {
        Self {
            name,
            message: message.into(),
            data: None,
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(ErrorName::InvalidParams, message)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorName::NotFound, message)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(ErrorName::Internal, message)
    }

    pub fn conflict(reason: ConflictReason, message: impl Into<String>) -> Self {
        Self {
            name: ErrorName::Conflict,
            message: message.into(),
            data: Some(json!({ "reason": reason })),
        }
    }

    pub fn unavailable(reason: UnavailableReason, message: impl Into<String>) -> Self {
        Self {
            name: ErrorName::Unavailable,
            message: message.into(),
            data: Some(json!({ "reason": reason })),
        }
    }

    pub fn denied(reason: PermissionDeniedReason, scope: Option<&str>) -> Self {
        Self {
            name: ErrorName::PermissionDenied,
            message: format!("permission denied ({})", scope.unwrap_or("policy")),
            data: Some(json!({ "reason": reason, "scope": scope })),
        }
    }

    pub fn preflight(reasons: &[PreflightReason], change_id: &str) -> Self {
        Self {
            name: ErrorName::PreflightRejected,
            message: format!("preflight rejected the change ({} reasons)", reasons.len()),
            data: Some(json!({ "reasons": reasons, "change_id": change_id })),
        }
    }

    pub fn identity(message: impl Into<String>) -> Self {
        Self::new(ErrorName::IdentityRejected, message)
    }

    pub fn response(&self, id: String) -> RpcResponse {
        RpcResponse::error_with(id, self.name.clone(), &self.message, self.data.clone())
    }
}

impl From<StoreError> for CoreError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::NotFound(what) => Self::not_found(what),
            StoreError::Conflict(what) => Self::new(ErrorName::Conflict, what),
            StoreError::Invalid(what) => Self::invalid(what),
            StoreError::StorageFull => Self {
                name: ErrorName::Unavailable,
                message: "not enough storage space; nothing was changed".into(),
                data: Some(json!({ "reason": UnavailableReason::StorageFull })),
            },
            StoreError::Io(what) => Self {
                name: ErrorName::Unavailable,
                message: format!("storage error; nothing was changed ({what})"),
                data: Some(json!({ "reason": UnavailableReason::StorageError })),
            },
            StoreError::Locked => {
                Self::new(ErrorName::Unavailable, "the configuration store is locked")
            }
            other => Self::internal(other.to_string()),
        }
    }
}
