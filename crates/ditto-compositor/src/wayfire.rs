//! Wayfire IPC backend. Like the Sway backend, window coordinates and
//! workspaces are not covered by the neutral Wayland protocols (matrix rows
//! C-04 and C-05), so this backend is compositor-bound by design and every
//! capability it serves reports that binding.
//!
//! Two differences from Sway are visible through this adapter and are not
//! hidden by it:
//!
//! * Wayfire has a **maximize and a minimize state**, so `set_window_state`
//!   serves all four states instead of refusing two (row C-03).
//! * Wayfire's workspaces are a **fixed grid per output**, not a dynamic named
//!   list. A workspace id therefore carries output and grid coordinates, and
//!   which workspace a window is on is *derived* from its geometry, because the
//!   compositor does not report it per view. The derivation is Wayfire's own
//!   rule — a workspace to the right starts one output width further along —
//!   but it is still a derivation, and row C-05 records that.
//!
//! The protocol is a 4-byte native endian length header followed by one JSON
//! object, in both directions. A reply is `{"result": "ok"}`, a listing, or
//! `{"error": "..."}`.

use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::Path,
};

use ditto_protocol::{Output, Window, WindowSessionId, WindowState, Workspace};
use serde_json::{json, Value};

use crate::{
    AdapterError, AdapterResult, CompositorAdapter, CompositorChange, EventSource, Support,
};

const VIEW_PREFIX: &str = "wayfire-view-";
const WORKSPACE_PREFIX: &str = "wayfire-ws-";
const BOUND_TO: &str = "wayfire-ipc";
/// `wf::TILED_EDGES_ALL`: all four edges tiled, which is what Wayfire calls a
/// maximized toplevel.
const TILED_ALL: u64 = 15;

/// `(wset index, column, row, view ids)` of one workspace cell.
type Cell = (i64, i64, i64, Vec<u64>);

/// Events this adapter needs. Wayfire sends only what is subscribed to, and an
/// event never carries state to consumers: it tells Core what to re-read.
const WATCHED_EVENTS: [&str; 10] = [
    "view-mapped",
    "view-unmapped",
    "view-focused",
    "view-geometry-changed",
    "view-title-changed",
    "view-fullscreen",
    "view-minimized",
    "view-tiled",
    "view-workspace-changed",
    "wset-workspace-changed",
];

struct Connection {
    stream: UnixStream,
}

impl Connection {
    fn open(socket: &Path) -> AdapterResult<Self> {
        UnixStream::connect(socket)
            .map(|stream| Self { stream })
            .map_err(|error| AdapterError::Unavailable(format!("wayfire IPC unreachable: {error}")))
    }

    fn send(&mut self, method: &str, data: Value) -> AdapterResult<()> {
        let payload =
            serde_json::to_vec(&json!({"method": method, "data": data})).map_err(|error| {
                AdapterError::Internal(format!("request not serialisable: {error}"))
            })?;
        let mut frame = Vec::with_capacity(4 + payload.len());
        frame.extend_from_slice(&(payload.len() as u32).to_ne_bytes());
        frame.extend_from_slice(&payload);
        self.stream.write_all(&frame).map_err(|error| {
            AdapterError::Unavailable(format!("wayfire IPC write failed: {error}"))
        })
    }

    fn receive(&mut self) -> AdapterResult<Value> {
        let mut header = [0_u8; 4];
        self.stream.read_exact(&mut header).map_err(|error| {
            AdapterError::Unavailable(format!("wayfire IPC connection ended: {error}"))
        })?;
        let length = u32::from_ne_bytes(header) as usize;
        let mut payload = vec![0_u8; length];
        self.stream.read_exact(&mut payload).map_err(|error| {
            AdapterError::Unavailable(format!("wayfire IPC payload truncated: {error}"))
        })?;
        serde_json::from_slice(&payload).map_err(|error| {
            AdapterError::Internal(format!("wayfire IPC payload invalid: {error}"))
        })
    }

    fn request(&mut self, method: &str, data: Value) -> AdapterResult<Value> {
        self.send(method, data)?;
        let reply = self.receive()?;
        match reply.get("error").and_then(Value::as_str) {
            Some(message) => Err(classify(method, message)),
            None => Ok(reply),
        }
    }
}

