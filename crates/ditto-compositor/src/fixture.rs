//! In-memory compositor for tests and for running Core where no compositor is
//! reachable. It reproduces the gaps a real compositor has (no coordinate
//! control for tiled windows, no minimize or maximize state) so a consumer that
//! works against the fixture also meets `unsupported` on the real path. Numbers
//! or capability claims produced against it are not compositor evidence.

use std::sync::mpsc::{self, Receiver, Sender};

use ditto_protocol::{
    profile::ShortcutBinding, Output, Window, WindowSessionId, WindowState, Workspace,
};

use crate::{
    AdapterError, AdapterResult, CompositorAdapter, CompositorChange, EventSource, Support,
};

pub const LABEL: &str = "fixture (no compositor)";

pub struct FixtureCompositor {
    outputs: Vec<Output>,
    workspaces: Vec<Workspace>,
    windows: Vec<Window>,
    floating: Vec<WindowSessionId>,
    changes: Sender<CompositorChange>,
    connected: bool,
    strategy: String,
    shortcuts: Vec<ShortcutBinding>,
}

pub struct FixtureEventSource {
    changes: Receiver<CompositorChange>,
}

impl FixtureCompositor {
    pub fn paired() -> (Self, FixtureEventSource) {
        let (changes, receiver) = mpsc::channel();
        let floating = WindowSessionId("fixture-window-2".into());
        let compositor = Self {
            outputs: vec![Output {
                name: "FIXTURE-1".into(),
                width: 1920,
                height: 1080,
                scale: 1.0,
                x: 0,
                y: 0,
                enabled: true,
            }],
            workspaces: vec![
                Workspace {
                    id: "1".into(),
                    name: "1".into(),
                    active: true,
                },
                Workspace {
                    id: "2".into(),
                    name: "2".into(),
                    active: false,
                },
            ],
            windows: vec![
                Window {
                    id: WindowSessionId("fixture-window-1".into()),
                    title: "terminal".into(),
                    app_id: "fixture.terminal".into(),
                    workspace_id: Some("1".into()),
                    x: Some(0),
                    y: Some(0),
                    width: Some(960),
                    height: Some(1080),
                    focused: true,
                    state: WindowState::Normal,
                },
                Window {
                    id: floating.clone(),
                    title: "notes".into(),
                    app_id: "fixture.editor".into(),
                    workspace_id: Some("1".into()),
                    x: Some(100),
                    y: Some(100),
                    width: Some(640),
                    height: Some(480),
                    focused: false,
                    state: WindowState::Normal,
                },
            ],
            floating: vec![floating],
            changes,
            connected: true,
            strategy: "floating".into(),
            shortcuts: vec![],
        };
        (compositor, FixtureEventSource { changes: receiver })
    }

    /// Drop the compositor connection, as a compositor restart would.
    pub fn disconnect(&mut self) {
        self.connected = false;
    }

    fn online(&self) -> AdapterResult<()> {
        if self.connected {
            return Ok(());
        }
        Err(AdapterError::Unavailable(
            "fixture compositor connection closed".into(),
        ))
    }

    fn window_mut(&mut self, window_id: &WindowSessionId) -> AdapterResult<&mut Window> {
        self.online()?;
        self.windows
            .iter_mut()
            .find(|window| window.id == *window_id)
            .ok_or_else(|| AdapterError::NotFound(format!("no window {}", window_id.0)))
    }

    fn coordinate_target(&mut self, window_id: &WindowSessionId) -> AdapterResult<()> {
        self.online()?;
        if !self.windows.iter().any(|window| window.id == *window_id) {
            return Err(AdapterError::NotFound(format!("no window {}", window_id.0)));
        }
        if self.floating.contains(window_id) {
            return Ok(());
        }
        Err(AdapterError::Unsupported(
            "tiled window geometry is owned by the compositor layout (C-04)".into(),
        ))
    }

    fn announce(&self, change: CompositorChange) {
        let _ = self.changes.send(change);
    }
}

impl CompositorAdapter for FixtureCompositor {
    fn label(&self) -> String {
        LABEL.into()
    }

    fn support(&self, capability_id: &str) -> Support {
        match capability_id {
            "desktop.outputs.list" => Support::bound("C-06", "fixture", "in-memory fixture state"),
            "desktop.workspaces.list"
            | "desktop.workspaces.get"
            | "desktop.workspaces.activate" => {
                Support::bound("C-05", "fixture", "in-memory fixture state")
            }
            "desktop.windows.list"
            | "desktop.windows.get"
            | "desktop.windows.focus"
            | "desktop.windows.close_request" => {
                Support::bound("C-02", "fixture", "in-memory fixture state")
            }
            "desktop.windows.move" | "desktop.windows.resize" => Support::bound(
                "C-04",
                "fixture",
                "floating fixture windows only; tiled windows report unsupported",
            ),
            "desktop.windows.set_state" => Support::bound(
                "C-03",
                "fixture",
                "fullscreen and restore only, as on the compositor path",
            ),
            "desktop.events.subscribe" => {
                Support::bound("C-02", "fixture", "changes announced by the fixture itself")
            }
            other => Support::missing("—", &format!("{other} has no fixture path")),
        }
    }

