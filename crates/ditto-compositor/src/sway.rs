//! Sway IPC backend. **Abandoned.**
//!
//! D-02 selected Wayfire on 2026-09-22 (`.agents/notes/decisions/`), and Sway is
//! no longer a support target: it takes no new capabilities, the default paths
//! and the G0 scripts do not run it, and nothing here is expected to keep up
//! with `wayfire.rs`.
//!
//! It is kept, and kept compiling, for one reason: it is the other half of the
//! comparison D-02 was decided on. Deleting it would leave the decision record
//! pointing at evidence that can no longer be reproduced, and Sway is the first
//! option that would be reconsidered if Wayfire turns out to be blocked.
//!
//! Window coordinates and workspaces are not covered by the neutral Wayland
//! protocols (matrix rows C-04 and C-05), so this backend is compositor-bound by
//! design; every capability it serves reports that binding.

use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::Path,
};

use ditto_protocol::{Output, Window, WindowSessionId, WindowState, Workspace};
use serde_json::Value;

use crate::{
    AdapterError, AdapterResult, CompositorAdapter, CompositorChange, EventSource, Support,
};

const MAGIC: &[u8; 6] = b"i3-ipc";
const RUN_COMMAND: u32 = 0;
const GET_WORKSPACES: u32 = 1;
const SUBSCRIBE: u32 = 2;
const GET_OUTPUTS: u32 = 3;
const GET_TREE: u32 = 4;
const GET_VERSION: u32 = 7;
const EVENT_WORKSPACE: u32 = 0x8000_0000;
const EVENT_OUTPUT: u32 = 0x8000_0001;
const EVENT_WINDOW: u32 = 0x8000_0003;
const ID_PREFIX: &str = "sway-con-";
const BOUND_TO: &str = "sway-ipc";

struct Connection {
    stream: UnixStream,
}

impl Connection {
    fn open(socket: &Path) -> AdapterResult<Self> {
        UnixStream::connect(socket)
            .map(|stream| Self { stream })
            .map_err(|error| AdapterError::Unavailable(format!("sway IPC unreachable: {error}")))
    }

    fn send(&mut self, message_type: u32, payload: &[u8]) -> AdapterResult<()> {
        let mut frame = Vec::with_capacity(14 + payload.len());
        frame.extend_from_slice(MAGIC);
        frame.extend_from_slice(&(payload.len() as u32).to_ne_bytes());
        frame.extend_from_slice(&message_type.to_ne_bytes());
        frame.extend_from_slice(payload);
        self.stream
            .write_all(&frame)
            .map_err(|error| AdapterError::Unavailable(format!("sway IPC write failed: {error}")))
    }

    fn receive(&mut self) -> AdapterResult<(u32, Value)> {
        let mut header = [0_u8; 14];
        self.stream.read_exact(&mut header).map_err(|error| {
            AdapterError::Unavailable(format!("sway IPC connection ended: {error}"))
        })?;
        if &header[..6] != MAGIC {
            return Err(AdapterError::Internal("sway IPC framing lost".into()));
        }
        let length = u32::from_ne_bytes(header[6..10].try_into().expect("4 bytes")) as usize;
        let message_type = u32::from_ne_bytes(header[10..14].try_into().expect("4 bytes"));
        let mut payload = vec![0_u8; length];
        self.stream.read_exact(&mut payload).map_err(|error| {
            AdapterError::Unavailable(format!("sway IPC payload truncated: {error}"))
        })?;
        let value = serde_json::from_slice(&payload).map_err(|error| {
            AdapterError::Internal(format!("sway IPC payload invalid: {error}"))
        })?;
        Ok((message_type, value))
    }

    fn request(&mut self, message_type: u32, payload: &[u8]) -> AdapterResult<Value> {
        self.send(message_type, payload)?;
        loop {
            let (kind, value) = self.receive()?;
            if kind & 0x8000_0000 == 0 {
                return Ok(value);
            }
        }
    }
}

pub struct SwayAdapter {
    connection: Connection,
    version: String,
}

impl SwayAdapter {
    /// Connect to `$SWAYSOCK`.
    pub fn connect(socket: &Path) -> AdapterResult<Self> {
        let mut connection = Connection::open(socket)?;
        let version = connection.request(GET_VERSION, b"")?;
        let version = version
            .get("human_readable_version")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        Ok(Self {
            connection,
            version,
        })
    }

    pub fn from_environment() -> AdapterResult<Self> {
        let socket = std::env::var_os("SWAYSOCK")
            .ok_or_else(|| AdapterError::Unavailable("SWAYSOCK is not set".into()))?;
        Self::connect(Path::new(&socket))
    }