/// A refusal that names a missing object is a `NotFound`, not an internal
/// error: the caller asked about something that is gone, which is an ordinary
/// outcome in a session where windows close on their own.
fn classify(method: &str, message: &str) -> AdapterError {
    if message.contains("No view with id") || message.contains("not found") {
        AdapterError::NotFound(message.to_string())
    } else {
        AdapterError::Internal(format!("wayfire rejected `{method}`: {message}"))
    }
}

pub struct WayfireAdapter {
    connection: Connection,
    version: String,
    socket: std::path::PathBuf,
    /// `<plugin-path>/libsimple-tile.so` exists (C-15 prepare check).
    tile_plugin: bool,
    /// Tiling is on: `tiled-edges == 15` then means "in the tile tree", not
    /// maximized.
    tiling: bool,
    /// Floating geometry recorded before tiling, to restore on the way back.
    /// Runtime state of the adapter, not configuration.
    floating_before: std::collections::HashMap<u64, Value>,
    binder: Option<crate::wayfire_bindings::Binder>,
    shortcut_handler: Option<crate::ShortcutHandler>,
}

impl WayfireAdapter {
    /// Connect to the socket the `ipc` plugin listens on.
    pub fn connect(socket: &Path) -> AdapterResult<Self> {
        let mut connection = Connection::open(socket)?;
        let configuration = connection.request("wayfire/configuration", json!({}))?;
        let version = configuration
            .get("wayfire-version")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        let tile_plugin = configuration
            .get("plugin-path")
            .and_then(Value::as_str)
            .is_some_and(|path| Path::new(path).join("libsimple-tile.so").exists());
        let mut adapter = Self {
            connection,
            version,
            socket: socket.to_path_buf(),
            tile_plugin,
            tiling: false,
            floating_before: std::collections::HashMap::new(),
            binder: None,
            shortcut_handler: None,
        };
        adapter.tiling = adapter
            .plugins()
            .map(|plugins| has_tile(&plugins))
            .unwrap_or(false);
        Ok(adapter)
    }

    fn plugins(&mut self) -> AdapterResult<String> {
        let reply = self.connection.request(
            "wayfire/get-config-option",
            json!({"option": "core/plugins"}),
        )?;
        Ok(reply
            .get("value")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string())
    }

    fn set_plugins(&mut self, plugins: &str) -> AdapterResult<()> {
        self.connection
            .request(
                "wayfire/set-config-options",
                json!({"core/plugins": plugins}),
            )
            .map(|_| ())
    }

    /// Each grid cell of each output with the views on it.
    fn cells(&mut self) -> AdapterResult<Vec<Cell>> {
        let outputs = self.output_list()?;
        let views = self.view_list()?;
        let mut cells = Vec::new();
        for output in &outputs {
            let (Some(output_id), Some(wset)) =
                (number(output, "id"), number(output, "wset-index"))
            else {
                continue;
            };
            let current = output.get("workspace");
            let grid_width = current
                .and_then(|c| number(c, "grid_width"))
                .unwrap_or(1)
                .max(1);
            let grid_height = current
                .and_then(|c| number(c, "grid_height"))
                .unwrap_or(1)
                .max(1);
            for row in 0..grid_height {
                for column in 0..grid_width {
                    let members: Vec<u64> = views
                        .iter()
                        .filter(|view| number(view, "output-id") == Some(output_id))
                        .filter(|view| {
                            workspace_of(view, output).as_deref()
                                == Some(&workspace_id(output_id, column, row))
                        })
                        .filter(|view| view.get("minimized").and_then(Value::as_bool) != Some(true))
                        .filter(|view| {
                            view.get("fullscreen").and_then(Value::as_bool) != Some(true)
                        })
                        .filter_map(|view| number(view, "id").map(|id| id as u64))
                        .collect();
                    cells.push((wset, column, row, members));
                }
            }
        }
        Ok(cells)
    }

    fn set_tree(&mut self, wset: i64, column: i64, row: i64, views: &[u64]) -> AdapterResult<()> {
        let split: Vec<Value> = views
            .iter()
            .map(|id| json!({"weight": 1.0, "view-id": id}))
            .collect();
        self.connection
            .request(
                "simple-tile/set-layout",
                json!({"wset-index": wset, "workspace": {"x": column, "y": row}, "layout": {"vertical-split": split}}),
            )
            .map(|_| ())
    }

