//! Compositor adapter. Windows, workspaces and outputs are the compositor's
//! state; this crate translates protocol and keeps no persistent copy of it.
//! Every capability records which capability-matrix row it depends on, so a
//! gap is reported as `unsupported` instead of a silent success.

pub mod fixture;
pub mod sway;
pub mod wayfire;

use ditto_protocol::{DesktopSnapshot, Output, Window, WindowSessionId, WindowState, Workspace};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdapterError {
    /// The compositor has no path for this operation (capability matrix gap).
    Unsupported(String),
    NotFound(String),
    /// The compositor connection is gone; the caller must mark the capability
    /// unavailable rather than retry silently.
    Unavailable(String),
    /// The command was accepted but the readback disagrees with the request.
    ReadbackMismatch(String),
    Internal(String),
}

pub type AdapterResult<T> = Result<T, AdapterError>;

/// How a capability depends on the compositor, as recorded in
/// `docs/platform/compositor-capability-matrix.md`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Support {
    pub matrix_row: &'static str,
    pub available: bool,
    pub reason: Option<String>,
    /// Compositor-specific path this capability is bound to, when it is not
    /// reachable through a neutral Wayland protocol.
    pub bound_to: Option<String>,
}

impl Support {
    pub fn available(matrix_row: &'static str) -> Self {
        Self {
            matrix_row,
            available: true,
            reason: None,
            bound_to: None,
        }
    }

    pub fn bound(matrix_row: &'static str, bound_to: &str, reason: &str) -> Self {
        Self {
            matrix_row,
            available: true,
            reason: Some(reason.into()),
            bound_to: Some(bound_to.into()),
        }
    }

    pub fn missing(matrix_row: &'static str, reason: &str) -> Self {
        Self {
            matrix_row,
            available: false,
            reason: Some(reason.into()),
            bound_to: None,
        }
    }
}

/// What the compositor reported as changed. Core re-reads the affected state
/// through the adapter; compositor events are never replayed to consumers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompositorChange {
    Windows,
    Workspaces,
    Outputs,
}

pub trait CompositorAdapter: Send {
    /// Compositor name and version, for the measurement fingerprint.
    fn label(&self) -> String;
    fn support(&self, capability_id: &str) -> Support;
    fn outputs(&mut self) -> AdapterResult<Vec<Output>>;
    fn workspaces(&mut self) -> AdapterResult<Vec<Workspace>>;
    fn windows(&mut self) -> AdapterResult<Vec<Window>>;
    fn activate_workspace(&mut self, workspace_id: &str) -> AdapterResult<()>;
    fn focus_window(&mut self, window_id: &WindowSessionId) -> AdapterResult<()>;
    fn move_window(&mut self, window_id: &WindowSessionId, x: i32, y: i32) -> AdapterResult<()>;
    fn resize_window(
        &mut self,
        window_id: &WindowSessionId,
        width: u32,
        height: u32,
    ) -> AdapterResult<()>;
    fn set_window_state(
        &mut self,
        window_id: &WindowSessionId,
        state: &WindowState,
    ) -> AdapterResult<()>;
    /// Ask the compositor to close the window. The application may refuse, so
    /// this only reports that the request was delivered.
    fn close_request(&mut self, window_id: &WindowSessionId) -> AdapterResult<()>;

    fn window(&mut self, window_id: &WindowSessionId) -> AdapterResult<Window> {
        self.windows()?
            .into_iter()
            .find(|window| window.id == *window_id)
            .ok_or_else(|| AdapterError::NotFound(format!("no window {}", window_id.0)))
    }

    fn workspace(&mut self, workspace_id: &str) -> AdapterResult<Workspace> {
        self.workspaces()?
            .into_iter()
            .find(|workspace| workspace.id == workspace_id)
            .ok_or_else(|| AdapterError::NotFound(format!("no workspace {workspace_id}")))
    }

    fn snapshot(&mut self) -> AdapterResult<DesktopSnapshot> {
        Ok(DesktopSnapshot {
            outputs: self.outputs()?,
            workspaces: self.workspaces()?,
            windows: self.windows()?,
        })
    }
}

/// Blocking compositor event stream. A source that ends means the compositor
/// connection died: affected capabilities go unavailable and subscribers are
/// told to resync.
pub trait EventSource: Send {
    fn next_change(&mut self) -> AdapterResult<Option<CompositorChange>>;
}