    fn outputs(&mut self) -> AdapterResult<Vec<Output>> {
        self.online()?;
        Ok(self.outputs.clone())
    }

    fn workspaces(&mut self) -> AdapterResult<Vec<Workspace>> {
        self.online()?;
        Ok(self.workspaces.clone())
    }

    fn windows(&mut self) -> AdapterResult<Vec<Window>> {
        self.online()?;
        Ok(self.windows.clone())
    }

    fn activate_workspace(&mut self, workspace_id: &str) -> AdapterResult<()> {
        self.online()?;
        if !self
            .workspaces
            .iter()
            .any(|workspace| workspace.id == workspace_id)
        {
            return Err(AdapterError::NotFound(format!(
                "no workspace {workspace_id}"
            )));
        }
        for workspace in &mut self.workspaces {
            workspace.active = workspace.id == workspace_id;
        }
        self.announce(CompositorChange::Workspaces);
        Ok(())
    }

    fn focus_window(&mut self, window_id: &WindowSessionId) -> AdapterResult<()> {
        self.window_mut(window_id)?;
        for window in &mut self.windows {
            window.focused = window.id == *window_id;
        }
        self.announce(CompositorChange::Windows);
        Ok(())
    }

    fn move_window(&mut self, window_id: &WindowSessionId, x: i32, y: i32) -> AdapterResult<()> {
        self.coordinate_target(window_id)?;
        let window = self.window_mut(window_id)?;
        window.x = Some(x);
        window.y = Some(y);
        self.announce(CompositorChange::Windows);
        Ok(())
    }

    fn resize_window(
        &mut self,
        window_id: &WindowSessionId,
        width: u32,
        height: u32,
    ) -> AdapterResult<()> {
        self.coordinate_target(window_id)?;
        let window = self.window_mut(window_id)?;
        window.width = Some(width);
        window.height = Some(height);
        self.announce(CompositorChange::Windows);
        Ok(())
    }

    fn set_window_state(
        &mut self,
        window_id: &WindowSessionId,
        state: &WindowState,
    ) -> AdapterResult<()> {
        if matches!(state, WindowState::Minimized | WindowState::Maximized) {
            self.window_mut(window_id)?;
            return Err(AdapterError::Unsupported(
                "this compositor has no minimize or maximize window state (C-03)".into(),
            ));
        }
        let window = self.window_mut(window_id)?;
        window.state = state.clone();
        self.announce(CompositorChange::Windows);
        Ok(())
    }

    fn close_request(&mut self, window_id: &WindowSessionId) -> AdapterResult<()> {
        self.window_mut(window_id)?;
        self.windows.retain(|window| window.id != *window_id);
        self.announce(CompositorChange::Windows);
        Ok(())
    }

    /// The fixture can switch between the two G1 strategies and hold a
    /// binding table, so Core's transaction path can be tested without a
    /// compositor. It is not evidence that a real compositor can (C-15/C-16).
    fn supports_layout_strategy(&self, strategy: &str) -> bool {
        matches!(strategy, "floating" | "simple-tile")
    }

    fn layout_strategy(&mut self) -> AdapterResult<Option<String>> {
        self.online()?;
        Ok(Some(self.strategy.clone()))
    }

    fn set_layout_strategy(&mut self, strategy: &str) -> AdapterResult<()> {
        self.online()?;
        if !self.supports_layout_strategy(strategy) {
            return Err(AdapterError::Unsupported(format!(
                "unknown strategy {strategy}"
            )));
        }
        self.strategy = strategy.into();
        Ok(())
    }

    fn supports_shortcut_binding(&self) -> bool {
        true
    }

    fn shortcuts(&mut self) -> AdapterResult<Vec<ShortcutBinding>> {
        self.online()?;
        Ok(self.shortcuts.clone())
    }

    fn bind_shortcuts(&mut self, bindings: &[ShortcutBinding]) -> AdapterResult<()> {
        self.online()?;
        self.shortcuts = bindings.to_vec();
        Ok(())
    }

    fn workspace_grid(&mut self) -> AdapterResult<Option<[u32; 2]>> {
        Ok(Some([3, 3]))
    }
}

impl EventSource for FixtureEventSource {
    fn next_change(&mut self) -> AdapterResult<Option<CompositorChange>> {
        Ok(self.changes.recv().ok())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_coordinates_for_tiled_windows_and_absent_states() {
        let (mut compositor, _events) = FixtureCompositor::paired();
        let tiled = WindowSessionId("fixture-window-1".into());
        assert!(matches!(
            compositor.move_window(&tiled, 10, 10),
            Err(AdapterError::Unsupported(_))
        ));
        assert!(matches!(
            compositor.set_window_state(&tiled, &WindowState::Minimized),
            Err(AdapterError::Unsupported(_))
        ));
        let floating = WindowSessionId("fixture-window-2".into());
        compositor.move_window(&floating, 10, 10).unwrap();
        assert_eq!(compositor.window(&floating).unwrap().x, Some(10));
    }

    #[test]
    fn reports_unavailable_after_the_connection_drops() {
        let (mut compositor, _events) = FixtureCompositor::paired();
        compositor.disconnect();
        assert!(matches!(
            compositor.windows(),
            Err(AdapterError::Unavailable(_))
        ));
    }
}