    fn run(&mut self, command: &str) -> AdapterResult<()> {
        let outcome = self.connection.request(RUN_COMMAND, command.as_bytes())?;
        let entries = outcome
            .as_array()
            .ok_or_else(|| AdapterError::Internal("sway command reply is not a list".into()))?;
        for entry in entries {
            if entry.get("success").and_then(Value::as_bool) != Some(true) {
                let message = entry
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("command rejected");
                return Err(AdapterError::Internal(format!(
                    "sway rejected `{command}`: {message}"
                )));
            }
        }
        Ok(())
    }

    fn tree_windows(&mut self) -> AdapterResult<Vec<TreeWindow>> {
        let tree = self.connection.request(GET_TREE, b"")?;
        let mut windows = Vec::new();
        collect_windows(&tree, None, &mut windows);
        Ok(windows)
    }

    fn tree_window(&mut self, window_id: &WindowSessionId) -> AdapterResult<TreeWindow> {
        let target = con_id(window_id)?;
        self.tree_windows()?
            .into_iter()
            .find(|entry| entry.con_id == target)
            .ok_or_else(|| AdapterError::NotFound(format!("no window {}", window_id.0)))
    }

    /// Coordinate control exists only for floating containers; a tiled window's
    /// geometry belongs to the layout, so the request is refused rather than
    /// accepted with no effect.
    fn floating_target(&mut self, window_id: &WindowSessionId) -> AdapterResult<i64> {
        let window = self.tree_window(window_id)?;
        if window.floating {
            return Ok(window.con_id);
        }
        Err(AdapterError::Unsupported(
            "tiled window geometry is owned by the compositor layout (C-04)".into(),
        ))
    }
}

struct TreeWindow {
    con_id: i64,
    floating: bool,
    window: Window,
}

fn con_id(window_id: &WindowSessionId) -> AdapterResult<i64> {
    window_id
        .0
        .strip_prefix(ID_PREFIX)
        .and_then(|rest| rest.parse().ok())
        .ok_or_else(|| AdapterError::NotFound(format!("not a session window id: {}", window_id.0)))
}

fn number(node: &Value, key: &str) -> Option<i64> {
    node.get(key).and_then(Value::as_i64)
}

fn rectangle(node: &Value) -> (Option<i32>, Option<i32>, Option<u32>, Option<u32>) {
    let rect = node.get("rect");
    let read = |key: &str| {
        rect.and_then(|value| value.get(key))
            .and_then(Value::as_i64)
    };
    (
        read("x").map(|value| value as i32),
        read("y").map(|value| value as i32),
        read("width").map(|value| value as u32),
        read("height").map(|value| value as u32),
    )
}

/// The window as the user sees it: decorations included. The compositor reports
/// the content box separately from the title bar and positions windows by the
/// decoration origin, so a capability built on the content box would report a
/// mismatch for every move that actually worked.
fn frame(node: &Value) -> (Option<i32>, Option<i32>, Option<u32>, Option<u32>) {
    let (x, y, width, height) = rectangle(node);
    let decoration = node.get("deco_rect");
    let read = |key: &str| {
        decoration
            .and_then(|value| value.get(key))
            .and_then(Value::as_i64)
    };
    let decoration_height = read("height").unwrap_or(0);
    if decoration_height <= 0 {
        return (x, y, width, height);
    }
    (
        read("x").map(|value| value as i32).or(x),
        read("y").map(|value| value as i32).or(y),
        width,
        height.map(|value| value + decoration_height as u32),
    )
}

fn collect_windows(node: &Value, workspace: Option<&str>, out: &mut Vec<TreeWindow>) {
    let node_type = node.get("type").and_then(Value::as_str).unwrap_or_default();
    let workspace = if node_type == "workspace" {
        node.get("name").and_then(Value::as_str)
    } else {
        workspace
    };
    let has_children = ["nodes", "floating_nodes"].iter().any(|key| {
        node.get(*key)
            .and_then(Value::as_array)
            .is_some_and(|children| !children.is_empty())
    });
    let is_leaf_container = matches!(node_type, "con" | "floating_con") && !has_children;
    if is_leaf_container {
        if let Some(con_id) = number(node, "id") {
            let (x, y, width, height) = frame(node);
            let app_id = node
                .get("app_id")
                .and_then(Value::as_str)
                .or_else(|| {
                    node.get("window_properties")
                        .and_then(|properties| properties.get("class"))
                        .and_then(Value::as_str)
                })
                .unwrap_or("unknown")
                .to_string();
            out.push(TreeWindow {
                con_id,
                floating: node_type == "floating_con",
                window: Window {
                    id: WindowSessionId(format!("{ID_PREFIX}{con_id}")),
                    title: node
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    app_id,
                    workspace_id: workspace.map(str::to_string),
                    // Sway support is kept only for the D-02 comparison;
                    // its coordinates are global, so no output is named.
                    output: None,
                    x,
                    y,
                    width,
                    height,
                    focused: node.get("focused").and_then(Value::as_bool) == Some(true),
                    state: if number(node, "fullscreen_mode").unwrap_or(0) == 1 {
                        WindowState::Fullscreen
                    } else {
                        WindowState::Normal
                    },
                },
            });
        }
    }
    for key in ["nodes", "floating_nodes"] {
        if let Some(children) = node.get(key).and_then(Value::as_array) {
            for child in children {
                collect_windows(child, workspace, out);
            }
        }
    }
}

