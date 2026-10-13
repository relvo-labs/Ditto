//! Private context the person attaches to a message (G2-CORE-03, PLAT-02): a
//! text file under their home directory, the clipboard, or a screenshot.
//! Core takes it only at the person's explicit request (the Shell's scope),
//! holds the content in memory, never logs or stores it, and hands it to the
//! Agent only for the one turn it was attached to. Conversations keep the
//! reference (label, size, hash), never the content.
use crate::error::CoreError;
use ditto_protocol::{
    agent::{
        ContextAcquireInput, ContextKind, ContextPayload, ContextPreviewOutput, ContextReference,
    },
    PermissionDeniedReason, UnavailableReason,
};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    ffi::CString,
    fs::File,
    io::Read,
    os::{
        fd::{FromRawFd, OwnedFd},
        unix::{ffi::OsStrExt, fs::MetadataExt},
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Mutex,
    time::{Duration, Instant},
};

/// Text beyond this is cut (the reference says so).
pub const TEXT_LIMIT: usize = 64 * 1024;
/// A capture larger than this is refused.
pub const IMAGE_LIMIT: usize = 8 * 1024 * 1024;
/// Unsent context is released after this.
pub const TTL: Duration = Duration::from_secs(30 * 60);
const HELD_LIMIT: usize = 16;
const PREVIEW_CHARS: usize = 2_000;
const WL_PASTE: &str = "/usr/bin/wl-paste";
const GRIM: &str = "/usr/bin/grim";

enum Content {
    Text(String),
    Image { png: Vec<u8>, size: [u32; 2] },
}

struct Held {
    reference: ContextReference,
    owner: String,
    content: Content,
    turn: Option<String>,
    taken: Instant,
}

#[derive(Default)]
pub struct ContextBroker {
    held: Mutex<HashMap<String, Held>>,
}

fn unsupported(message: &str) -> CoreError {
    CoreError::unavailable(UnavailableReason::SystemUnavailable, message)
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Valid UTF-8 text, cut at `TEXT_LIMIT` on a character boundary.
fn text_of(mut bytes: Vec<u8>) -> Result<(String, bool), CoreError> {
    let truncated = bytes.len() > TEXT_LIMIT;
    if truncated {
        bytes.truncate(TEXT_LIMIT);
        // Drop an incomplete trailing character from the cut.
        while !bytes.is_empty() && std::str::from_utf8(&bytes).is_err() {
            bytes.pop();
        }
    }
    let text = String::from_utf8(bytes)
        .map_err(|_| CoreError::invalid("only text files can be attached"))?;
    if text.contains('\0') {
        return Err(CoreError::invalid("only text files can be attached"));
    }
    Ok((text, truncated))
}

/// `struct open_how` of linux/openat2.h (libc marks its own non-exhaustive).
#[repr(C)]
struct OpenHow {
    flags: u64,
    mode: u64,
    resolve: u64,
}

/// Open `path` for reading only if it is a regular file beneath `home`,
/// reached without following any symbolic link and without crossing a
/// mount — checked by the kernel during the open itself (openat2), so a
/// path swapped between check and open cannot escape.
pub fn open_beneath(home: &Path, path: &Path) -> Result<File, CoreError> {
    let relative = path.strip_prefix(home).map_err(|_| {
        CoreError::denied(
            PermissionDeniedReason::PolicyDenied,
            Some("desktop.context"),
        )
    })?;
    if relative.as_os_str().is_empty() {
        return Err(CoreError::invalid("choose a file, not the home directory"));
    }
    let home_c = CString::new(home.as_os_str().as_bytes())
        .map_err(|_| CoreError::invalid("invalid path"))?;
    // SAFETY: opening a directory path we own the string for.
    let dir = unsafe {
        libc::open(
            home_c.as_ptr(),
            libc::O_PATH | libc::O_DIRECTORY | libc::O_CLOEXEC,
        )
    };
    if dir < 0 {
        return Err(unsupported("the home directory cannot be opened"));
    }
    // SAFETY: a new descriptor that we own.
    let dir = unsafe { OwnedFd::from_raw_fd(dir) };
    let rel_c = CString::new(relative.as_os_str().as_bytes())
        .map_err(|_| CoreError::invalid("invalid path"))?;
    let how = OpenHow {
        flags: (libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOCTTY | libc::O_NONBLOCK) as u64,
        mode: 0,
        resolve: libc::RESOLVE_BENEATH
            | libc::RESOLVE_NO_SYMLINKS
            | libc::RESOLVE_NO_MAGICLINKS
            | libc::RESOLVE_NO_XDEV,
    };
    // SAFETY: openat2 with a valid dirfd, path and open_how of its size.
    let fd = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            std::os::fd::AsRawFd::as_raw_fd(&dir),
            rel_c.as_ptr(),
            &how as *const OpenHow,
            std::mem::size_of::<OpenHow>(),
        )
    };
    if fd < 0 {
        let error = std::io::Error::last_os_error();
        return Err(match error.raw_os_error() {
            Some(libc::ENOENT) => CoreError::not_found("file"),
            Some(libc::ELOOP | libc::EXDEV | libc::EACCES | libc::EPERM) => CoreError::denied(
                PermissionDeniedReason::PolicyDenied,
                Some("desktop.context"),
            ),
            _ => CoreError::invalid("the file cannot be opened"),
        });
    }
    // SAFETY: a new descriptor that we own.
    let file = unsafe { File::from_raw_fd(fd as i32) };
    let metadata = file
        .metadata()
        .map_err(|_| CoreError::invalid("the file cannot be read"))?;
    if !metadata.file_type().is_file() || metadata.nlink() == 0 {
        return Err(CoreError::invalid("only regular files can be attached"));
    }
    Ok(file)
}

