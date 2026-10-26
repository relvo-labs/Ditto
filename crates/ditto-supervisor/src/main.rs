//! `ditto-supervisor`: watches the Shell's responsiveness and starts the
//! rescue UI when it stops answering (G1-PLAT-03, plan/03/05 §1 and §3).
//! It has no IPC server, holds no authoritative state, and does not depend
//! on the Shell, Node or Core being alive. The line protocol it expects from
//! the Shell is in this crate's README.

mod monitor;
mod shell;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use monitor::{Clock, Effects, Outcome, Phase, State, Timing};
use shell::{Locator, SocketPinger};

const USAGE: &str =
    "usage: ditto-supervisor [--socket PATH] [--interval-ms N] [--timeout-ms N] [--misses N] \
[--startup-grace-ms N] [--startup-misses N] \
[--shell-scope NAME]... [--pid-file PATH] [--rescue-unit NAME] [--no-rescue]\n       \
ditto-supervisor --on-core-failure\n       ditto-supervisor --once";

struct Options {
    socket: PathBuf,
    runtime_dir: PathBuf,
    timing: Timing,
    locator: Locator,
    rescue_unit: Option<String>,
    mode: Mode,
}

#[derive(PartialEq)]
enum Mode {
    Watch,
    Once,
    OnCoreFailure,
}

fn runtime_dir() -> PathBuf {
    std::env::var_os("DITTO_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("XDG_RUNTIME_DIR")
                .map(PathBuf::from)
                // SAFETY: getuid has no preconditions.
                .unwrap_or_else(|| {
                    PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }))
                })
                .join("ditto")
        })
}

fn parse(arguments: impl Iterator<Item = String>) -> Result<Options, String> {
    let runtime_dir = runtime_dir();
    let mut options = Options {
        socket: runtime_dir.join("shell.sock"),
        timing: Timing::default(),
        locator: Locator::for_user(runtime_dir.join("shell.pid")),
        rescue_unit: Some("ditto-rescue.service".into()),
        mode: Mode::Watch,
        runtime_dir,
    };
    let mut scopes = Vec::new();
    let mut startup_misses = None;
    let mut arguments = arguments.peekable();
    let number = |value: Option<String>, name: &str| -> Result<u64, String> {
        value
            .and_then(|v| v.parse().ok())
            .ok_or_else(|| format!("{name} needs a number\n{USAGE}"))
    };
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--socket" => options.socket = arguments.next().ok_or(USAGE)?.into(),
            "--interval-ms" => {
                options.timing.interval =
                    Duration::from_millis(number(arguments.next(), "--interval-ms")?)
            }
            "--timeout-ms" => {
                options.timing.timeout =
                    Duration::from_millis(number(arguments.next(), "--timeout-ms")?)
            }
            "--misses" => options.timing.misses = number(arguments.next(), "--misses")? as u32,
            "--startup-grace-ms" => {
                options.timing.startup_grace =
                    Duration::from_millis(number(arguments.next(), "--startup-grace-ms")?)
            }
            "--startup-misses" => {
                let value = number(arguments.next(), "--startup-misses")?;
                startup_misses = Some(
                    u32::try_from(value)
                        .map_err(|_| format!("--startup-misses is too large\n{USAGE}"))?,
                );
            }
            "--shell-scope" => scopes.push(arguments.next().ok_or(USAGE)?),
            "--pid-file" => options.locator.pid_file = arguments.next().ok_or(USAGE)?.into(),
            "--rescue-unit" => options.rescue_unit = Some(arguments.next().ok_or(USAGE)?),
            "--no-rescue" => options.rescue_unit = None,
            "--on-core-failure" => options.mode = Mode::OnCoreFailure,
            "--once" => options.mode = Mode::Once,
            "--help" | "-h" => return Err(USAGE.into()),
            other => return Err(format!("unknown argument {other}\n{USAGE}")),
        }
    }
    if !scopes.is_empty() {
        options.locator.scopes = scopes;
    }
    if options.timing.timeout >= options.timing.interval {
        return Err("--timeout-ms must be shorter than --interval-ms".into());
    }
    // The startup grace may only be more patient than the steady rule. Left
    // unset it follows a larger --misses, so existing invocations keep working.
    let steady = options.timing.misses.max(1);
    match startup_misses {
        Some(misses) if misses < steady => {
            return Err("--startup-misses must be at least --misses".into());
        }
        Some(misses) => options.timing.startup_misses = misses,
        None => options.timing.startup_misses = options.timing.startup_misses.max(steady),
    }
    Ok(options)
}

