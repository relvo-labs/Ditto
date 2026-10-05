//! Global shortcuts on Wayfire (C-16, D-33 §2): temporary bindings on a
//! connection of Core's own. A binding without a command starts nothing; the
//! compositor sends `{"event": "command-binding", "binding-id": …}` back to the
//! connection that registered it, and the bindings die with that connection.
//! Wayfire cannot list them, so the table here is the only readback.

use std::{
    collections::HashMap,
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
    time::Duration,
};

use ditto_protocol::profile::ShortcutBinding;
use serde_json::{json, Value};

use crate::{AdapterError, AdapterResult, ShortcutHandler};

type Table = Arc<Mutex<HashMap<u64, ShortcutBinding>>>;

pub struct Binder {
    writer: Mutex<UnixStream>,
    replies: Mutex<mpsc::Receiver<Value>>,
    table: Table,
    handler: Arc<Mutex<Option<ShortcutHandler>>>,
    alive: Arc<AtomicBool>,
}

fn frame(value: &Value) -> Vec<u8> {
    let payload = serde_json::to_vec(value).expect("json serializes");
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_ne_bytes());
    frame.extend_from_slice(&payload);
    frame
}

fn read_frame(stream: &mut UnixStream) -> std::io::Result<Value> {
    let mut header = [0_u8; 4];
    stream.read_exact(&mut header)?;
    let mut payload = vec![0_u8; u32::from_ne_bytes(header) as usize];
    stream.read_exact(&mut payload)?;
    serde_json::from_slice(&payload).map_err(std::io::Error::other)
}

/// `Super+Shift+Space` → `<super> <shift> KEY_SPACE`, Wayfire's activator form.
pub fn wayfire_chord(chord: &str) -> Option<String> {
    let mut modifiers = Vec::new();
    let mut key = None;
    for part in chord.split('+').map(str::trim) {
        match part.to_ascii_lowercase().as_str() {
            "super" | "logo" | "meta" => modifiers.push("<super>"),
            "ctrl" | "control" => modifiers.push("<ctrl>"),
            "alt" => modifiers.push("<alt>"),
            "shift" => modifiers.push("<shift>"),
            _ => {
                if key.is_some() {
                    return None;
                }
                key = Some(part);
            }
        }
    }
    let key = key?;
    let name = match key.to_ascii_lowercase().as_str() {
        "space" => "SPACE".to_string(),
        "escape" | "esc" => "ESC".to_string(),
        "return" | "enter" => "ENTER".to_string(),
        "tab" => "TAB".to_string(),
        "backspace" => "BACKSPACE".to_string(),
        "delete" => "DELETE".to_string(),
        "left" | "right" | "up" | "down" | "home" | "end" => key.to_ascii_uppercase(),
        "pageup" => "PAGEUP".to_string(),
        "pagedown" => "PAGEDOWN".to_string(),
        other if other.len() == 1 && other.chars().all(|c| c.is_ascii_alphanumeric()) => {
            other.to_ascii_uppercase()
        }
        other
            if other.starts_with('f')
                && other[1..]
                    .parse::<u8>()
                    .is_ok_and(|n| (1..=12).contains(&n)) =>
        {
            other.to_ascii_uppercase()
        }
        _ => return None,
    };
    let mut text = modifiers.join(" ");
    if !text.is_empty() {
        text.push(' ');
    }
    text.push_str("KEY_");
    text.push_str(&name);
    Some(text)
}

impl Binder {
    pub fn open(socket: &Path, handler: Option<ShortcutHandler>) -> AdapterResult<Self> {
        let stream = UnixStream::connect(socket).map_err(|error| {
            AdapterError::Unavailable(format!("wayfire IPC unreachable: {error}"))
        })?;
        let mut reader = stream
            .try_clone()
            .map_err(|error| AdapterError::Internal(error.to_string()))?;
        let (replies, receiver) = mpsc::channel();
        let table: Table = Arc::new(Mutex::new(HashMap::new()));
        let handler = Arc::new(Mutex::new(handler));
        let alive = Arc::new(AtomicBool::new(true));
        {
            let (table, handler, alive) =
                (Arc::clone(&table), Arc::clone(&handler), Arc::clone(&alive));
            std::thread::Builder::new()
                .name("ditto-wayfire-bindings".into())
                .spawn(move || {
                    while let Ok(message) = read_frame(&mut reader) {
                        if message.get("event").and_then(Value::as_str) == Some("command-binding") {
                            let id = message
                                .get("binding-id")
                                .and_then(Value::as_u64)
                                .unwrap_or(0);
                            let command = table
                                .lock()
                                .expect("binding table")
                                .get(&id)
                                .map(|binding| binding.command.clone());
                            let handler = handler.lock().expect("binding handler").clone();
                            if let (Some(command), Some(handler)) = (command, handler) {
                                handler(&command);
                            }
                            continue;
                        }
                        if replies.send(message).is_err() {
                            break;
                        }
                    }
                    // The compositor went away: every binding went with it.
                    alive.store(false, Ordering::SeqCst);
                    table.lock().expect("binding table").clear();
                })
                .map_err(|error| AdapterError::Internal(error.to_string()))?;
        }
        Ok(Self {
            writer: Mutex::new(stream),
            replies: Mutex::new(receiver),
            table,
            handler,
            alive,
        })
    }