/// Run a fixed helper with a deadline and a cap on what it may print.
fn run_bounded(
    program: &str,
    args: &[&str],
    limit: usize,
    deadline: Duration,
) -> Result<Vec<u8>, CoreError> {
    if !Path::new(program).is_file() {
        return Err(unsupported("this desktop has no way to take that context"));
    }
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| unsupported("the context helper could not start"))?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let reader = std::thread::spawn(move || {
        let mut data = Vec::new();
        let _ = (&mut stdout).take(limit as u64 + 1).read_to_end(&mut data);
        data
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if started.elapsed() < deadline => {
                std::thread::sleep(Duration::from_millis(10))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let data = reader.join().unwrap_or_default();
    match status {
        Some(status) if status.success() => Ok(data),
        Some(_) => Err(CoreError::not_found("nothing to take")),
        None => Err(CoreError::new(
            ditto_protocol::ErrorName::Timeout,
            "the context helper did not finish",
        )),
    }
}

/// Width and height from a PNG's IHDR chunk.
fn png_size(png: &[u8]) -> Option<[u32; 2]> {
    if png.len() < 24 || &png[..8] != b"\x89PNG\r\n\x1a\n" || &png[12..16] != b"IHDR" {
        return None;
    }
    let read = |at: usize| u32::from_be_bytes([png[at], png[at + 1], png[at + 2], png[at + 3]]);
    Some([read(16), read(20)])
}

impl ContextBroker {
    pub fn acquire(
        &self,
        owner: &str,
        input: &ContextAcquireInput,
        home: &Path,
        locked: bool,
        primary_output: Option<String>,
    ) -> Result<ContextReference, CoreError> {
        self.sweep();
        if self.held.lock().expect("context").len() >= HELD_LIMIT {
            return Err(CoreError::invalid(
                "too much context is attached; remove some first",
            ));
        }
        // A locked screen gives nothing away, whatever asks.
        if locked && input.kind != ContextKind::File {
            return Err(CoreError::unavailable(
                UnavailableReason::SessionLocked,
                "the session is locked",
            ));
        }
        let (label, mime, content, truncated, raw_len, hash) = match input.kind {
            ContextKind::File => {
                let path = PathBuf::from(
                    input
                        .path
                        .as_deref()
                        .ok_or_else(|| CoreError::invalid("a file path is required"))?,
                );
                if !path.is_absolute() {
                    return Err(CoreError::invalid("the path must be absolute"));
                }
                let mut file = open_beneath(home, &path)?;
                let mut bytes = Vec::new();
                (&mut file)
                    .take(TEXT_LIMIT as u64 + 1)
                    .read_to_end(&mut bytes)
                    .map_err(|_| CoreError::invalid("the file cannot be read"))?;
                let size = file
                    .metadata()
                    .map(|m| m.len())
                    .unwrap_or(bytes.len() as u64);
                let (text, truncated) = text_of(bytes)?;
                let hash = digest(text.as_bytes());
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                (
                    name,
                    "text/plain".to_string(),
                    Content::Text(text),
                    truncated,
                    size,
                    hash,
                )
            }
            ContextKind::Clipboard => {
                let bytes = run_bounded(
                    WL_PASTE,
                    &["--no-newline", "--type", "text/plain;charset=utf-8"],
                    TEXT_LIMIT,
                    Duration::from_secs(2),
                )
                .or_else(|_| {
                    run_bounded(
                        WL_PASTE,
                        &["--no-newline", "--type", "text"],
                        TEXT_LIMIT,
                        Duration::from_secs(2),
                    )
                })?;
                if bytes.is_empty() {
                    return Err(CoreError::not_found("the clipboard holds no text"));
                }
                let (text, truncated) = text_of(bytes)?;
                let size = text.len() as u64;
                let hash = digest(text.as_bytes());
                (
                    "clipboard".to_string(),
                    "text/plain".to_string(),
                    Content::Text(text),
                    truncated,
                    size,
                    hash,
                )
            }
            ContextKind::Capture => {
                let output = input
                    .output
                    .clone()
                    .or(primary_output)
                    .ok_or_else(|| unsupported("no output to capture"))?;
                if output.is_empty() || output.len() > 64 || output.contains('\0') {
                    return Err(CoreError::invalid("invalid output name"));
                }
                // Half scale keeps a 1080p screen under a megabyte or two.
                let png = run_bounded(
                    GRIM,
                    &["-o", &output, "-s", "0.5", "-t", "png", "-"],
                    IMAGE_LIMIT,
                    Duration::from_secs(5),
                )?;
                if png.len() > IMAGE_LIMIT {
                    return Err(CoreError::invalid("the capture is too large"));
                }
                let size =
                    png_size(&png).ok_or_else(|| unsupported("the capture is not a PNG image"))?;
                let hash = digest(&png);
                let length = png.len() as u64;
                (
                    output,
                    "image/png".to_string(),
                    Content::Image { png, size },
                    false,
                    length,
                    hash,
                )
            }
        };
        let reference = ContextReference {
            context_id: format!("ctx-{}", ditto_protocol::ids::ulid()),
            kind: input.kind,
            label,
            mime,
            bytes: raw_len,
            sha256: hash,
            captured_at: ditto_store::time::now(),
            expires_at_ms: ditto_store::time::unix_millis_now().max(0) as u64
                + TTL.as_millis() as u64,
            truncated,
        };
        self.held.lock().expect("context").insert(
            reference.context_id.clone(),
            Held {
                reference: reference.clone(),
                owner: owner.into(),
                content,
                turn: None,
                taken: Instant::now(),
            },
        );
        Ok(reference)
    }

    pub fn preview(&self, owner: &str, id: &str) -> Result<ContextPreviewOutput, CoreError> {
        self.sweep();
        let held = self.held.lock().expect("context");
        let entry = held
            .get(id)
            .filter(|h| h.owner == owner)
            .ok_or_else(|| CoreError::not_found("context"))?;
        Ok(ContextPreviewOutput {
            reference: entry.reference.clone(),
            text: match &entry.content {
                Content::Text(text) => Some(text.chars().take(PREVIEW_CHARS).collect()),
                Content::Image { .. } => None,
            },
            image_size: match &entry.content {
                Content::Image { size, .. } => Some(*size),
                Content::Text(_) => None,
            },
        })
    }

    pub fn release(&self, owner: &str, id: &str) -> Result<(), CoreError> {
        let mut held = self.held.lock().expect("context");
        match held.get(id) {
            Some(entry) if entry.owner == owner => {
                held.remove(id);
                Ok(())
            }
            _ => Err(CoreError::not_found("context")),
        }
    }

    /// Bind the person's context to the turn of their message. Every id
    /// must be theirs and not yet bound to another turn.
    pub fn references(
        &self,
        owner: &str,
        ids: &[String],
    ) -> Result<Vec<ContextReference>, CoreError> {
        self.sweep();
        let held = self.held.lock().expect("context");
        ids.iter()
            .map(|id| {
                held.get(id)
                    .filter(|h| h.owner == owner && h.turn.is_none())
                    .map(|h| h.reference.clone())
                    .ok_or_else(|| CoreError::not_found("attached context is no longer available"))
            })
            .collect()
    }

    pub fn bind(&self, ids: &[String], turn_id: &str) {
        let mut held = self.held.lock().expect("context");
        for id in ids {
            if let Some(entry) = held.get_mut(id) {
                entry.turn = Some(turn_id.into());
            }
        }
    }

    pub fn payloads(&self, turn_id: &str) -> Vec<ContextPayload> {
        use base64_lite::encode;
        self.held
            .lock()
            .expect("context")
            .values()
            .filter(|h| h.turn.as_deref() == Some(turn_id))
            .map(|h| ContextPayload {
                reference: h.reference.clone(),
                text: match &h.content {
                    Content::Text(text) => Some(text.clone()),
                    Content::Image { .. } => None,
                },
                image_data_url: match &h.content {
                    Content::Image { png, .. } => {
                        Some(format!("data:image/png;base64,{}", encode(png)))
                    }
                    Content::Text(_) => None,
                },
            })
            .collect()
    }

    /// The turn ended: its context is released (nothing is kept for later).
    pub fn release_turn(&self, turn_id: &str) {
        self.held
            .lock()
            .expect("context")
            .retain(|_, h| h.turn.as_deref() != Some(turn_id));
    }

    /// A connection that went away takes its unsent context with it.
    pub fn release_owner(&self, owner: &str) {
        self.held
            .lock()
            .expect("context")
            .retain(|_, h| h.owner != owner || h.turn.is_some());
    }

    pub fn release_bound(&self) {
        self.held
            .lock()
            .expect("context")
            .retain(|_, h| h.turn.is_none());
    }

    pub fn sweep(&self) {
        self.held
            .lock()
            .expect("context")
            .retain(|_, h| h.taken.elapsed() < TTL);
    }

    pub fn held_count(&self) -> usize {
        self.held.lock().expect("context").len()
    }
}

/// Standard base64 without padding quirks; small enough not to need a crate.
mod base64_lite {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    pub fn encode(data: &[u8]) -> String {
        let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
        for chunk in data.chunks(3) {
            let b = [
                chunk[0],
                *chunk.get(1).unwrap_or(&0),
                *chunk.get(2).unwrap_or(&0),
            ];
            let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
            out.push(TABLE[(n >> 18) as usize & 63] as char);
            out.push(TABLE[(n >> 12) as usize & 63] as char);
            out.push(if chunk.len() > 1 {
                TABLE[(n >> 6) as usize & 63] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                TABLE[n as usize & 63] as char
            } else {
                '='
            });
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn home(label: &str) -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("ditto-context-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("notes")).unwrap();
        root
    }

    fn file(path: &str) -> ContextAcquireInput {
        ContextAcquireInput {
            kind: ContextKind::File,
            path: Some(path.into()),
            output: None,
        }
    }

    #[test]
    fn a_text_file_under_home_is_taken_once_and_released_with_its_turn() {
        let home = home("ok");
        std::fs::write(home.join("notes/plan.txt"), "左邊放專案，右邊放終端").unwrap();
        let broker = ContextBroker::default();
        let path = home.join("notes/plan.txt");
        let reference = broker
            .acquire("shell-1", &file(path.to_str().unwrap()), &home, false, None)
            .unwrap();
        assert_eq!(reference.label, "plan.txt");
        assert!(!reference.truncated);
        // Another connection cannot read or bind it.
        assert!(broker.preview("shell-2", &reference.context_id).is_err());
        assert!(broker
            .references("shell-2", std::slice::from_ref(&reference.context_id))
            .is_err());
        let preview = broker.preview("shell-1", &reference.context_id).unwrap();
        assert_eq!(preview.text.as_deref(), Some("左邊放專案，右邊放終端"));
        broker
            .references("shell-1", std::slice::from_ref(&reference.context_id))
            .unwrap();
        broker.bind(std::slice::from_ref(&reference.context_id), "turn-1");
        // Bound once: not attachable to another message.
        assert!(broker
            .references("shell-1", std::slice::from_ref(&reference.context_id))
            .is_err());
        assert_eq!(broker.payloads("turn-1").len(), 1);
        assert!(broker.payloads("turn-2").is_empty());
        broker.release_turn("turn-1");
        assert_eq!(broker.held_count(), 0);
    }

    #[test]
    fn escapes_links_binaries_and_other_places_are_refused() {
        let home = home("refuse");
        let outside =
            std::env::temp_dir().join(format!("ditto-context-outside-{}", std::process::id()));
        std::fs::write(&outside, "secret").unwrap();
        symlink(&outside, home.join("notes/link.txt")).unwrap();
        symlink("/etc", home.join("etc")).unwrap();
        std::fs::write(home.join("notes/blob.bin"), [0u8, 159, 146, 150]).unwrap();
        let broker = ContextBroker::default();
        let try_path =
            |p: &Path| broker.acquire("s", &file(p.to_str().unwrap()), &home, false, None);
        for denied in [
            home.join("notes/link.txt"),
            home.join("etc/passwd"),
            outside.clone(),
            PathBuf::from("/proc/self/environ"),
        ] {
            let error = try_path(&denied).unwrap_err();
            assert_eq!(
                error.name,
                ditto_protocol::ErrorName::PermissionDenied,
                "{denied:?}"
            );
        }
        assert_eq!(
            try_path(&home.join("notes/blob.bin")).unwrap_err().name,
            ditto_protocol::ErrorName::InvalidParams
        );
        assert_eq!(
            try_path(&home.join("notes")).unwrap_err().name,
            ditto_protocol::ErrorName::InvalidParams
        );
        assert_eq!(
            try_path(&home.join("notes/missing.txt")).unwrap_err().name,
            ditto_protocol::ErrorName::NotFound
        );
        assert!(broker
            .acquire("s", &file("notes/plan.txt"), &home, false, None)
            .is_err());
        let _ = std::fs::remove_file(outside);
    }

    #[test]
    fn long_text_is_cut_on_a_character_boundary() {
        let home = home("long");
        let text = "字".repeat(TEXT_LIMIT); // three bytes each
        std::fs::write(home.join("notes/long.txt"), &text).unwrap();
        let broker = ContextBroker::default();
        let reference = broker
            .acquire(
                "s",
                &file(home.join("notes/long.txt").to_str().unwrap()),
                &home,
                false,
                None,
            )
            .unwrap();
        assert!(reference.truncated);
        assert_eq!(reference.bytes, text.len() as u64);
        let payload = {
            broker.bind(std::slice::from_ref(&reference.context_id), "t");
            broker.payloads("t").remove(0)
        };
        let kept = payload.text.unwrap();
        assert!(kept.len() <= TEXT_LIMIT && kept.chars().all(|c| c == '字'));
    }

    #[test]
    fn a_locked_session_gives_no_clipboard_or_screen() {
        let broker = ContextBroker::default();
        for kind in [ContextKind::Clipboard, ContextKind::Capture] {
            let error = broker
                .acquire(
                    "s",
                    &ContextAcquireInput {
                        kind,
                        path: None,
                        output: None,
                    },
                    Path::new("/"),
                    true,
                    None,
                )
                .unwrap_err();
            assert_eq!(error.name, ditto_protocol::ErrorName::Unavailable);
        }
    }

    #[test]
    fn base64_matches_the_standard_alphabet() {
        assert_eq!(base64_lite::encode(b"Ditto"), "RGl0dG8=");
        assert_eq!(base64_lite::encode(b"ab"), "YWI=");
        assert_eq!(base64_lite::encode(b"abc"), "YWJj");
        assert_eq!(
            png_size(b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\x07\x80\0\0\x048"),
            Some([1920, 1080])
        );
    }
}
