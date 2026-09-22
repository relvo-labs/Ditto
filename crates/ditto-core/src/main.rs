//! G0 Core process: owns the IPC socket, binds to one compositor, and starts
//! the session clients itself so their identity comes from the launcher rather
//! than from what they claim in a message.

mod launcher;

use std::{env, io, os::unix::net::UnixListener, path::PathBuf, sync::Arc, thread, time::Duration};

use ditto_compositor::{fixture::FixtureCompositor, sway, wayfire, CompositorAdapter, EventSource};
use ditto_core::{
    identity::IdentityRegistry,
    session::{self, Session},
};

const USAGE: &str = "usage: ditto-core serve [--compositor wayfire|sway|fixture]\n\
                     \x20            [--launch \"<kind> <version> <executable> [args...]\"]...\n\
                     \x20            [--development]\n\
                     G0 diagnostics and session service. Not a rescue entry point.";

enum Compositor {
    Wayfire,
    Sway,
    Fixture,
}

struct Options {
    compositor: Compositor,
    launches: Vec<String>,
    development: bool,
}

fn parse_options() -> io::Result<Options> {
    let mut arguments = env::args().skip(1);
    if arguments.next().as_deref() != Some("serve") {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, USAGE));
    }
    let mut options = Options {
        // Whichever compositor is actually running here. Wayfire is the
        // selected compositor (D-02) and is checked first; Sway is abandoned
        // and only reached by an explicit socket or flag. A session with
        // neither gets the fixture and says so in its label.
        compositor: if env::var_os("WAYFIRE_SOCKET").is_some() {
            Compositor::Wayfire
        } else if env::var_os("SWAYSOCK").is_some() {
            Compositor::Sway
        } else {
            Compositor::Fixture
        },
        launches: Vec::new(),
        development: false,
    };
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--compositor" => {
                options.compositor = match arguments.next().as_deref() {
                    Some("wayfire") => Compositor::Wayfire,
                    Some("sway") => Compositor::Sway,
                    Some("fixture") => Compositor::Fixture,
                    _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, USAGE)),
                }
            }
            "--launch" => options.launches.push(
                arguments
                    .next()
                    .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, USAGE))?,
            ),
            "--development" => options.development = true,
            _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, USAGE)),
        }
    }
    if options.development && !options.launches.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "--development shares one token with every caller and cannot be combined with --launch",
        ));
    }
    Ok(options)
}

fn connect(
    compositor: &Compositor,
) -> io::Result<(Box<dyn CompositorAdapter>, Box<dyn EventSource>)> {
    match compositor {
        Compositor::Wayfire => {
            let adapter = wayfire::WayfireAdapter::from_environment()
                .map_err(|error| io::Error::other(format!("{error:?}")))?;
            let events = wayfire::WayfireEventSource::from_environment()
                .map_err(|error| io::Error::other(format!("{error:?}")))?;
            Ok((Box::new(adapter), Box::new(events)))
        }
        Compositor::Sway => {
            let adapter = sway::SwayAdapter::from_environment()
                .map_err(|error| io::Error::other(format!("{error:?}")))?;
            let events = sway::SwayEventSource::from_environment()
                .map_err(|error| io::Error::other(format!("{error:?}")))?;
            Ok((Box::new(adapter), Box::new(events)))
        }
        Compositor::Fixture => {
            let (adapter, events) = FixtureCompositor::paired();
            Ok((Box::new(adapter), Box::new(events)))
        }
    }
}

/// Follow the compositor for as long as the process lives. A compositor restart
/// takes capabilities offline, then re-reads state; nothing is replayed.
fn follow_compositor(
    session: Arc<Session>,
    compositor: Compositor,
    mut source: Box<dyn EventSource>,
) {
    loop {
        session::pump(&session, source.as_mut());
        if matches!(compositor, Compositor::Fixture) {
            return;
        }
        loop {
            thread::sleep(Duration::from_secs(1));
            match connect(&compositor) {
                Ok((adapter, events)) => {
                    if session.reconnect(adapter).is_ok() {
                        source = events;
                        eprintln!("compositor reconnected");
                        break;
                    }
                }
                Err(error) => eprintln!("compositor still unreachable: {error}"),
            }
        }
    }
}

fn socket_path() -> io::Result<PathBuf> {
    let runtime =
        PathBuf::from(env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is required")
        })?);
    let directory = runtime.join("ditto");
    std::fs::create_dir_all(&directory)?;
    ditto_core::set_private_permissions(&directory, 0o700)?;
    Ok(directory.join("core.sock"))
}

fn bind(path: &PathBuf) -> io::Result<UnixListener> {
    if path.exists() {
        match std::os::unix::net::UnixStream::connect(path) {
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "core socket already active",
                ))
            }
            Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                std::fs::remove_file(path)?
            }
            Err(error) => return Err(error),
        }
    }
    let listener = UnixListener::bind(path)?;
    ditto_core::set_private_permissions(path, 0o600)?;
    Ok(listener)
}

fn main() -> io::Result<()> {
    let options = parse_options()?;
    let development_token = if options.development {
        Some(
            env::var("DITTO_DEV_TOKEN")
                .ok()
                .filter(|token| !token.is_empty())
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "DITTO_DEV_TOKEN is required with --development",
                    )
                })?,
        )
    } else {
        None
    };

    let (adapter, events) = connect(&options.compositor)?;
    let session = Arc::new(Session::new(adapter));
    let path = socket_path()?;
    let listener = bind(&path)?;
    eprintln!(
        "ditto-core listening at {} (compositor: {}, online: {})",
        path.display(),
        session.compositor_label(),
        session.is_online()
    );

    {
        let session = Arc::clone(&session);
        thread::spawn(move || follow_compositor(session, options.compositor, events));
    }

    let registry = Arc::new(IdentityRegistry::new());
    let mut children = Vec::new();
    for specification in &options.launches {
        match launcher::launch(&registry, specification, &path) {
            Ok(child) => children.push(child),
            Err(error) => eprintln!("could not start `{specification}`: {error}"),
        }
    }
    if development_token.is_some() {
        eprintln!("development mode: one shared token, no launcher binding; not EX-07 evidence");
    } else if children.is_empty() {
        eprintln!("no clients launched: only processes started by this launcher can connect");
    }

    for connection in listener.incoming() {
        let stream = connection?;
        let session = Arc::clone(&session);
        let registry = Arc::clone(&registry);
        let token = development_token.clone();
        thread::spawn(move || {
            let served = match token {
                Some(token) => ditto_core::serve_connection(stream, session, &token),
                None => ditto_core::serve_bound_connection(stream, session, &registry),
            };
            if let Err(error) = served {
                eprintln!("client connection ended: {error}");
            }
        });
    }
    Ok(())
}
