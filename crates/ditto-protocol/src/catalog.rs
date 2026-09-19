use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    CloseRequestOutput, Empty, ErrorName, EventsSubscribeInput, EventsSubscribeOutput,
    OutputsListOutput, Window, WindowIdInput, WindowMoveInput, WindowResizeInput,
    WindowSetStateInput, WindowsListOutput, Workspace, WorkspaceIdInput, WorkspacesListOutput,
};

/// A capability contract. `availability` is the only runtime-resolved field:
/// the exported catalog declares which matrix row a capability depends on, and
/// Core fills in what the connected compositor actually offers.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CapabilityDescriptor {
    pub capability_id: String,
    pub version: String,
    pub input_schema: Value,
    pub output_schema: Value,
    pub errors: Vec<ErrorName>,
    pub resource_scope: Vec<String>,
    pub cancellable: bool,
    pub idempotency: Idempotency,
    pub timeout_ms: Timeout,
    pub readback: Option<String>,
    pub claimable: bool,
    pub provider: String,
    pub availability: Availability,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Idempotency {
    None,
    KeyBased,
    Natural,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Timeout {
    pub default_ms: u64,
    pub max_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Availability {
    Always,
    /// Resolved when Core connects to a compositor; the exported catalog cannot
    /// know it, so it names the capability matrix row instead of guessing.
    ResolvedAtRuntime {
        matrix_row: String,
    },
    DependsOnCompositor {
        matrix_row: String,
        available: bool,
        reason: Option<String>,
        /// Compositor-specific path this capability is bound to, when no
        /// neutral Wayland protocol covers it.
        bound_to: Option<String>,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CapabilitiesListOutput {
    pub catalog_revision: u64,
    pub capabilities: Vec<CapabilityDescriptor>,
}

pub const CATALOG_REVISION: u64 = 2;

pub const CAPABILITIES_LIST: &str = "desktop.capabilities.list";
pub const OUTPUTS_LIST: &str = "desktop.outputs.list";
pub const WORKSPACES_LIST: &str = "desktop.workspaces.list";
pub const WORKSPACES_GET: &str = "desktop.workspaces.get";
pub const WORKSPACES_ACTIVATE: &str = "desktop.workspaces.activate";
pub const WINDOWS_LIST: &str = "desktop.windows.list";
pub const WINDOWS_GET: &str = "desktop.windows.get";
pub const WINDOWS_FOCUS: &str = "desktop.windows.focus";
pub const WINDOWS_MOVE: &str = "desktop.windows.move";
pub const WINDOWS_RESIZE: &str = "desktop.windows.resize";
pub const WINDOWS_SET_STATE: &str = "desktop.windows.set_state";
pub const WINDOWS_CLOSE_REQUEST: &str = "desktop.windows.close_request";
pub const EVENTS_SUBSCRIBE: &str = "desktop.events.subscribe";

/// G0 declares no permission model, so `permission_denied` is reserved and
/// never returned; it stays in the closed set so adding grants in G1 is not a
/// contract break for consumers that already match exhaustively.
const READ_ERRORS: &[ErrorName] = &[
    ErrorName::Unsupported,
    ErrorName::InvalidParams,
    ErrorName::NotFound,
    ErrorName::PermissionDenied,
    ErrorName::Timeout,
    ErrorName::Cancelled,
    ErrorName::Unavailable,
    ErrorName::ProtocolVersionUnsupported,
    ErrorName::IdentityRejected,
    ErrorName::Internal,
];

const WRITE_ERRORS: &[ErrorName] = &[
    ErrorName::Unsupported,
    ErrorName::InvalidParams,
    ErrorName::NotFound,
    ErrorName::PermissionDenied,
    ErrorName::Timeout,
    ErrorName::Cancelled,
    ErrorName::Conflict,
    ErrorName::Unavailable,
    ErrorName::ProtocolVersionUnsupported,
    ErrorName::IdentityRejected,
    ErrorName::Internal,
];

fn schema<T: JsonSchema>() -> Value {
    serde_json::to_value(schemars::schema_for!(T)).expect("schema serializes")
}

struct Definition {
    capability_id: &'static str,
    input_schema: fn() -> Value,
    output_schema: fn() -> Value,
    write: bool,
    cancellable: bool,
    idempotency: Idempotency,
    readback: Option<&'static str>,
    claimable: bool,
    matrix_row: Option<&'static str>,
}

fn definitions() -> Vec<Definition> {
    vec![
        Definition {
            capability_id: CAPABILITIES_LIST,
            input_schema: schema::<Empty>,
            output_schema: schema::<CapabilitiesListOutput>,
            write: false,
            cancellable: false,
            idempotency: Idempotency::None,
            readback: None,
            claimable: false,
            matrix_row: None,
        },
        Definition {
            capability_id: OUTPUTS_LIST,
            input_schema: schema::<Empty>,
            output_schema: schema::<OutputsListOutput>,
            write: false,
            cancellable: false,
            idempotency: Idempotency::None,
            readback: None,
            claimable: false,
            matrix_row: Some("C-06"),
        },
        Definition {
            capability_id: WORKSPACES_LIST,
            input_schema: schema::<Empty>,
            output_schema: schema::<WorkspacesListOutput>,
            write: false,
            cancellable: false,
            idempotency: Idempotency::None,
            readback: None,
            claimable: false,
            matrix_row: Some("C-05"),
        },
        Definition {
            capability_id: WORKSPACES_GET,
            input_schema: schema::<WorkspaceIdInput>,
            output_schema: schema::<Workspace>,
            write: false,
            cancellable: false,
            idempotency: Idempotency::None,
            readback: None,
            claimable: false,
            matrix_row: Some("C-05"),
        },
        Definition {
            capability_id: WORKSPACES_ACTIVATE,
            input_schema: schema::<WorkspaceIdInput>,
            output_schema: schema::<Workspace>,
            write: true,
            cancellable: false,
            idempotency: Idempotency::Natural,
            readback: Some(WORKSPACES_GET),
            claimable: true,
            matrix_row: Some("C-05"),
        },
        Definition {
            capability_id: WINDOWS_LIST,
            input_schema: schema::<Empty>,
            output_schema: schema::<WindowsListOutput>,
            write: false,
            cancellable: false,
            idempotency: Idempotency::None,
            readback: None,
            claimable: false,
            matrix_row: Some("C-02"),
        },
        Definition {
            capability_id: WINDOWS_GET,
            input_schema: schema::<WindowIdInput>,
            output_schema: schema::<Window>,
            write: false,
            cancellable: false,
            idempotency: Idempotency::None,
            readback: None,
            claimable: false,
            matrix_row: Some("C-02"),
        },
        Definition {
            capability_id: WINDOWS_FOCUS,
            input_schema: schema::<WindowIdInput>,
            output_schema: schema::<Window>,
            write: true,
            cancellable: false,
            idempotency: Idempotency::Natural,
            readback: Some(WINDOWS_GET),
            claimable: true,
            matrix_row: Some("C-03"),
        },
        Definition {
            capability_id: WINDOWS_MOVE,
            input_schema: schema::<WindowMoveInput>,
            output_schema: schema::<Window>,
            write: true,
            cancellable: false,
            idempotency: Idempotency::Natural,
            readback: Some(WINDOWS_GET),
            claimable: true,
            matrix_row: Some("C-04"),
        },
        Definition {
            capability_id: WINDOWS_RESIZE,
            input_schema: schema::<WindowResizeInput>,
            output_schema: schema::<Window>,
            write: true,
            cancellable: false,
            idempotency: Idempotency::Natural,
            readback: Some(WINDOWS_GET),
            claimable: true,
            matrix_row: Some("C-04"),
        },
        Definition {
            capability_id: WINDOWS_SET_STATE,
            input_schema: schema::<WindowSetStateInput>,
            output_schema: schema::<Window>,
            write: true,
            cancellable: false,
            idempotency: Idempotency::Natural,
            readback: Some(WINDOWS_GET),
            claimable: true,
            matrix_row: Some("C-03"),
        },
        Definition {
            // Delivery is observable, completion is not: the application may
            // refuse to close, so this capability never claims success.
            capability_id: WINDOWS_CLOSE_REQUEST,
            input_schema: schema::<WindowIdInput>,
            output_schema: schema::<CloseRequestOutput>,
            write: true,
            cancellable: false,
            idempotency: Idempotency::KeyBased,
            readback: Some(WINDOWS_LIST),
            claimable: false,
            matrix_row: Some("C-03"),
        },
        Definition {
            capability_id: EVENTS_SUBSCRIBE,
            input_schema: schema::<EventsSubscribeInput>,
            output_schema: schema::<EventsSubscribeOutput>,
            write: false,
            cancellable: true,
            idempotency: Idempotency::None,
            readback: None,
            claimable: false,
            matrix_row: Some("C-02"),
        },
    ]
}

/// Timeouts are part of the contract: a capability with no upper bound is not
/// exposed across processes.
fn timeout_for(cancellable: bool) -> Timeout {
    if cancellable {
        Timeout {
            default_ms: 5_000,
            max_ms: 30_000,
        }
    } else {
        Timeout {
            default_ms: 2_000,
            max_ms: 5_000,
        }
    }
}

/// The runtime-relevant part of a descriptor, without the schemas. Core routes
/// on this so request handling never rebuilds every JSON Schema.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapabilityContract {
    pub capability_id: &'static str,
    pub cancellable: bool,
    pub timeout: Timeout,
    pub readback: Option<&'static str>,
    pub claimable: bool,
    pub matrix_row: Option<&'static str>,
}

pub fn contracts() -> Vec<CapabilityContract> {
    definitions()
        .into_iter()
        .map(|definition| CapabilityContract {
            capability_id: definition.capability_id,
            cancellable: definition.cancellable,
            timeout: timeout_for(definition.cancellable),
            readback: definition.readback,
            claimable: definition.claimable,
            matrix_row: definition.matrix_row,
        })
        .collect()
}

pub fn contract(capability_id: &str) -> Option<CapabilityContract> {
    contracts()
        .into_iter()
        .find(|contract| contract.capability_id == capability_id)
}

fn descriptor(definition: Definition, availability: Availability) -> CapabilityDescriptor {
    CapabilityDescriptor {
        capability_id: definition.capability_id.into(),
        version: "1.0.0".into(),
        input_schema: (definition.input_schema)(),
        output_schema: (definition.output_schema)(),
        errors: if definition.write {
            WRITE_ERRORS.to_vec()
        } else {
            READ_ERRORS.to_vec()
        },
        resource_scope: vec![], // Deliberately empty: G0 has no permission grants.
        cancellable: definition.cancellable,
        idempotency: definition.idempotency,
        timeout_ms: timeout_for(definition.cancellable),
        readback: definition.readback.map(Into::into),
        claimable: definition.claimable,
        provider: if definition.matrix_row.is_some() {
            "compositor-adapter".into()
        } else {
            "core".into()
        },
        availability,
    }
}

/// The exported contract: every capability with its declared matrix row.
pub fn catalog() -> CapabilitiesListOutput {
    CapabilitiesListOutput {
        catalog_revision: CATALOG_REVISION,
        capabilities: definitions()
            .into_iter()
            .map(|definition| {
                let availability = match definition.matrix_row {
                    None => Availability::Always,
                    Some(row) => Availability::ResolvedAtRuntime {
                        matrix_row: row.into(),
                    },
                };
                descriptor(definition, availability)
            })
            .collect(),
    }
}

/// The served catalog: `resolve` reports what the connected compositor offers,
/// so a consumer learns a capability is unavailable before calling it.
pub fn resolved_catalog(resolve: impl Fn(&str, &str) -> Availability) -> CapabilitiesListOutput {
    CapabilitiesListOutput {
        catalog_revision: CATALOG_REVISION,
        capabilities: definitions()
            .into_iter()
            .map(|definition| {
                let availability = match definition.matrix_row {
                    None => Availability::Always,
                    Some(row) => resolve(definition.capability_id, row),
                };
                descriptor(definition, availability)
            })
            .collect(),
    }
}

pub fn validate_catalog(
    descriptors: &[CapabilityDescriptor],
    provider_handlers: &[&str],
    consumers: &[&str],
) -> Result<(), String> {
    let ids: std::collections::HashSet<_> = descriptors
        .iter()
        .map(|item| item.capability_id.as_str())
        .collect();
    if ids.len() != descriptors.len() {
        return Err("duplicate capability_id".into());
    }
    for item in descriptors {
        let id = item.capability_id.as_str();
        if !provider_handlers.contains(&id) {
            return Err(format!("{id}: no registered handler"));
        }
        if !consumers.contains(&id) {
            return Err(format!("{id}: no registered consumer"));
        }
        if !item.errors.contains(&ErrorName::Unsupported) {
            return Err(format!("{id}: unsupported missing from closed error set"));
        }
        if item.timeout_ms.default_ms == 0
            || item.timeout_ms.max_ms == 0
            || item.timeout_ms.default_ms > item.timeout_ms.max_ms
        {
            return Err(format!("{id}: invalid timeout"));
        }
        if let Some(readback) = &item.readback {
            if !ids.contains(readback.as_str()) {
                return Err(format!("{id}: readback {readback} is not registered"));
            }
        } else if item.claimable {
            return Err(format!("{id}: cannot claim success without readback"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_missing_seam_or_unverifiable_success() {
        let mut entries = catalog().capabilities;
        let ids: Vec<_> = entries
            .iter()
            .map(|item| item.capability_id.clone())
            .collect();
        let all: Vec<&str> = ids.iter().map(String::as_str).collect();
        assert!(validate_catalog(&entries, &[], &all).is_err());
        assert!(validate_catalog(&entries, &all, &[]).is_err());
        let subscribe = entries
            .iter_mut()
            .find(|item| item.capability_id == EVENTS_SUBSCRIBE)
            .expect("subscribe is in the catalog");
        subscribe.claimable = true;
        assert!(validate_catalog(&entries, &all, &all).is_err());
    }

    #[test]
    fn close_request_reports_delivery_only() {
        let catalog = catalog();
        let close = catalog
            .capabilities
            .iter()
            .find(|item| item.capability_id == WINDOWS_CLOSE_REQUEST)
            .expect("close_request is in the catalog");
        assert!(!close.claimable);
        assert_eq!(close.idempotency, Idempotency::KeyBased);
        assert_eq!(close.readback.as_deref(), Some(WINDOWS_LIST));
    }

    #[test]
    fn exported_catalog_defers_compositor_availability() {
        for item in catalog().capabilities {
            match item.availability {
                Availability::Always => assert_eq!(item.provider, "core"),
                Availability::ResolvedAtRuntime { .. } => {
                    assert_eq!(item.provider, "compositor-adapter")
                }
                Availability::DependsOnCompositor { .. } => {
                    panic!(
                        "{} must not claim availability at export time",
                        item.capability_id
                    )
                }
            }
        }
    }
}
