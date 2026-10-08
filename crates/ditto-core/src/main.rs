//! `ditto-core serve`: binds the IPC socket, opens the authoritative store,
//! connects to one compositor, and starts the session clients itself so their
//! identity comes from the launcher rather than from what they claim.

use std::{env, io, os::unix::net::UnixListener, path::PathBuf, sync::Arc, thread, time::Duration};

use ditto_compositor::{fixture::FixtureCompositor, sway, wayfire, CompositorAdapter, EventSource};
use ditto_core::{
    core::{Core, CoreConfig},
    identity::IdentityRegistry,
    launcher,
    session::{self, Session},
};
use ditto_protocol::rpc::CoreMode;

const USAGE: &str = "usage: ditto-core serve [--compositor wayfire|sway|fixture] [--mode normal|rescue]\n\
                     \x20            [--shell \"<kind> <version> <executable> [args...]\"]\n\
                     \x20            [--hostd \"hostd <version> <executable> [args...]\"]\n\
                     \x20            [--agent \"agent <version> <executable> [args...]\"]\n\
                     \x20            [--agent-backend \"codex-app-server <version> <sha256> <executable>\"]\n\
                     \x20            [--agent-backend-test-provider http://127.0.0.1:<port>/v1]  (fixture only)\n\
                     \x20            [--rescue-ui \"<spec>\"] [--lock \"<spec>\"]\n\
                     \x20            [--launch \"<spec>\"]... [--builtin-packages DIR] [--development]\n\
                     `--mode rescue` starts no Cordis host: native applications, history and\n\
                     restoring the last known good composition only.";

enum Compositor {
    Wayfire,
    Sway,
    Fixture,
}

struct Options {
    compositor: Compositor,
    mode: CoreMode,
    shell: Option<String>,
    hostd: Option<String>,
    agent: Option<String>,
    agent_backend: Option<String>,
    agent_backend_test_provider: Option<String>,
    rescue_ui: Option<String>,
    lock: Option<String>,
    launches: Vec<String>,
    builtin_packages: Option<PathBuf>,
    development: bool,
}

fn usage() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, USAGE)
}

fn parse_options() -> io::Result<Options> {
    let mut arguments = env::args().skip(1);
    if arguments.next().as_deref() != Some("serve") {
        return Err(usage());
    }
    let mut options = Options {
        // Wayfire is the selected compositor (D-02) and is checked first;
        // Sway is abandoned and only reached by an explicit socket or flag.
        compositor: if env::var_os("WAYFIRE_SOCKET").is_some() {
            Compositor::Wayfire
        } else if env::var_os("SWAYSOCK").is_some() {
            Compositor::Sway
        } else {
            Compositor::Fixture
        },
        mode: CoreMode::Normal,
        shell: None,
        hostd: None,
        agent: None,
        agent_backend: None,
        agent_backend_test_provider: None,
        rescue_ui: None,
        lock: None,
        launches: Vec::new(),
        builtin_packages: env::var_os("DITTO_BUILTIN_PACKAGES").map(PathBuf::from),
        development: false,
    };
    while let Some(argument) = arguments.next() {
        let mut value = || arguments.next().ok_or_else(usage);
        match argument.as_str() {
            "--compositor" => {
                options.compositor = match value()?.as_str() {
                    "wayfire" => Compositor::Wayfire,
                    "sway" => Compositor::Sway,
                    "fixture" => Compositor::Fixture,
                    _ => return Err(usage()),
                }
            }
            "--mode" => {
                options.mode = match value()?.as_str() {
                    "normal" => CoreMode::Normal,
                    "rescue" => CoreMode::Rescue,
                    _ => return Err(usage()),
                }
            }
            "--shell" => options.shell = Some(value()?),
            "--hostd" => options.hostd = Some(value()?),
            "--agent" => options.agent = Some(value()?),
            "--agent-backend" => options.agent_backend = Some(value()?),
            "--agent-backend-test-provider" => options.agent_backend_test_provider = Some(value()?),
            "--rescue-ui" => options.rescue_ui = Some(value()?),
            "--lock" => options.lock = Some(value()?),
            "--launch" => options.launches.push(value()?),
            "--builtin-packages" => options.builtin_packages = Some(PathBuf::from(value()?)),
            "--development" => options.development = true,
            _ => return Err(usage()),
        }
    }
    // G0 session scripts pass the Shell as a plain `--launch`; it is the
    // supervised Shell all the same.
    if options.shell.is_none() {
        if let Some(index) = options
            .launches
            .iter()
            .position(|spec| spec.starts_with("quickshell "))
        {
            options.shell = Some(options.launches.remove(index));
        }
    }
    if options.development && (options.shell.is_some() || !options.launches.is_empty()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "--development shares one token with every caller and cannot be combined with launched clients",
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

/// Follow the compositor for as long as the process lives. A compositor
/// restart takes capabilities offline, then re-reads state; nothing is replayed.
fn follow_compositor(
    session: Arc<Session>,
    compositor: Compositor,
    mut source: Box<dyn EventSource>,
    core: Arc<Core>,
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
                        ditto_core::log::event("compositor.reconnected", &[]);
                        // Layout and bindings set over IPC died with the old
                        // compositor; apply the committed Profile again.
                        core.compositor.forget();
                        core.submit(|coordinator| {
                            coordinator.sync_participant(
                                ditto_protocol::participant::ParticipantRole::Compositor,
                            )
                        });
                        break;
                    }
                }
                Err(error) => ditto_core::log::event(
                    "compositor.unreachable",
                    &[("reason", &error.to_string())],
                ),
            }
        }
    }
}

