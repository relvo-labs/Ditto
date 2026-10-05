//! The G0 compositor capabilities (outputs, workspaces, windows). Unchanged in
//! meaning from G0: every write is read back from the compositor, a readback
//! that disagrees is a conflict, and a deadline passed before the readback is
//! a timeout with an unknown outcome.

use std::{sync::Arc, time::Instant};

use ditto_compositor::AdapterError;
use ditto_protocol::{
    catalog, CloseRequestOutput, ErrorName, OutputsListOutput, UnavailableReason, Window,
    WindowIdInput, WindowMoveInput, WindowResizeInput, WindowSessionId, WindowSetStateInput,
    WindowsListOutput, Workspace, WorkspaceIdInput, WorkspacesListOutput,
};
use serde_json::{json, Value};

use crate::{error::CoreError, router::Call, session::Session};

fn adapter_error(error: AdapterError) -> CoreError {
    match error {
        AdapterError::Unsupported(reason) => CoreError::new(ErrorName::Unsupported, reason),
        AdapterError::NotFound(reason) => CoreError::not_found(reason),
        AdapterError::Unavailable(reason) => {
            CoreError::unavailable(UnavailableReason::CompositorOffline, reason)
        }
        AdapterError::ReadbackMismatch(reason) => {
            CoreError::conflict(ditto_protocol::ConflictReason::ReadbackMismatch, reason)
        }
        AdapterError::Internal(reason) => CoreError::internal(reason),
    }
}

fn unknown_outcome(message: &str) -> CoreError {
    let mut error = CoreError::new(ErrorName::Timeout, message);
    // The command reached the compositor; whether it took effect is unknown.
    error.data = Some(json!({"outcome": "unknown"}));
    error
}

fn expired(call: &Call<'_>, started: Instant) -> bool {
    started.elapsed() > call.deadline
}

fn input<T: serde::de::DeserializeOwned>(call: &Call<'_>) -> Result<T, CoreError> {
    serde_json::from_value(Value::Object(call.params.clone()))
        .map_err(|error| CoreError::invalid(format!("invalid parameters: {error}")))
}

fn no_input(call: &Call<'_>) -> Result<(), CoreError> {
    if call.params.is_empty() {
        Ok(())
    } else {
        Err(CoreError::invalid("unexpected capability parameters"))
    }
}

fn readback_window(
    session: &Session,
    call: &Call<'_>,
    window_id: &WindowSessionId,
) -> Result<Window, CoreError> {
    if expired(call, call.started) {
        return Err(unknown_outcome(
            "deadline passed before the result could be read back",
        ));
    }
    session
        .with_adapter(|adapter| adapter.window(window_id))
        .map_err(adapter_error)
}

fn readback_workspace(
    session: &Session,
    call: &Call<'_>,
    workspace_id: &str,
) -> Result<Workspace, CoreError> {
    if expired(call, call.started) {
        return Err(unknown_outcome(
            "deadline passed before the result could be read back",
        ));
    }
    session
        .with_adapter(|adapter| adapter.workspace(workspace_id))
        .map_err(adapter_error)
}