    /// Floating → tiling (D-33): load the plugin, wait until it answers,
    /// then place existing windows into the tree; Wayfire tiles only new ones.
    fn tile(&mut self) -> AdapterResult<()> {
        let plugins = self.plugins()?;
        for view in self.view_list()? {
            if view.get("tiled-edges").and_then(Value::as_u64).unwrap_or(0) == 0 {
                if let (Some(id), Some(geometry)) = (number(&view, "id"), view.get("geometry")) {
                    self.floating_before.insert(id as u64, geometry.clone());
                }
            }
        }
        if !has_tile(&plugins) {
            self.set_plugins(&format!("{} simple-tile", plugins.trim()))?;
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(1_500);
        let first_wset = self
            .output_list()?
            .iter()
            .find_map(|output| number(output, "wset-index"))
            .unwrap_or(1);
        loop {
            let probe = self.connection.request(
                "simple-tile/get-layout",
                json!({"wset-index": first_wset, "workspace": {"x": 0, "y": 0}}),
            );
            if probe.is_ok() {
                break;
            }
            if std::time::Instant::now() > deadline {
                // Put the plugin list back: prepare promised no lasting effect.
                let _ = self.set_plugins(&plugins);
                return Err(AdapterError::Unavailable(
                    "simple-tile did not load in time".into(),
                ));
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        for (wset, column, row, members) in self.cells()? {
            if !members.is_empty() {
                self.set_tree(wset, column, row, &members)?;
            }
        }
        self.tiling = true;
        Ok(())
    }

    /// Tiling → floating (D-33): empty every tree, restore the recorded
    /// floating geometry, then unload. Unloading first would leave windows at
    /// tiled geometry with no layout managing them in between.
    fn float(&mut self) -> AdapterResult<()> {
        let plugins = self.plugins()?;
        if !has_tile(&plugins) {
            self.tiling = false;
            return Ok(());
        }
        let cells = self.cells()?;
        let mut members = Vec::new();
        for (wset, column, row, views) in cells {
            self.set_tree(wset, column, row, &[])?;
            members.extend(views);
        }
        let outputs = self.output_list()?;
        for view in self.view_list()? {
            let Some(id) = number(&view, "id").map(|id| id as u64) else {
                continue;
            };
            if !members.contains(&id)
                && view.get("tiled-edges").and_then(Value::as_u64) != Some(TILED_ALL)
            {
                continue;
            }
            let geometry = self.floating_before.get(&id).cloned().unwrap_or_else(|| {
                // Opened while tiled: a default place inside the work area.
                let area = outputs
                    .iter()
                    .find(|output| number(output, "id") == number(&view, "output-id"))
                    .and_then(|output| output.get("workarea").cloned())
                    .unwrap_or(json!({"x": 0, "y": 0, "width": 1280, "height": 720}));
                let (x, y) = (number(&area, "x").unwrap_or(0), number(&area, "y").unwrap_or(0));
                let (width, height) = (number(&area, "width").unwrap_or(1280), number(&area, "height").unwrap_or(720));
                json!({"x": x + width / 8, "y": y + height / 8, "width": width * 3 / 4, "height": height * 3 / 4})
            });
            self.configure(id, json!({"tiled-edges": 0, "geometry": geometry}))?;
        }
        let remaining: Vec<&str> = plugins
            .split_whitespace()
            .filter(|plugin| *plugin != "simple-tile")
            .collect();
        self.set_plugins(&remaining.join(" "))?;
        self.floating_before.clear();
        self.tiling = false;
        Ok(())
    }

    pub fn from_environment() -> AdapterResult<Self> {
        Self::connect(Path::new(&socket_from_environment()?))
    }

    fn view_list(&mut self) -> AdapterResult<Vec<Value>> {
        let views = self
            .connection
            .request("window-rules/list-views", json!({}))?;
        Ok(views
            .as_array()
            .ok_or_else(|| AdapterError::Internal("view list is not a list".into()))?
            .iter()
            .filter(|view| {
                view.get("role").and_then(Value::as_str) == Some("toplevel")
                    && view.get("mapped").and_then(Value::as_bool) == Some(true)
            })
            .cloned()
            .collect())
    }

    fn view(&mut self, window_id: &WindowSessionId) -> AdapterResult<Value> {
        let id = view_id(window_id)?;
        let info = self
            .connection
            .request("window-rules/view-info", json!({"id": id}))?;
        info.get("info")
            .cloned()
            .ok_or_else(|| AdapterError::NotFound(format!("no window {}", window_id.0)))
    }

    fn output_list(&mut self) -> AdapterResult<Vec<Value>> {
        let outputs = self
            .connection
            .request("window-rules/list-outputs", json!({}))?;
        outputs
            .as_array()
            .cloned()
            .ok_or_else(|| AdapterError::Internal("output list is not a list".into()))
    }

    /// Wayfire's IPC reports output geometry but not the scale it is running
    /// at, so the scale is read from the configuration it was started with. A
    /// scale changed at runtime through another path would not be seen here;
    /// that gap belongs to row C-06.
    fn output_scale(&mut self, name: &str) -> f64 {
        self.connection
            .request(
                "wayfire/get-config-option",
                json!({"option": format!("output:{name}/scale")}),
            )
            .ok()
            .and_then(|reply| {
                reply
                    .get("value")
                    .and_then(Value::as_f64)
                    .or_else(|| reply.get("value").and_then(|v| v.as_str()?.parse().ok()))
            })
            .filter(|scale| *scale > 0.0)
            .unwrap_or(1.0)
    }

    /// Geometry belongs to the layout once a view is tiled, so the request is
    /// refused rather than accepted with no effect — the same stance the Sway
    /// backend takes for tiled containers.
    fn floating_geometry(&mut self, window_id: &WindowSessionId) -> AdapterResult<(u64, Value)> {
        let view = self.view(window_id)?;
        if view.get("tiled-edges").and_then(Value::as_u64).unwrap_or(0) != 0 {
            return Err(AdapterError::Unsupported(
                "tiled window geometry is owned by the compositor layout (C-04)".into(),
            ));
        }
        let geometry = view
            .get("geometry")
            .cloned()
            .ok_or_else(|| AdapterError::Internal("view has no geometry".into()))?;
        Ok((view_id(window_id)?, geometry))
    }

    fn configure(&mut self, id: u64, fields: Value) -> AdapterResult<()> {
        let mut data = json!({"id": id});
        if let (Some(target), Some(fields)) = (data.as_object_mut(), fields.as_object()) {
            for (key, value) in fields {
                target.insert(key.clone(), value.clone());
            }
        }
        self.connection
            .request("window-rules/configure-view", data)
            .map(|_| ())
    }
}

pub fn socket_from_environment() -> AdapterResult<std::ffi::OsString> {
    std::env::var_os("WAYFIRE_SOCKET")
        .or_else(|| std::env::var_os("_WAYFIRE_SOCKET"))
        .ok_or_else(|| AdapterError::Unavailable("WAYFIRE_SOCKET is not set".into()))
}

fn view_id(window_id: &WindowSessionId) -> AdapterResult<u64> {
    window_id
        .0
        .strip_prefix(VIEW_PREFIX)
        .and_then(|rest| rest.parse().ok())
        .ok_or_else(|| AdapterError::NotFound(format!("not a session window id: {}", window_id.0)))
}

/// `wayfire-ws-<output id>-<column>-<row>`. The coordinates are in the
/// compositor's own grid, so an id cannot be confused with a Sway workspace
/// name and cannot be built by hand from a display label.
fn workspace_id(output_id: i64, column: i64, row: i64) -> String {
    format!("{WORKSPACE_PREFIX}{output_id}-{column}-{row}")
}

fn parse_workspace_id(workspace_id: &str) -> AdapterResult<(i64, i64, i64)> {
    let parts: Vec<&str> = workspace_id
        .strip_prefix(WORKSPACE_PREFIX)
        .ok_or_else(|| AdapterError::NotFound(format!("no workspace {workspace_id}")))?
        .split('-')
        .collect();
    match parts.as_slice() {
        [output, column, row] => Ok((
            output
                .parse()
                .map_err(|_| AdapterError::NotFound(format!("no workspace {workspace_id}")))?,
            column
                .parse()
                .map_err(|_| AdapterError::NotFound(format!("no workspace {workspace_id}")))?,
            row.parse()
                .map_err(|_| AdapterError::NotFound(format!("no workspace {workspace_id}")))?,
        )),
        _ => Err(AdapterError::NotFound(format!(
            "no workspace {workspace_id}"
        ))),
    }
}

fn number(node: &Value, key: &str) -> Option<i64> {
    node.get(key)
        .and_then(|value| value.as_i64().or_else(|| value.as_f64().map(|v| v as i64)))
}

fn geometry(node: &Value) -> Option<(i32, i32, u32, u32)> {
    let rect = node.get("geometry")?;
    Some((
        number(rect, "x")? as i32,
        number(rect, "y")? as i32,
        number(rect, "width")?.max(0) as u32,
        number(rect, "height")?.max(0) as u32,
    ))
}

fn has_tile(plugins: &str) -> bool {
    plugins
        .split_whitespace()
        .any(|plugin| plugin == "simple-tile")
}

/// With tiling on, all four edges tiled means "in the tile tree"; it is only
/// a maximized window while floating (D-33 note).
fn window_state(view: &Value, tiling: bool) -> WindowState {
    if view.get("minimized").and_then(Value::as_bool) == Some(true) {
        WindowState::Minimized
    } else if view.get("fullscreen").and_then(Value::as_bool) == Some(true) {
        WindowState::Fullscreen
    } else if !tiling && view.get("tiled-edges").and_then(Value::as_u64) == Some(TILED_ALL) {
        WindowState::Maximized
    } else {
        WindowState::Normal
    }
}

/// Which workspace a view sits on. Wayfire lays the grid out in one continuous
/// coordinate space with the current workspace at the origin, so the cell is
/// the current one plus however many output widths the view is offset by. The
/// compositor does not report this per view; this reproduces its rule, and a
/// sticky view belongs to whichever workspace is current.
fn workspace_of(view: &Value, output: &Value) -> Option<String> {
    let output_id = number(output, "id")?;
    let (width, height) = {
        let rect = output.get("geometry")?;
        (number(rect, "width")?, number(rect, "height")?)
    };
    if width <= 0 || height <= 0 {
        return None;
    }
    let current = output.get("workspace")?;
    let (current_x, current_y) = (number(current, "x")?, number(current, "y")?);
    if view.get("sticky").and_then(Value::as_bool) == Some(true) {
        return Some(workspace_id(output_id, current_x, current_y));
    }
    let (x, y, _, _) = geometry(view)?;
    let grid_width = number(current, "grid_width").unwrap_or(1).max(1);
    let grid_height = number(current, "grid_height").unwrap_or(1).max(1);
    let column = (current_x + (x as i64).div_euclid(width)).clamp(0, grid_width - 1);
    let row = (current_y + (y as i64).div_euclid(height)).clamp(0, grid_height - 1);
    Some(workspace_id(output_id, column, row))
}

fn to_window(view: &Value, outputs: &[Value], tiling: bool) -> Option<Window> {
    let id = number(view, "id")?;
    let (x, y, width, height) = geometry(view)?;
    let output = outputs
        .iter()
        .find(|output| number(output, "id") == number(view, "output-id"));
    Some(Window {
        id: WindowSessionId(format!("{VIEW_PREFIX}{id}")),
        title: view
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        app_id: view
            .get("app-id")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string(),
        workspace_id: output.and_then(|output| workspace_of(view, output)),
        x: Some(x),
        y: Some(y),
        width: Some(width),
        height: Some(height),
        focused: view.get("activated").and_then(Value::as_bool) == Some(true),
        state: window_state(view, tiling),
    })
}

impl CompositorAdapter for WayfireAdapter {
    fn label(&self) -> String {
        format!("wayfire {}", self.version)
    }

    fn support(&self, capability_id: &str) -> Support {
        match capability_id {
            "desktop.outputs.list" => Support::bound(
                "C-06",
                BOUND_TO,
                "output enumeration read through the compositor's own IPC; scale comes from configuration, not from live state",
            ),
            "desktop.workspaces.list" | "desktop.workspaces.get" => Support::bound(
                "C-05",
                BOUND_TO,
                "a fixed grid per output, not a named list; which workspace a window is on is derived from its geometry",
            ),
            "desktop.workspaces.activate" => Support::bound(
                "C-05",
                BOUND_TO,
                "workspace switching needs the vswitch plugin; without it this capability has no path",
            ),
            "desktop.windows.list" | "desktop.windows.get" => Support::bound(
                "C-02",
                BOUND_TO,
                "window metadata read from the compositor's view list, not from foreign-toplevel",
            ),
            "desktop.windows.focus" | "desktop.windows.close_request" => Support::bound(
                "C-03",
                BOUND_TO,
                "window control issued through the compositor's own IPC",
            ),
            "desktop.windows.move" | "desktop.windows.resize" => Support::bound(
                "C-04",
                BOUND_TO,
                "coordinates apply to untiled windows only; tiled windows report unsupported",
            ),
            "desktop.windows.set_state" => Support::bound(
                "C-03",
                BOUND_TO,
                "all four states are served; minimize needs the wm-actions plugin",
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
        let entries = self.output_list()?;
        let mut outputs = Vec::with_capacity(entries.len());
        for entry in entries {
            let Some(name) = entry.get("name").and_then(Value::as_str) else {
                continue;
            };
            let name = name.to_string();
            let Some((x, y, width, height)) = geometry(&entry) else {
                continue;
            };
            let scale = self.output_scale(&name);
            outputs.push(Output {
                name,
                width,
                height,
                scale,
                x,
                y,
                enabled: true,
            });
        }
        Ok(outputs)
    }

    fn workspaces(&mut self) -> AdapterResult<Vec<Workspace>> {
        let mut workspaces = Vec::new();
        for output in self.output_list()? {
            let Some(output_id) = number(&output, "id") else {
                continue;
            };
            let Some(current) = output.get("workspace") else {
                continue;
            };
            let grid_width = number(current, "grid_width").unwrap_or(1).max(1);
            let grid_height = number(current, "grid_height").unwrap_or(1).max(1);
            let (current_x, current_y) = (
                number(current, "x").unwrap_or(0),
                number(current, "y").unwrap_or(0),
            );
            for row in 0..grid_height {
                for column in 0..grid_width {
                    workspaces.push(Workspace {
                        id: workspace_id(output_id, column, row),
                        // The grid read in reading order, so the label matches
                        // how the workspace switcher counts.
                        name: (row * grid_width + column + 1).to_string(),
                        active: column == current_x && row == current_y,
                    });
                }
            }
        }
        Ok(workspaces)
    }

    fn windows(&mut self) -> AdapterResult<Vec<Window>> {
        let outputs = self.output_list()?;
        let tiling = self.tiling;
        Ok(self
            .view_list()?
            .iter()
            .filter_map(|view| to_window(view, &outputs, tiling))
            .collect())
    }

    fn supports_layout_strategy(&self, strategy: &str) -> bool {
        match strategy {
            "floating" => true,
            "simple-tile" => self.tile_plugin,
            _ => false,
        }
    }

    fn layout_strategy(&mut self) -> AdapterResult<Option<String>> {
        let tiling = has_tile(&self.plugins()?);
        self.tiling = tiling;
        Ok(Some(if tiling { "simple-tile" } else { "floating" }.into()))
    }

    /// Options set over IPC are not written to `wayfire.ini` and are lost
    /// when Wayfire restarts; Core applies the Profile again on reconnect.
    fn set_layout_strategy(&mut self, strategy: &str) -> AdapterResult<()> {
        match strategy {
            "simple-tile" if self.tile_plugin => self.tile(),
            "simple-tile" => Err(AdapterError::Unsupported(
                "libsimple-tile.so is not installed".into(),
            )),
            "floating" => self.float(),
            other => Err(AdapterError::Unsupported(format!(
                "no layout strategy {other}"
            ))),
        }
    }

    fn supports_shortcut_binding(&self) -> bool {
        true
    }

    /// Wayfire cannot list IPC bindings (C-16); what is read back is the
    /// binder's own table of binding ids Wayfire acknowledged.
    fn shortcuts(&mut self) -> AdapterResult<Vec<ditto_protocol::profile::ShortcutBinding>> {
        Ok(self
            .binder
            .as_ref()
            .map(|binder| binder.bound())
            .unwrap_or_default())
    }

    fn bind_shortcuts(
        &mut self,
        bindings: &[ditto_protocol::profile::ShortcutBinding],
    ) -> AdapterResult<()> {
        if self.binder.as_ref().is_none_or(|binder| !binder.alive()) {
            self.binder = Some(crate::wayfire_bindings::Binder::open(
                &self.socket,
                self.shortcut_handler.clone(),
            )?);
        }
        self.binder
            .as_mut()
            .expect("binder opened")
            .replace(bindings)
    }

    fn set_shortcut_handler(&mut self, handler: crate::ShortcutHandler) {
        self.shortcut_handler = Some(handler.clone());
        if let Some(binder) = &self.binder {
            binder.set_handler(handler);
        }
    }

    fn workspace_grid(&mut self) -> AdapterResult<Option<[u32; 2]>> {
        let outputs = self.output_list()?;
        Ok(outputs.first().and_then(|output| {
            let current = output.get("workspace")?;
            Some([
                number(current, "grid_width").unwrap_or(1).max(1) as u32,
                number(current, "grid_height").unwrap_or(1).max(1) as u32,
            ])
        }))
    }

    fn activate_workspace(&mut self, workspace_id: &str) -> AdapterResult<()> {
        let (output_id, column, row) = parse_workspace_id(workspace_id)?;
        if !self
            .workspaces()?
            .iter()
            .any(|workspace| workspace.id == workspace_id)
        {
            return Err(AdapterError::NotFound(format!(
                "no workspace {workspace_id}"
            )));
        }
        self.connection
            .request(
                "vswitch/set-workspace",
                json!({"x": column, "y": row, "output-id": output_id}),
            )
            .map(|_| ())
    }

    fn focus_window(&mut self, window_id: &WindowSessionId) -> AdapterResult<()> {
        let id = view_id(window_id)?;
        self.connection
            .request("window-rules/focus-view", json!({"id": id}))
            .map(|_| ())
    }

    fn move_window(&mut self, window_id: &WindowSessionId, x: i32, y: i32) -> AdapterResult<()> {
        let (id, geometry) = self.floating_geometry(window_id)?;
        let width = number(&geometry, "width").unwrap_or(0);
        let height = number(&geometry, "height").unwrap_or(0);
        self.configure(
            id,
            json!({"geometry": {"x": x, "y": y, "width": width, "height": height}}),
        )
    }

    fn resize_window(
        &mut self,
        window_id: &WindowSessionId,
        width: u32,
        height: u32,
    ) -> AdapterResult<()> {
        let (id, geometry) = self.floating_geometry(window_id)?;
        let x = number(&geometry, "x").unwrap_or(0);
        let y = number(&geometry, "y").unwrap_or(0);
        self.configure(
            id,
            json!({"geometry": {"x": x, "y": y, "width": width, "height": height}}),
        )
    }

    fn set_window_state(
        &mut self,
        window_id: &WindowSessionId,
        state: &WindowState,
    ) -> AdapterResult<()> {
        let id = view_id(window_id)?;
        // Minimize lives in a different plugin from the rest, so leaving the
        // minimized state is its own call before anything else is set.
        let unminimize = |connection: &mut Connection| {
            connection
                .request(
                    "wm-actions/set-minimized",
                    json!({"view_id": id, "state": false}),
                )
                .map(|_| ())
        };
        match state {
            WindowState::Minimized => self
                .connection
                .request(
                    "wm-actions/set-minimized",
                    json!({"view_id": id, "state": true}),
                )
                .map(|_| ()),
            WindowState::Fullscreen => {
                unminimize(&mut self.connection)?;
                self.configure(id, json!({"fullscreen": true}))
            }
            WindowState::Maximized => {
                unminimize(&mut self.connection)?;
                self.configure(id, json!({"fullscreen": false, "tiled-edges": TILED_ALL}))
            }
            WindowState::Normal => {
                unminimize(&mut self.connection)?;
                self.configure(id, json!({"fullscreen": false, "tiled-edges": 0}))
            }
        }
    }

    fn close_request(&mut self, window_id: &WindowSessionId) -> AdapterResult<()> {
        let id = view_id(window_id)?;
        self.connection
            .request("window-rules/close-view", json!({"id": id}))
            .map(|_| ())
    }
}

pub struct WayfireEventSource {
    connection: Connection,
}

impl WayfireEventSource {
    pub fn connect(socket: &Path) -> AdapterResult<Self> {
        let mut connection = Connection::open(socket)?;
        connection.request(
            "window-rules/events/watch",
            json!({"events": WATCHED_EVENTS}),
        )?;
        Ok(Self { connection })
    }

    pub fn from_environment() -> AdapterResult<Self> {
        Self::connect(Path::new(&socket_from_environment()?))
    }
}

fn change_for(event: &str) -> Option<CompositorChange> {
    match event {
        "wset-workspace-changed" | "view-workspace-changed" | "output-wset-changed" => {
            Some(CompositorChange::Workspaces)
        }
        "output-added" | "output-removed" | "output-layout-changed" => {
            Some(CompositorChange::Outputs)
        }
        event if event.starts_with("view-") => Some(CompositorChange::Windows),
        _ => None,
    }
}

impl EventSource for WayfireEventSource {
    fn next_change(&mut self) -> AdapterResult<Option<CompositorChange>> {
        loop {
            let message = match self.connection.receive() {
                Ok(message) => message,
                Err(AdapterError::Unavailable(_)) => return Ok(None),
                Err(error) => return Err(error),
            };
            let Some(event) = message.get("event").and_then(Value::as_str) else {
                continue;
            };
            if let Some(change) = change_for(event) {
                return Ok(Some(change));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output() -> Value {
        json!({
            "id": 1, "name": "HEADLESS-1",
            "geometry": {"x": 0.0, "y": 0.0, "width": 1280.0, "height": 720.0},
            "workarea": {"x": 0.0, "y": 40.0, "width": 1280.0, "height": 680.0},
            "workspace": {"x": 0, "y": 0, "grid_width": 3, "grid_height": 3}
        })
    }

    fn view() -> Value {
        json!({
            "id": 4, "title": "editor", "app-id": "foot", "role": "toplevel",
            "mapped": true, "activated": true, "sticky": false,
            "output-id": 1, "tiled-edges": 0, "fullscreen": false, "minimized": false,
            "geometry": {"x": 120.0, "y": 90.0, "width": 500.0, "height": 400.0}
        })
    }

    #[test]
    fn reads_a_view_with_its_derived_workspace() {
        let window = to_window(&view(), &[output()], false).expect("window");
        assert_eq!(window.id, WindowSessionId("wayfire-view-4".into()));
        assert_eq!(window.app_id, "foot");
        assert_eq!((window.x, window.y), (Some(120), Some(90)));
        assert_eq!(window.state, WindowState::Normal);
        assert_eq!(window.workspace_id.as_deref(), Some("wayfire-ws-1-0-0"));
    }

    #[test]
    fn a_view_one_output_width_to_the_right_is_on_the_next_workspace() {
        let mut view = view();
        view["geometry"]["x"] = json!(1400.0);
        let window = to_window(&view, &[output()], false).expect("window");
        assert_eq!(window.workspace_id.as_deref(), Some("wayfire-ws-1-1-0"));
    }

    #[test]
    fn a_sticky_view_reports_the_current_workspace() {
        let mut view = view();
        view["sticky"] = json!(true);
        view["geometry"]["x"] = json!(2600.0);
        let mut output = output();
        output["workspace"]["x"] = json!(2);
        let window = to_window(&view, &[output], false).expect("window");
        assert_eq!(window.workspace_id.as_deref(), Some("wayfire-ws-1-2-0"));
    }

    #[test]
    fn distinguishes_all_four_window_states() {
        assert_eq!(window_state(&view(), false), WindowState::Normal);
        let mut maximized = view();
        maximized["tiled-edges"] = json!(TILED_ALL);
        assert_eq!(window_state(&maximized, false), WindowState::Maximized);
        // With tiling on, all edges tiled means "in the tree", not maximized.
        assert_eq!(window_state(&maximized, true), WindowState::Normal);
        let mut fullscreen = view();
        fullscreen["fullscreen"] = json!(true);
        assert_eq!(window_state(&fullscreen, false), WindowState::Fullscreen);
        let mut minimized = view();
        minimized["minimized"] = json!(true);
        assert_eq!(window_state(&minimized, false), WindowState::Minimized);
    }

    #[test]
    fn rejects_identifiers_from_another_session_shape() {
        assert!(view_id(&WindowSessionId("wayfire-view-12".into())).is_ok());
        assert!(matches!(
            view_id(&WindowSessionId("sway-con-12".into())),
            Err(AdapterError::NotFound(_))
        ));
        assert_eq!(parse_workspace_id("wayfire-ws-1-2-0"), Ok((1, 2, 0)));
        assert!(matches!(
            parse_workspace_id("2"),
            Err(AdapterError::NotFound(_))
        ));
    }

    #[test]
    fn maps_events_to_the_state_that_must_be_re_read() {
        assert_eq!(change_for("view-mapped"), Some(CompositorChange::Windows));
        assert_eq!(
            change_for("wset-workspace-changed"),
            Some(CompositorChange::Workspaces)
        );
        assert_eq!(change_for("output-added"), Some(CompositorChange::Outputs));
        assert_eq!(change_for("plugin-activation-state-changed"), None);
    }
}
