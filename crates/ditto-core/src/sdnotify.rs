//! `sd_notify` for `Type=notify` and `WatchdogSec`. The watchdog is pinged
//! from the coordinator loop, not from a thread of its own, so a coordinator
//! that stops making progress really does miss the watchdog.

use std::os::unix::net::UnixDatagram;

fn send(message: &str) {
    let Some(path) = std::env::var_os("NOTIFY_SOCKET") else {
        return;
    };
    let Ok(socket) = UnixDatagram::unbound() else {
        return;
    };
    let path = path.to_string_lossy().into_owned();
    if let Some(abstract_name) = path.strip_prefix('@') {
        use std::os::linux::net::SocketAddrExt;
        if let Ok(address) =
            std::os::unix::net::SocketAddr::from_abstract_name(abstract_name.as_bytes())
        {
            let _ = socket.send_to_addr(message.as_bytes(), &address);
        }
    } else {
        let _ = socket.send_to(message.as_bytes(), path);
    }
}

pub fn ready() {
    send("READY=1");
}

pub fn watchdog() {
    send("WATCHDOG=1");
}

pub fn status(text: &str) {
    send(&format!("STATUS={text}"));
}