impl CompositorAdapter for SwayAdapter {
    fn label(&self) -> String {
        format!("sway {}", self.version)
    }

    fn support(&self, capability_id: &str) -> Support {
        match capability_id {
            "desktop.outputs.list" => Support::bound(
                "C-06",
                BOUND_TO,
                "output enumeration read through the compositor's own IPC",
            ),
            "desktop.workspaces.list"
            | "desktop.workspaces.get"
            | "desktop.workspaces.activate" => Support::bound(
                "C-05",
                BOUND_TO,
                "no neutral workspace protocol on this compositor version",
            ),
            "desktop.windows.list" | "desktop.windows.get" => Support::bound(
                "C-02",
                BOUND_TO,
                "window metadata read from the compositor tree, not from foreign-toplevel",
            ),
            "desktop.windows.focus" | "desktop.windows.close_request" => Support::bound(
                "C-03",
                BOUND_TO,
                "window control issued as compositor commands",
            ),
            "desktop.windows.move" | "desktop.windows.resize" => Support::bound(
                "C-04",
                BOUND_TO,
                "coordinates apply to floating windows only; tiled windows report unsupported",
            ),
            "desktop.windows.set_state" => Support::bound(
                "C-03",
                BOUND_TO,
                "fullscreen and restore only; this compositor has no minimize or maximize state",
            ),
            "desktop.events.subscribe" => Support::bound(
                "C-02",
                BOUND_TO,
                "change notifications come from the compositor's own event stream",
            ),
            other => Support::missing("—", &format!("{other} has no compositor path")),
        }
    }

    fn outputs(&mut self) -> AdapterResult<Vec<Output>> {
        let outputs = self.connection.request(GET_OUTPUTS, b"")?;
        let entries = outputs
            .as_array()
            .ok_or_else(|| AdapterError::Internal("outputs reply is not a list".into()))?;
        Ok(entries
            .iter()
            .filter_map(|entry| {
                let (x, y, width, height) = rectangle(entry);
                Some(Output {
                    name: entry.get("name").and_then(Value::as_str)?.to_string(),
                    width: width?,
                    height: height?,
                    scale: entry.get("scale").and_then(Value::as_f64).unwrap_or(1.0),
                    x: x?,
                    y: y?,
                    enabled: entry.get("active").and_then(Value::as_bool) == Some(true),
                })
            })
            .collect())
    }

    fn workspaces(&mut self) -> AdapterResult<Vec<Workspace>> {
        let workspaces = self.connection.request(GET_WORKSPACES, b"")?;
        let entries = workspaces
            .as_array()
            .ok_or_else(|| AdapterError::Internal("workspaces reply is not a list".into()))?;
        Ok(entries
            .iter()
            .filter_map(|entry| {
                let name = entry.get("name").and_then(Value::as_str)?.to_string();
                Some(Workspace {
                    id: name.clone(),
                    name,
                    active: entry.get("focused").and_then(Value::as_bool) == Some(true),
                })
            })
            .collect())
    }

    fn windows(&mut self) -> AdapterResult<Vec<Window>> {
        Ok(self
            .tree_windows()?
            .into_iter()
            .map(|entry| entry.window)
            .collect())
    }

    fn activate_workspace(&mut self, workspace_id: &str) -> AdapterResult<()> {
        if !self
            .workspaces()?
            .iter()
            .any(|workspace| workspace.id == workspace_id)
        {
            return Err(AdapterError::NotFound(format!(
                "no workspace {workspace_id}"
            )));
        }
        self.run(&format!(
            "workspace --no-auto-back-and-forth {workspace_id}"
        ))
    }

    fn focus_window(&mut self, window_id: &WindowSessionId) -> AdapterResult<()> {
        let target = self.tree_window(window_id)?.con_id;
        self.run(&format!("[con_id={target}] focus"))
    }

    fn move_window(&mut self, window_id: &WindowSessionId, x: i32, y: i32) -> AdapterResult<()> {
        let target = self.floating_target(window_id)?;
        self.run(&format!("[con_id={target}] move absolute position {x} {y}"))
    }