/// `key=value` lines on stderr, which the journal keeps with the unit.
fn log(event: &str, fields: &[(&str, &str)]) {
    let mut line = format!("ditto-supervisor event={event}");
    for (key, value) in fields {
        line.push_str(&format!(" {key}={value:?}"));
    }
    eprintln!("{line}");
}

struct RealClock(Instant);

impl Clock for RealClock {
    fn now_ms(&self) -> u64 {
        self.0.elapsed().as_millis() as u64
    }
    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

struct RealEffects<'a> {
    options: &'a Options,
}

impl Effects for RealEffects<'_> {
    fn trip(&mut self, misses: u32, last: &Outcome, phase: Phase) {
        let reason = match last {
            Outcome::NoReply(reason) => reason.as_str(),
            _ => "",
        };
        let killed = shell::kill_shell(&self.options.locator);
        let pids = killed
            .pids
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join(",");
        log(
            "shell_unresponsive",
            &[
                ("misses", &misses.to_string()),
                ("phase", phase.as_str()),
                ("last", reason),
                ("source", killed.source),
                ("killed", &pids),
            ],
        );
        shell::write_rescue_request(&self.options.runtime_dir, "shell_unresponsive", &killed);
        if let Some(unit) = &self.options.rescue_unit {
            // A running Core starts the rescue UI itself, through its launcher,
            // so the rescue UI can reach Core (window list, restore, back to
            // the desktop). The unit, which has no launcher token, is only for
            // a Core that is not running.
            if shell::unit_active("ditto-core.service") {
                log("rescue_left_to_core", &[]);
                return;
            }
            match shell::start_unit(unit) {
                Ok(()) => log("rescue_started", &[("unit", unit)]),
                Err(error) => log("rescue_failed", &[("unit", unit), ("error", &error)]),
            }
        }
    }

    fn transition(&mut self, from: State, to: State, outcome: &Outcome, phase: Phase) {
        let detail = match outcome {
            Outcome::NoReply(reason) => reason.clone(),
            _ => String::new(),
        };
        let from = format!("{from:?}");
        let to_text = format!("{to:?}");
        let mut fields = vec![
            ("from", from.as_str()),
            ("to", to_text.as_str()),
            ("detail", detail.as_str()),
        ];
        // Armed: which rule the Shell is now judged by. Tripped: which rule
        // tripped it. Tells a startup stall from a steady hang in the journal.
        if matches!(to, State::Armed { .. } | State::Tripped) {
            fields.push(("phase", phase.as_str()));
        }
        log("state", &fields);
    }

    fn grace_ended(&mut self, misses: u32) {
        log("grace_ended", &[("misses", &misses.to_string())]);
    }
}

/// `ExecStartPre=` of `ditto-rescue.service`. It records why rescue started
/// unless the watcher already did, and makes sure the main Shell is gone: a
/// Shell whose Core has died cannot change anything, and two Shells would
/// fight over the panels. It never fails, so it cannot block the rescue UI.
fn on_core_failure(options: &Options) {
    if shell::recent_rescue_request(&options.runtime_dir, Duration::from_secs(30)).is_some() {
        log("rescue_request_kept", &[]);
    } else {
        let killed = shell::kill_shell(&options.locator);
        let pids = killed
            .pids
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join(",");
        log(
            "core_failure",
            &[("source", killed.source), ("killed", &pids)],
        );
        shell::write_rescue_request(&options.runtime_dir, "core_failure", &killed);
    }
}

