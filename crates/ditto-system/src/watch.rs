//! inotify on every `applications/` tree. The thread sleeps in `poll` with no
//! timeout until an event or shutdown arrives; only while a burst is being
//! debounced does it use a timeout. A missing directory is watched through its
//! nearest existing ancestor, so creating `~/.local/share/applications`
//! later is noticed without polling.

use std::collections::HashMap;
use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread::JoinHandle;

use crate::real::{Shared, DEBOUNCE};

const TREE_MASK: u32 = libc::IN_CREATE
    | libc::IN_DELETE
    | libc::IN_MOVED_FROM
    | libc::IN_MOVED_TO
    | libc::IN_CLOSE_WRITE
    | libc::IN_ATTRIB
    | libc::IN_DELETE_SELF
    | libc::IN_MOVE_SELF;
const ANCESTOR_MASK: u32 = libc::IN_CREATE | libc::IN_MOVED_TO | libc::IN_ONLYDIR;

pub struct Watcher {
    stop: OwnedFd,
    thread: Option<JoinHandle<()>>,
}

impl Watcher {
    pub fn start(shared: Arc<Shared>) -> io::Result<Self> {
        // SAFETY: plain syscalls; the returned descriptors are checked and owned below.
        let inotify = unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) };
        if inotify < 0 {
            return Err(io::Error::last_os_error());
        }
        let inotify = unsafe { OwnedFd::from_raw_fd(inotify) };
        let stop = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if stop < 0 {
            return Err(io::Error::last_os_error());
        }
        let stop = unsafe { OwnedFd::from_raw_fd(stop) };
        let stop_raw = stop.as_raw_fd();
        let mut watches = Watches {
            fd: inotify,
            ancestors: HashMap::new(),
        };
        watches.refresh(&shared.config.application_dirs);
        // A change between the initial scan and the first watch would be lost.
        shared.rescan();
        let thread = std::thread::Builder::new()
            .name("ditto-app-index".into())
            .spawn(move || watches.run(&shared, stop_raw))?;
        Ok(Self {
            stop,
            thread: Some(thread),
        })
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        let one: u64 = 1;
        // SAFETY: writing 8 bytes to our own eventfd.
        unsafe { libc::write(self.stop.as_raw_fd(), (&one as *const u64).cast(), 8) };
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

struct Watches {
    fd: OwnedFd,
    /// Ancestor watch → the child name that would lead to a missing tree.
    ancestors: HashMap<i32, Vec<Vec<u8>>>,
}

impl Watches {
    fn add(&self, path: &Path, mask: u32) -> Option<i32> {
        let path = CString::new(path.as_os_str().as_bytes()).ok()?;
        // SAFETY: valid NUL-terminated path; the kernel copies it.
        let wd = unsafe { libc::inotify_add_watch(self.fd.as_raw_fd(), path.as_ptr(), mask) };
        (wd >= 0).then_some(wd)
    }

    /// Watch every existing tree recursively; for a missing one, its nearest
    /// existing ancestor. Re-adding an existing watch returns the same wd.
    fn refresh(&mut self, roots: &[PathBuf]) {
        self.ancestors.clear();
        for root in roots {
            if root.is_dir() {
                self.add_tree(root, 0);
                continue;
            }
            let mut child = root.as_path();
            while let Some(parent) = child.parent() {
                if parent.is_dir() {
                    if let (Some(wd), Some(name)) =
                        (self.add(parent, ANCESTOR_MASK), child.file_name())
                    {
                        self.ancestors
                            .entry(wd)
                            .or_default()
                            .push(name.as_bytes().to_vec());
                    }
                    break;
                }
                child = parent;
            }
        }
    }

    fn add_tree(&self, dir: &Path, depth: usize) {
        if depth > 8 || self.add(dir, TREE_MASK).is_none() {
            return;
        }
        if let Ok(read) = std::fs::read_dir(dir) {
            for item in read.flatten() {
                if item.path().is_dir() {
                    self.add_tree(&item.path(), depth + 1);
                }
            }
        }
    }

    /// Whether the buffer holds an event that can change the index.
    fn relevant(&self, buffer: &[u8]) -> bool {
        let header = std::mem::size_of::<libc::inotify_event>();
        let mut offset = 0;
        let mut relevant = false;
        while offset + header <= buffer.len() {
            // SAFETY: the kernel writes whole events; read_unaligned copes with alignment.
            let event: libc::inotify_event =
                unsafe { std::ptr::read_unaligned(buffer[offset..].as_ptr().cast()) };
            let name_start = offset + header;
            let name_end = (name_start + event.len as usize).min(buffer.len());
            let name: &[u8] = buffer[name_start..name_end]
                .split(|b| *b == 0)
                .next()
                .unwrap_or_default();
            relevant |= match self.ancestors.get(&event.wd) {
                Some(wanted) => wanted.iter().any(|w| w.as_slice() == name),
                None => event.mask & libc::IN_Q_OVERFLOW != 0 || event.mask & TREE_MASK != 0,
            };
            offset = name_end;
        }
        relevant
    }

    fn run(mut self, shared: &Shared, stop: i32) {
        let mut buffer = vec![0u8; 16 * 1024];
        let mut pending = false;
        loop {
            let mut fds = [
                libc::pollfd {
                    fd: self.fd.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: stop,
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            let timeout = if pending {
                DEBOUNCE.as_millis() as i32
            } else {
                -1
            };
            // SAFETY: two valid pollfd structs.
            let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) };
            if ready < 0 {
                if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return;
            }
            if fds[1].revents != 0 {
                return;
            }
            if ready == 0 {
                // Quiet for DEBOUNCE: new subdirectories need watches before
                // the rescan, or files created in them right now are missed.
                pending = false;
                self.refresh(&shared.config.application_dirs);
                shared.rescan();
                continue;
            }
            loop {
                // SAFETY: the buffer is valid for its length.
                let read = unsafe {
                    libc::read(
                        self.fd.as_raw_fd(),
                        buffer.as_mut_ptr().cast(),
                        buffer.len(),
                    )
                };
                if read <= 0 {
                    break;
                }
                pending |= self.relevant(&buffer[..read as usize]);
            }
        }
    }
}