    fn resize_window(
        &mut self,
        window_id: &WindowSessionId,
        width: u32,
        height: u32,
    ) -> AdapterResult<()> {
        let target = self.floating_target(window_id)?;
        self.run(&format!(
            "[con_id={target}] resize set width {width} px height {height} px"
        ))
    }

    fn set_window_state(
        &mut self,
        window_id: &WindowSessionId,
        state: &WindowState,
    ) -> AdapterResult<()> {
        let target = self.tree_window(window_id)?.con_id;
        match state {
            WindowState::Fullscreen => self.run(&format!("[con_id={target}] fullscreen enable")),
            WindowState::Normal => self.run(&format!("[con_id={target}] fullscreen disable")),
            WindowState::Minimized | WindowState::Maximized => Err(AdapterError::Unsupported(
                "this compositor has no minimize or maximize window state (C-03)".into(),
            )),
        }
    }

    fn close_request(&mut self, window_id: &WindowSessionId) -> AdapterResult<()> {
        let target = self.tree_window(window_id)?.con_id;
        self.run(&format!("[con_id={target}] kill"))
    }
}

pub struct SwayEventSource {
    connection: Connection,
}

impl SwayEventSource {
    pub fn connect(socket: &Path) -> AdapterResult<Self> {
        let mut connection = Connection::open(socket)?;
        let reply = connection.request(SUBSCRIBE, br#"["window","workspace","output"]"#)?;
        if reply.get("success").and_then(Value::as_bool) != Some(true) {
            return Err(AdapterError::Unavailable(
                "compositor refused the event subscription".into(),
            ));
        }
        Ok(Self { connection })
    }

    pub fn from_environment() -> AdapterResult<Self> {
        let socket = std::env::var_os("SWAYSOCK")
            .ok_or_else(|| AdapterError::Unavailable("SWAYSOCK is not set".into()))?;
        Self::connect(Path::new(&socket))
    }
}

impl EventSource for SwayEventSource {
    fn next_change(&mut self) -> AdapterResult<Option<CompositorChange>> {
        loop {
            let (kind, _) = match self.connection.receive() {
                Ok(message) => message,
                Err(AdapterError::Unavailable(_)) => return Ok(None),
                Err(error) => return Err(error),
            };
            match kind {
                EVENT_WINDOW => return Ok(Some(CompositorChange::Windows)),
                EVENT_WORKSPACE => return Ok(Some(CompositorChange::Workspaces)),
                EVENT_OUTPUT => return Ok(Some(CompositorChange::Outputs)),
                _ => continue,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree() -> Value {
        serde_json::json!({
            "type": "root", "nodes": [{
                "type": "output", "name": "HEADLESS-1", "nodes": [{
                    "type": "workspace", "name": "1", "nodes": [{
                        "type": "con", "id": 7, "name": "editor", "app_id": "foot",
                        "focused": true, "fullscreen_mode": 0,
                        "rect": {"x": 0, "y": 45, "width": 1280, "height": 675},
                        "deco_rect": {"x": 0, "y": 20, "width": 1280, "height": 25},
                        "nodes": [], "floating_nodes": []
                    }], "floating_nodes": [{
                        "type": "floating_con", "id": 9, "name": "player",
                        "window_properties": {"class": "mpv"},
                        "focused": false, "fullscreen_mode": 1,
                        "rect": {"x": 40, "y": 60, "width": 400, "height": 300},
                        "nodes": [], "floating_nodes": []
                    }]
                }]
            }]
        })
    }

    #[test]
    fn reads_leaf_windows_with_workspace_and_state() {
        let mut windows = Vec::new();
        collect_windows(&tree(), None, &mut windows);
        assert_eq!(windows.len(), 2);
        let tiled = &windows[0];
        assert_eq!(tiled.window.id, WindowSessionId("sway-con-7".into()));
        assert_eq!(tiled.window.app_id, "foot");
        assert_eq!(tiled.window.workspace_id.as_deref(), Some("1"));
        assert_eq!(
            (tiled.window.y, tiled.window.height),
            (Some(20), Some(700)),
            "the reported window includes its decorations"
        );
        assert_eq!(tiled.window.state, WindowState::Normal);
        assert!(!tiled.floating);
        let floating = &windows[1];
        assert_eq!(floating.window.app_id, "mpv");
        assert_eq!(floating.window.state, WindowState::Fullscreen);
        assert!(floating.floating);
    }

    #[test]
    fn rejects_identifiers_from_another_session_shape() {
        assert!(con_id(&WindowSessionId("sway-con-12".into())).is_ok());
        assert!(matches!(
            con_id(&WindowSessionId("12".into())),
            Err(AdapterError::NotFound(_))
        ));
    }
}