/// `DITTO_RUNTIME_DIR` lets a verification fixture run its own Core next to a
/// logged-in Ditto session that already owns `$XDG_RUNTIME_DIR/ditto`.
fn socket_path() -> io::Result<PathBuf> {
    let directory = match env::var_os("DITTO_RUNTIME_DIR") {
        Some(directory) => PathBuf::from(directory),
        None => PathBuf::from(env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is required")
        })?)
        .join("ditto"),
    };
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

fn spec(text: &Option<String>) -> io::Result<Option<launcher::Specification>> {
    text.as_deref().map(launcher::parse).transpose()
}

fn main() -> io::Result<()> {
    let options = parse_options()?;
    ditto_core::fault::load_from_environment();
    let session_id = ditto_protocol::ids::new("session");
    ditto_core::log::set_session(&session_id);
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
    let registry = Arc::new(IdentityRegistry::new());
    let paths = ditto_store::Paths::from_environment()
        .map_err(|error| io::Error::other(error.to_string()))?;
    let mut config = CoreConfig::new(paths, path.clone());
    config.mode = options.mode;
    config.shell = spec(&options.shell)?;
    config.hostd = spec(&options.hostd)?;
    config.agent = spec(&options.agent)?;
    if config
        .agent
        .as_ref()
        .is_some_and(|agent| agent.kind != "agent")
    {
        return Err(usage());
    }
    config.agent_backend = options
        .agent_backend
        .as_deref()
        .map(ditto_core::agent_backend::parse)
        .transpose()?;
    if let Some(url) = &options.agent_backend_test_provider {
        // A loopback stand-in for the subscription exists for automated
        // tests only: the fixture compositor, or a headless desktop fixture
        // that says so explicitly. The login session sets neither.
        let test_run = matches!(options.compositor, Compositor::Fixture)
            || env::var_os("DITTO_TEST_FIXTURE").is_some_and(|v| v == "1");
        let (Some(backend), true) = (&mut config.agent_backend, test_run) else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "--agent-backend-test-provider needs --agent-backend and a test fixture",
            ));
        };
        backend.test_provider = Some(ditto_core::agent_backend::parse_test_provider(url)?);
        ditto_core::log::event("agent.test_provider", &[("url", url.as_str())]);
    }
    config.rescue_ui = spec(&options.rescue_ui)?;
    config.lock = spec(&options.lock)?;
    config.builtin_packages = options.builtin_packages.clone();
    // The system integration lives in ditto-system. `DITTO_SYSTEM=none` (test
    // fixtures) gets a stand-in that reports every action unavailable rather
    // than pretending; the real one reports its own missing parts.
    // `DITTO_SYSTEM=no-logind` (headless fixtures with their own session bus)
    // is the real one without logind: the notification server runs on the
    // fixture's bus, and nothing reaches the login session the fixture runs
    // beside (no Lock or PrepareForSleep from it, no LockSession on it).
    let system_mode = env::var("DITTO_SYSTEM").unwrap_or_default();
    let real = (system_mode != "none").then(|| {
        let mut config = ditto_system::RealSystemConfig::from_env(
            ditto_system::RealSystemConfig::default_cache_path(),
        );
        if system_mode == "no-logind" {
            config.logind = false;
        }
        Arc::new(ditto_system::RealSystem::with_config(config))
    });
    if let Some(real) = &real {
        for (component, problem) in real.problems() {
            ditto_core::log::event(
                "system.component_unavailable",
                &[("component", component), ("reason", problem)],
            );
        }
    }
    let system: Arc<dyn ditto_system::SystemServices> = match &real {
        Some(real) => Arc::clone(real) as Arc<dyn ditto_system::SystemServices>,
        None => Arc::new(ditto_system::UnavailableSystem),
    };
    let core = match Core::start(
        config,
        Arc::clone(&session),
        Arc::clone(&system),
        Arc::clone(&registry),
    ) {
        Ok(core) => core,
        Err(error) => {
            // The store failed its check or its migration: nothing is
            // repaired automatically. systemd's OnFailure starts rescue,
            // which reads the database offline under the same lock.
            ditto_core::log::event("core.store_refused", &[("reason", &error.to_string())]);
            std::process::exit(3);
        }
    };
    let hooks = Arc::new(ditto_core::router::Hooks(Arc::downgrade(&core)));
    system.set_notification_hooks(hooks.clone());
    system.set_session_hooks(hooks);
    if let Some(real) = &real {
        // Application names in the index follow the Profile's language.
        let locale = core
            .read(|connection| {
                let active = ditto_store::profiles::active_profile(connection)?
                    .ok_or_else(|| ditto_store::StoreError::NotFound("no active profile".into()))?;
                Ok(ditto_store::profiles::head_document(connection, &active)?
                    .2
                    .appearance
                    .locale)
            })
            .unwrap_or_else(|_| "zh-TW".into());
        real.set_locale(&locale);
    }
    ditto_core::log::event(
        "core.listening",
        &[
            ("socket", &path.display().to_string()),
            ("compositor", &session.compositor_label()),
            (
                "mode",
                if options.mode == CoreMode::Rescue {
                    "rescue"
                } else {
                    "normal"
                },
            ),
        ],
    );
    {
        // A pressed global shortcut runs its command through Core, like any
        // `desktop.commands.invoke`.
        let weak = Arc::downgrade(&core);
        session.set_shortcut_handler(Arc::new(move |command_id: &str| {
            if let Some(core) = weak.upgrade() {
                if let Err(error) =
                    ditto_core::router::run_command(&core, command_id, serde_json::Value::Null)
                {
                    ditto_core::log::event(
                        "shortcut.command_failed",
                        &[("command", command_id), ("reason", &error.message)],
                    );
                }
            }
        }));
    }
    {
        let session = Arc::clone(&session);
        let core = Arc::clone(&core);
        thread::spawn(move || follow_compositor(session, options.compositor, events, core));
    }
    for specification in &options.launches {
        match launcher::launch(&registry, specification, &path) {
            // A launched client is not supervised, but its exit is reaped
            // (no zombie left until Core ends) and logged.
            Ok(mut child) => {
                let spec = specification.clone();
                thread::spawn(move || {
                    let status = child
                        .wait()
                        .map(|status| status.to_string())
                        .unwrap_or_else(|error| error.to_string());
                    ditto_core::log::event(
                        "launch.exited",
                        &[("spec", &spec), ("status", &status)],
                    );
                });
            }
            Err(error) => {
                ditto_core::log::event(
                    "launch.failed",
                    &[("spec", specification), ("reason", &error.to_string())],
                );
            }
        }
    }
    if development_token.is_some() {
        ditto_core::log::event(
            "core.development_mode",
            &[(
                "note",
                "one shared token, no launcher binding; not EX-07 evidence",
            )],
        );
    }
    for connection in listener.incoming() {
        let stream = connection?;
        let core = Arc::clone(&core);
        let registry = Arc::clone(&registry);
        let token = development_token.clone();
        thread::spawn(move || {
            let served = match token {
                Some(token) => ditto_core::serve_connection(stream, core, &token),
                None => ditto_core::serve_bound_connection(stream, core, &registry),
            };
            if let Err(error) = served {
                ditto_core::log::event("connection.ended", &[("reason", &error.to_string())]);
            }
        });
    }
    Ok(())
}