pub fn execute(session: &Arc<Session>, call: &Call<'_>) -> Result<(Value, bool), CoreError> {
    let read = |outcome: Result<Value, AdapterError>| -> Result<(Value, bool), CoreError> {
        let value = outcome.map_err(adapter_error)?;
        if expired(call, call.started) {
            return Err(CoreError::new(ErrorName::Timeout, "read exceeded deadline"));
        }
        Ok((value, false))
    };
    match call.contract.capability_id {
        catalog::OUTPUTS_LIST => {
            no_input(call)?;
            read(
                session
                    .with_adapter(|adapter| adapter.outputs())
                    .map(|outputs| json!(OutputsListOutput { outputs })),
            )
        }
        catalog::WORKSPACES_LIST => {
            no_input(call)?;
            read(
                session
                    .with_adapter(|adapter| adapter.workspaces())
                    .map(|workspaces| json!(WorkspacesListOutput { workspaces })),
            )
        }
        catalog::WORKSPACES_GET => {
            let input: WorkspaceIdInput = input(call)?;
            read(
                session
                    .with_adapter(|adapter| adapter.workspace(&input.workspace_id))
                    .map(|workspace| json!(workspace)),
            )
        }
        catalog::WINDOWS_LIST => {
            no_input(call)?;
            read(
                session
                    .with_adapter(|adapter| adapter.windows())
                    .map(|windows| json!(WindowsListOutput { windows })),
            )
        }
        catalog::WINDOWS_GET => {
            let input: WindowIdInput = input(call)?;
            read(
                session
                    .with_adapter(|adapter| adapter.window(&input.window_id))
                    .map(|window| json!(window)),
            )
        }
        catalog::WORKSPACES_ACTIVATE => {
            let input: WorkspaceIdInput = input(call)?;
            session
                .with_adapter(|adapter| adapter.activate_workspace(&input.workspace_id))
                .map_err(adapter_error)?;
            let observed = readback_workspace(session, call, &input.workspace_id)?;
            if !observed.active {
                return Err(CoreError::conflict(
                    ditto_protocol::ConflictReason::ReadbackMismatch,
                    format!("readback shows workspace {} is not active", observed.id),
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_FOCUS => {
            let input: WindowIdInput = input(call)?;
            session
                .with_adapter(|adapter| adapter.focus_window(&input.window_id))
                .map_err(adapter_error)?;
            let observed = readback_window(session, call, &input.window_id)?;
            if !observed.focused {
                return Err(CoreError::conflict(
                    ditto_protocol::ConflictReason::ReadbackMismatch,
                    "readback shows the window is not focused",
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_MOVE => {
            let input: WindowMoveInput = input(call)?;
            session
                .with_adapter(|adapter| adapter.move_window(&input.window_id, input.x, input.y))
                .map_err(adapter_error)?;
            let observed = readback_window(session, call, &input.window_id)?;
            if observed.x != Some(input.x) || observed.y != Some(input.y) {
                return Err(CoreError::conflict(
                    ditto_protocol::ConflictReason::ReadbackMismatch,
                    format!(
                        "readback shows position {:?},{:?} instead of {},{}",
                        observed.x, observed.y, input.x, input.y
                    ),
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_RESIZE => {
            let input: WindowResizeInput = input(call)?;
            session
                .with_adapter(|adapter| {
                    adapter.resize_window(&input.window_id, input.width, input.height)
                })
                .map_err(adapter_error)?;
            let observed = readback_window(session, call, &input.window_id)?;
            if observed.width != Some(input.width) || observed.height != Some(input.height) {
                return Err(CoreError::conflict(
                    ditto_protocol::ConflictReason::ReadbackMismatch,
                    format!(
                        "readback shows size {:?}x{:?} instead of {}x{}",
                        observed.width, observed.height, input.width, input.height
                    ),
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_SET_STATE => {
            let input: WindowSetStateInput = input(call)?;
            session
                .with_adapter(|adapter| adapter.set_window_state(&input.window_id, &input.state))
                .map_err(adapter_error)?;
            let observed = readback_window(session, call, &input.window_id)?;
            if observed.state != input.state {
                return Err(CoreError::conflict(
                    ditto_protocol::ConflictReason::ReadbackMismatch,
                    format!("readback shows state {:?}", observed.state),
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_CLOSE_REQUEST => {
            let input: WindowIdInput = input(call)?;
            session
                .with_adapter(|adapter| adapter.close_request(&input.window_id))
                .map_err(adapter_error)?;
            // Delivery only: the application may still refuse to close, so
            // the caller confirms the outcome through windows.list or an event.
            let operation_id = call
                .operation_id
                .clone()
                .unwrap_or_else(|| format!("close-{}", input.window_id.0));
            Ok((
                json!(CloseRequestOutput {
                    accepted: true,
                    operation_id,
                }),
                false,
            ))
        }
        other => Err(CoreError::new(
            ErrorName::Unsupported,
            format!("{other} has no compositor handler"),
        )),
    }
}