fn main() {
    let options = match parse(std::env::args().skip(1)) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };
    let mut pinger = SocketPinger::new(options.socket.clone());
    match options.mode {
        Mode::OnCoreFailure => on_core_failure(&options),
        Mode::Once => {
            use monitor::Pinger;
            let outcome = pinger.ping(1, options.timing.timeout);
            println!("{outcome:?}");
            std::process::exit(if outcome == Outcome::Pong { 0 } else { 1 });
        }
        Mode::Watch => {
            log(
                "started",
                &[
                    ("socket", &options.socket.display().to_string()),
                    (
                        "interval_ms",
                        &options.timing.interval.as_millis().to_string(),
                    ),
                    ("misses", &options.timing.misses.to_string()),
                    (
                        "startup_grace_ms",
                        &options.timing.startup_grace.as_millis().to_string(),
                    ),
                    ("startup_misses", &options.timing.startup_misses.to_string()),
                ],
            );
            let clock = RealClock(Instant::now());
            let mut effects = RealEffects { options: &options };
            monitor::run(&clock, &mut pinger, &mut effects, &options.timing, None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> impl Iterator<Item = String> {
        list.iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
            .into_iter()
    }

    #[test]
    fn defaults_follow_the_plan() {
        let options = parse(args(&[])).unwrap();
        assert_eq!(options.timing.interval, Duration::from_secs(2));
        assert_eq!(options.timing.timeout, Duration::from_secs(1));
        assert_eq!(options.timing.misses, 3);
        assert!(options.socket.ends_with("shell.sock"));
        assert_eq!(
            options.locator.scopes,
            ["ditto-shell.scope", "ditto-quickshell.scope"]
        );
        assert_eq!(options.rescue_unit.as_deref(), Some("ditto-rescue.service"));
    }

    #[test]
    fn flags_override_and_bad_values_are_refused() {
        let options = parse(args(&[
            "--interval-ms",
            "500",
            "--timeout-ms",
            "200",
            "--shell-scope",
            "x.scope",
            "--no-rescue",
            "--once",
        ]))
        .unwrap();
        assert_eq!(options.timing.interval, Duration::from_millis(500));
        assert_eq!(options.locator.scopes, ["x.scope"]);
        assert!(options.rescue_unit.is_none());
        assert!(options.mode == Mode::Once);
        assert!(parse(args(&["--interval-ms", "1000", "--timeout-ms", "1000"])).is_err());
        assert!(parse(args(&["--misses"])).is_err());
        assert!(parse(args(&["--bogus"])).is_err());
    }

    #[test]
    fn startup_grace_defaults_and_flags() {
        let options = parse(args(&[])).unwrap();
        assert_eq!(options.timing.startup_grace, Duration::from_secs(60));
        assert_eq!(options.timing.startup_misses, 10);

        let options = parse(args(&[
            "--startup-grace-ms",
            "30000",
            "--startup-misses",
            "6",
        ]))
        .unwrap();
        assert_eq!(options.timing.startup_grace, Duration::from_secs(30));
        assert_eq!(options.timing.startup_misses, 6);
        assert_eq!(options.timing.misses, 3, "the steady rule is untouched");

        // Zero turns the grace off; equal to --misses is allowed.
        let options = parse(args(&["--startup-grace-ms", "0", "--startup-misses", "3"])).unwrap();
        assert_eq!(options.timing.startup_grace, Duration::ZERO);
        assert_eq!(options.timing.startup_misses, 3);

        // An existing invocation with a larger --misses keeps working, and
        // the grace is never stricter than it.
        let options = parse(args(&["--misses", "100000"])).unwrap();
        assert_eq!(options.timing.misses, 100_000);
        assert_eq!(options.timing.startup_misses, 100_000);
    }

    #[test]
    fn bad_startup_values_are_refused() {
        assert!(parse(args(&["--startup-misses", "2"])).is_err());
        assert!(parse(args(&["--startup-misses", "0"])).is_err());
        assert!(parse(args(&["--misses", "5", "--startup-misses", "4"])).is_err());
        assert!(parse(args(&["--startup-misses", "4294967296"])).is_err());
        assert!(parse(args(&["--startup-misses", "-1"])).is_err());
        assert!(parse(args(&["--startup-misses"])).is_err());
        assert!(parse(args(&["--startup-grace-ms", "soon"])).is_err());
        assert!(parse(args(&["--startup-grace-ms"])).is_err());
    }
}
