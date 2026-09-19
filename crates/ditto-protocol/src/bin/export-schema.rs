use std::{
    fs,
    path::{Path, PathBuf},
};

use ditto_protocol::{catalog, *};
use schemars::JsonSchema;
use serde_json::Value;

fn write_schema<T: JsonSchema>(directory: &Path, name: &str, check: bool) -> std::io::Result<()> {
    let value = serde_json::to_value(schemars::schema_for!(T))?;
    write_json(directory.join(format!("{name}.json")), &value, check)
}

fn write_json(path: PathBuf, value: &Value, check: bool) -> std::io::Result<()> {
    let mut contents = serde_json::to_string_pretty(value)?;
    contents.push('\n');
    if check {
        if fs::read_to_string(&path)? != contents {
            return Err(std::io::Error::other(format!(
                "stale schema: {}",
                path.display()
            )));
        }
        Ok(())
    } else {
        fs::write(path, contents)
    }
}

fn main() -> std::io::Result<()> {
    let check = std::env::args().skip(1).any(|arg| arg == "--check");
    let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../schema");
    fs::create_dir_all(&directory)?;
    write_schema::<Empty>(&directory, "empty", check)?;
    write_schema::<Window>(&directory, "window", check)?;
    write_schema::<Workspace>(&directory, "workspace", check)?;
    write_schema::<Output>(&directory, "output", check)?;
    write_schema::<WindowIdInput>(&directory, "window-id-input", check)?;
    write_schema::<WorkspaceIdInput>(&directory, "workspace-id-input", check)?;
    write_schema::<WindowMoveInput>(&directory, "window-move-input", check)?;
    write_schema::<WindowResizeInput>(&directory, "window-resize-input", check)?;
    write_schema::<WindowSetStateInput>(&directory, "window-set-state-input", check)?;
    write_schema::<CloseRequestOutput>(&directory, "close-request-output", check)?;
    write_schema::<OutputsListOutput>(&directory, "outputs-list-output", check)?;
    write_schema::<WorkspacesListOutput>(&directory, "workspaces-list-output", check)?;
    write_schema::<WindowsListOutput>(&directory, "windows-list-output", check)?;
    write_schema::<DesktopSnapshot>(&directory, "desktop-snapshot", check)?;
    write_schema::<EventsSubscribeInput>(&directory, "events-subscribe-input", check)?;
    write_schema::<EventsSubscribeOutput>(&directory, "events-subscribe-output", check)?;
    write_schema::<DesktopEventNotification>(&directory, "desktop-event-notification", check)?;
    write_schema::<RequestMeta>(&directory, "request-meta", check)?;
    write_schema::<ResultMeta>(&directory, "result-meta", check)?;
    write_schema::<catalog::CapabilitiesListOutput>(&directory, "capabilities-list-output", check)?;
    write_schema::<rpc::RpcRequest>(&directory, "rpc-request", check)?;
    write_schema::<rpc::RpcResponse>(&directory, "rpc-response", check)?;
    write_schema::<rpc::HandshakeInput>(&directory, "handshake-input", check)?;
    write_schema::<rpc::HandshakeOutput>(&directory, "handshake-output", check)?;
    write_json(
        directory.join("catalog.json"),
        &serde_json::to_value(catalog::catalog())?,
        check,
    )
}
