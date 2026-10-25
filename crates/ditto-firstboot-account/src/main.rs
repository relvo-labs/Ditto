use ditto_firstboot_account::{unix, Engine, SystemTools};
use std::{io, path::PathBuf, time::Duration};
fn run() -> io::Result<()> {
    // SAFETY: geteuid has no preconditions. Only the root launcher may use TTY/recovery.
    if unsafe { libc::geteuid() } != 0 {
        return Err(io::Error::other("unauthorized"));
    }
    unix::protect_process()?;
    let engine = Engine {
        root: PathBuf::from("/"),
        tools: SystemTools,
    };
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let mut log = io::stderr().lock();
    match args.as_slice() {
        [] => {
            let listener = unix::activated_listener()?;
            // A socket-activated listener is ready; bound the wait if misstarted.
            listener.set_nonblocking(true)?;
            let mut poll = libc::pollfd {
                fd: std::os::fd::AsRawFd::as_raw_fd(&listener),
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: poll points to one initialized pollfd.
            if unsafe { libc::poll(&mut poll, 1, Duration::from_secs(30).as_millis() as i32) } <= 0
            {
                return Err(io::Error::other("listener timeout"));
            }
            let (stream, _) = listener.accept()?;
            let uid = match unix::greetd_uid() {
                Ok(uid) => uid,
                Err(_) => {
                    use std::io::Write;
                    // No request is consumed when the trusted identity cannot be resolved.
                    writeln!(log, "phase=authorize result=unauthorized")?;
                    let mut stream = stream;
                    stream.write_all(b"{\"ok\":false,\"error\":\"unauthorized\"}\n")?;
                    return Ok(());
                }
            };
            stream.set_nonblocking(false)?;
            engine.serve(stream, uid, &mut log)
        }
        [mode] if mode == "--recover" => engine
            .recover(&mut log)
            .map_err(|_| io::Error::other("recovery failed")),
        [mode] if mode == "--tty" => unix::tty(&engine, &mut log),
        _ => Err(io::Error::other("invalid invocation")),
    }
}
fn main() -> std::process::ExitCode {
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(_) => {
            eprintln!("phase=invocation result=internal_rollback_failed");
            std::process::ExitCode::FAILURE
        }
    }
}