    pub fn alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    pub fn set_handler(&self, handler: ShortcutHandler) {
        *self.handler.lock().expect("binding handler") = Some(handler);
    }

    fn request(&self, method: &str, data: Value) -> AdapterResult<Value> {
        self.writer
            .lock()
            .expect("binding writer")
            .write_all(&frame(&json!({"method": method, "data": data})))
            .map_err(|error| {
                AdapterError::Unavailable(format!("wayfire IPC write failed: {error}"))
            })?;
        let reply = self
            .replies
            .lock()
            .expect("binding replies")
            .recv_timeout(Duration::from_secs(2))
            .map_err(|_| {
                AdapterError::Unavailable("wayfire did not answer the binding request".into())
            })?;
        match reply.get("error").and_then(Value::as_str) {
            Some(message) => Err(AdapterError::Unsupported(format!(
                "wayfire refused `{method}`: {message}"
            ))),
            None => Ok(reply),
        }
    }

    /// Make the bound set exactly `bindings`: unbind first, then bind, so an
    /// old owner of a chord never fires next to its new owner (CHG-03).
    pub fn replace(&mut self, bindings: &[ShortcutBinding]) -> AdapterResult<()> {
        let current: Vec<(u64, ShortcutBinding)> = self
            .table
            .lock()
            .expect("binding table")
            .iter()
            .map(|(id, binding)| (*id, binding.clone()))
            .collect();
        for (id, binding) in &current {
            if !bindings.contains(binding) {
                self.request("command/unregister-binding", json!({"binding-id": id}))?;
                self.table.lock().expect("binding table").remove(id);
            }
        }
        for binding in bindings {
            let already = self
                .table
                .lock()
                .expect("binding table")
                .values()
                .any(|bound| bound == binding);
            if already {
                continue;
            }
            let activator = wayfire_chord(&binding.chord).ok_or_else(|| {
                AdapterError::Unsupported(format!("chord {} has no Wayfire form", binding.chord))
            })?;
            let reply = self.request("command/register-binding", json!({"binding": activator}))?;
            let id = reply
                .get("binding-id")
                .and_then(Value::as_u64)
                .ok_or_else(|| AdapterError::Internal("register-binding returned no id".into()))?;
            self.table
                .lock()
                .expect("binding table")
                .insert(id, binding.clone());
        }
        Ok(())
    }

    pub fn bound(&self) -> Vec<ShortcutBinding> {
        let mut bound: Vec<ShortcutBinding> = self
            .table
            .lock()
            .expect("binding table")
            .values()
            .cloned()
            .collect();
        bound.sort_by(|a, b| a.chord.cmp(&b.chord));
        bound
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chords_translate_to_wayfire_activators() {
        assert_eq!(
            wayfire_chord("Super+Space").as_deref(),
            Some("<super> KEY_SPACE")
        );
        assert_eq!(
            wayfire_chord("Ctrl+Alt+t").as_deref(),
            Some("<ctrl> <alt> KEY_T")
        );
        assert_eq!(
            wayfire_chord("Super+Shift+Escape").as_deref(),
            Some("<super> <shift> KEY_ESC")
        );
        assert_eq!(wayfire_chord("Super+F9").as_deref(), Some("<super> KEY_F9"));
        assert_eq!(wayfire_chord("Super+1").as_deref(), Some("<super> KEY_1"));
        assert!(wayfire_chord("Super+Space+Tab").is_none());
        assert!(wayfire_chord("Super+Nope").is_none());
    }
}
