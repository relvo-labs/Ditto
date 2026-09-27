//! The real system services. Construction scans the desktop entries
//! (reusing the cache), then starts, each on its own thread and only when
//! configured: the inotify watcher, the notification server and the logind
//! listeners. None of them wakes up periodically; each blocks until the
//! kernel or the bus has something for it.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, SystemTime};

use ditto_protocol::services::{
    AppEntry, LauncherAppsOutput, LauncherLaunchInput, LauncherLaunchOutput, NotificationItem,
    SessionState,
};

use crate::desktop_entry::{self, Locale};
use crate::index::{AppIndex, Environment};
use crate::launch::{self, LaunchOptions, PlanInput};
use crate::notify::{Incoming, Policy, Store};
use crate::watch::Watcher;
use crate::{NotificationHooks, SessionHooks, SystemError, SystemResult, SystemServices};

#[derive(Clone, Debug)]
pub struct RealSystemConfig {
    /// `$XDG_CACHE_HOME/ditto/app-index.db`.
    pub cache_path: PathBuf,
    /// `applications/` directories, highest precedence first.
    pub application_dirs: Vec<PathBuf>,
    pub environment: Environment,
    pub locale: Locale,
    pub systemd_run: PathBuf,
    pub xdg_mime: PathBuf,
    /// Prefix for `Terminal=true` entries.
    pub terminal: Vec<String>,
    pub watch: bool,
    pub notifications: bool,
    pub logind: bool,
}

impl RealSystemConfig {
    /// XDG base directories from the environment, with the spec defaults.
    pub fn from_env(cache_path: PathBuf) -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| "/".into());
        let data_home = std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home.join(".local/share"));
        let data_dirs = std::env::var("XDG_DATA_DIRS")
            .ok()
            .filter(|dirs| !dirs.is_empty())
            .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
        let mut application_dirs = vec![data_home.join("applications")];
        for dir in data_dirs
            .split(':')
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
        {
            let dir = dir.join("applications");
            if !application_dirs.contains(&dir) {
                application_dirs.push(dir);
            }
        }
        let terminal = std::env::var("DITTO_TERMINAL")
            .ok()
            .map(|t| t.split_whitespace().map(String::from).collect())
            .unwrap_or_else(|| vec!["foot".into()]);
        Self {
            cache_path,
            application_dirs,
            environment: Environment::from_env(),
            locale: Locale::from_env(),
            systemd_run: "/usr/bin/systemd-run".into(),
            xdg_mime: "/usr/bin/xdg-mime".into(),
            terminal,
            watch: true,
            notifications: true,
            logind: true,
        }
    }

    /// `$XDG_CACHE_HOME/ditto/app-index.db`.
    pub fn default_cache_path() -> PathBuf {
        let cache = std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| {
                std::env::var_os("HOME")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| "/".into())
                    .join(".cache")
            });
        cache.join("ditto/app-index.db")
    }
}

pub(crate) struct Shared {
    pub(crate) config: RealSystemConfig,
    pub(crate) index: RwLock<AppIndex>,
    locale: RwLock<Locale>,
    store: Mutex<Store>,
    policy: Policy,
    session: Mutex<SessionState>,
    session_hooks: RwLock<Option<Arc<dyn SessionHooks>>>,
    #[cfg(feature = "dbus")]
    notification_bus: Mutex<Option<zbus::blocking::Connection>>,
}

// Without the bus nothing delivers notifications or session signals.
#[cfg_attr(not(feature = "dbus"), allow(dead_code))]
impl Shared {
    /// Rescan and persist. A cache that cannot be written is logged and
    /// otherwise ignored: the in-memory index is what answers queries.
    pub(crate) fn rescan(&self) {
        let previous = self.index.read().expect("app index").files.clone();
        let index = AppIndex::scan(
            &self.config.application_dirs,
            &previous,
            &self.config.environment,
        );
        if let Err(error) = index.persist(&self.config.cache_path) {
            eprintln!(
                "ditto-system: app index cache {}: {error}",
                self.config.cache_path.display()
            );
        }
        *self.index.write().expect("app index") = index;
    }

    pub(crate) fn ingest(&self, incoming: Incoming) -> NotificationItem {
        let decision = self.policy.ask(&incoming.app_name, incoming.urgency);
        let item =
            self.store
                .lock()
                .expect("notifications")
                .apply(incoming, decision, SystemTime::now());
        if let Some(hooks) = self.policy.hooks() {
            hooks.posted(&item);
        }
        item
    }

    pub(crate) fn forget(&self, id: u32, reason: &str) -> bool {
        let removed = self.store.lock().expect("notifications").remove(id);
        if removed {
            if let Some(hooks) = self.policy.hooks() {
                hooks.closed(id, reason);
            }
        }
        removed
    }

    pub(crate) fn session_signal(&self, call: impl Fn(&dyn SessionHooks)) {
        let hooks = self.session_hooks.read().expect("session hooks").clone();
        if let Some(hooks) = hooks {
            call(hooks.as_ref());
        }
    }

    pub(crate) fn preparing_for_sleep(&self, before: bool) {
        self.session.lock().expect("session").preparing_for_sleep = before;
        self.session_signal(|hooks| hooks.preparing_for_sleep(before));
    }
}

pub struct RealSystem {
    shared: Arc<Shared>,
    _watcher: Option<Watcher>,
    #[cfg(feature = "dbus")]
    logind: Option<crate::dbus::Logind>,
    /// Why a component is unavailable, for diagnostics.
    problems: Vec<(String, String)>,
}

impl RealSystem {
    /// Everything from the environment; the index cache at `cache_path`.
    pub fn new(cache_path: PathBuf) -> Self {
        Self::with_config(RealSystemConfig::from_env(cache_path))
    }

    pub fn with_config(config: RealSystemConfig) -> Self {
        let cached = AppIndex::load_cache(&config.cache_path);
        let index = AppIndex {
            files: cached,
            ..AppIndex::default()
        };
        let shared = Arc::new(Shared {
            locale: RwLock::new(config.locale.clone()),
            index: RwLock::new(index),
            store: Mutex::new(Store::default()),
            policy: Policy::new(),
            session: Mutex::new(SessionState {
                locked: false,
                lock_client_running: false,
                preparing_for_sleep: false,
                logind_available: false,
            }),
            session_hooks: RwLock::new(None),
            #[cfg(feature = "dbus")]
            notification_bus: Mutex::new(None),
            config,
        });
        shared.rescan();
        let mut problems = Vec::new();
        let watcher = if shared.config.watch {
            match Watcher::start(shared.clone()) {
                Ok(watcher) => Some(watcher),
                Err(error) => {
                    problems.push((
                        "launcher".into(),
                        format!("inotify: {error}; the index is not refreshed"),
                    ));
                    None
                }
            }
        } else {
            None
        };
        #[cfg(feature = "dbus")]
        let logind = {
            if shared.config.notifications {
                match crate::dbus::start_notifications(shared.clone()) {
                    Ok(connection) => {
                        *shared.notification_bus.lock().expect("bus") = Some(connection)
                    }
                    Err(error) => problems.push(("notifications".into(), error)),
                }
            }
            if shared.config.logind {
                match crate::dbus::Logind::connect()
                    .and_then(|logind| logind.listen(shared.clone()).map(|()| logind))
                {
                    Ok(logind) => {
                        shared.session.lock().expect("session").logind_available = true;
                        Some(logind)
                    }
                    Err(error) => {
                        problems.push(("logind".into(), error));
                        None
                    }
                }
            } else {
                None
            }
        };
        #[cfg(not(feature = "dbus"))]
        {
            let wanted = [
                ("notifications", shared.config.notifications),
                ("logind", shared.config.logind),
            ];
            for (component, _) in wanted.into_iter().filter(|(_, wanted)| *wanted) {
                problems.push((component.into(), "built without the dbus feature".into()));
            }
        }
        for (component, problem) in &problems {
            eprintln!("ditto-system: {component} unavailable: {problem}");
        }
        Self {
            shared,
            _watcher: watcher,
            #[cfg(feature = "dbus")]
            logind,
            problems,
        }
    }

    /// The Profile's `appearance.locale` (e.g. `zh_TW`), for names and keywords.
    pub fn set_locale(&self, locale: &str) {
        *self.shared.locale.write().expect("locale") = Locale::parse(locale);
    }

    /// Why each unavailable component is unavailable.
    pub fn problems(&self) -> &[(String, String)] {
        &self.problems
    }

    /// The logind session object in use, for diagnostics.
    pub fn logind_session(&self) -> Option<String> {
        #[cfg(feature = "dbus")]
        return self
            .logind
            .as_ref()
            .map(|logind| logind.session_path().to_string());
        #[cfg(not(feature = "dbus"))]
        None
    }

    /// Force a rescan (the watcher does this on its own).
    pub fn refresh_index(&self) {
        self.shared.rescan();
    }

    /// `launch` with the extras the contract does not carry yet.
    pub fn launch_with(
        &self,
        input: &LauncherLaunchInput,
        operation_id: &str,
        options: &LaunchOptions,
    ) -> SystemResult<LauncherLaunchOutput> {
        let app_id = match (&input.app_id, &input.open_uri) {
            (Some(app_id), _) => app_id.clone(),
            (None, Some(uri)) => self.default_handler(uri)?,
            (None, None) => {
                return Err(SystemError::Invalid(
                    "app_id or open_uri is required".into(),
                ))
            }
        };
        if !self.shared.config.systemd_run.is_file() {
            return Err(SystemError::Unavailable(format!(
                "{} is missing",
                self.shared.config.systemd_run.display()
            )));
        }
        let suffix = launch::random_suffix();
        let plan = {
            let index = self.shared.index.read().expect("app index");
            let app = index
                .apps
                .get(&app_id)
                .ok_or_else(|| SystemError::NotFound(format!("no application {app_id}")))?;
            launch::plan(&PlanInput {
                app,
                target: input.open_uri.as_deref(),
                locale: &self.shared.locale.read().expect("locale"),
                systemd_run: &self.shared.config.systemd_run,
                terminal: &self.shared.config.terminal,
                suffix: &suffix,
                options,
            })?
        };
        launch::spawn_detached(&plan)
            .map_err(|error| SystemError::Failed(format!("starting {app_id}: {error}")))?;
        Ok(LauncherLaunchOutput {
            accepted: true,
            operation_id: operation_id.into(),
            unit: format!("{}.scope", plan.unit),
            app_id,
        })
    }

    /// `xdg-mime query default` for the target's type: the file type for a
    /// path or `file:` URI, `x-scheme-handler/<scheme>` for any other URI.
    fn default_handler(&self, target: &str) -> SystemResult<String> {
        let mime = match desktop_entry::uri_scheme(target) {
            Some(scheme) if !scheme.eq_ignore_ascii_case("file") => {
                format!("x-scheme-handler/{}", scheme.to_ascii_lowercase())
            }
            scheme => {
                let path = match scheme {
                    Some(_) => desktop_entry::file_uri_to_path(target).ok_or_else(|| {
                        SystemError::Invalid(format!("{target} is not a local file"))
                    })?,
                    None => PathBuf::from(target),
                };
                if !path.is_absolute() {
                    return Err(SystemError::Invalid(format!(
                        "{target} is not an absolute path or URI"
                    )));
                }
                if !path.exists() {
                    return Err(SystemError::NotFound(format!(
                        "{} does not exist",
                        path.display()
                    )));
                }
                self.xdg_mime(&["query", "filetype"], &path)?
            }
        };
        let desktop = self.xdg_mime(&["query", "default"], Path::new(&mime))?;
        let app_id = desktop.trim_end_matches(".desktop").to_string();
        if app_id.is_empty() {
            return Err(SystemError::NotFound(format!(
                "no default application for {mime}"
            )));
        }
        Ok(app_id)
    }

    fn xdg_mime(&self, args: &[&str], operand: &Path) -> SystemResult<String> {
        let output = Command::new(&self.shared.config.xdg_mime)
            .args(args)
            .arg(operand)
            .output()
            .map_err(|error| SystemError::Unavailable(format!("xdg-mime: {error}")))?;
        let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !output.status.success() || text.is_empty() {
            return Err(SystemError::NotFound(format!(
                "xdg-mime {} {} gave no answer",
                args.join(" "),
                operand.display()
            )));
        }
        Ok(text.lines().next().unwrap_or_default().trim().to_string())
    }

    fn indexed_at(&self) -> Option<String> {
        self.shared
            .index
            .read()
            .expect("app index")
            .indexed_at
            .map(crate::time::rfc3339)
    }

    #[cfg(feature = "dbus")]
    fn logind(&self) -> SystemResult<&crate::dbus::Logind> {
        self.logind
            .as_ref()
            .ok_or_else(|| SystemError::Unavailable("logind is not reachable".into()))
    }
}

#[cfg(feature = "dbus")]
fn bus_error(action: &str) -> impl Fn(zbus::Error) -> SystemError + '_ {
    move |error| SystemError::Failed(format!("logind {action}: {error}"))
}

impl SystemServices for RealSystem {
    fn search_apps(&self, query: &str, limit: usize) -> SystemResult<LauncherAppsOutput> {
        let locale = self.shared.locale.read().expect("locale").clone();
        let apps = self
            .shared
            .index
            .read()
            .expect("app index")
            .search(query, limit, &locale);
        Ok(LauncherAppsOutput {
            apps,
            indexed_at: self.indexed_at(),
        })
    }

    fn list_apps(&self, category: Option<&str>) -> SystemResult<LauncherAppsOutput> {
        let locale = self.shared.locale.read().expect("locale").clone();
        let apps = self
            .shared
            .index
            .read()
            .expect("app index")
            .list(category, &locale);
        Ok(LauncherAppsOutput {
            apps,
            indexed_at: self.indexed_at(),
        })
    }

    fn app(&self, app_id: &str) -> SystemResult<AppEntry> {
        let locale = self.shared.locale.read().expect("locale").clone();
        let index = self.shared.index.read().expect("app index");
        index
            .apps
            .get(app_id)
            .map(|app| AppIndex::to_app_entry(app, &locale))
            .ok_or_else(|| SystemError::NotFound(format!("no application {app_id}")))
    }

    fn launch(
        &self,
        input: &LauncherLaunchInput,
        operation_id: &str,
    ) -> SystemResult<LauncherLaunchOutput> {
        self.launch_with(input, operation_id, &LaunchOptions::default())
    }

    fn notifications(&self, limit: usize) -> SystemResult<Vec<NotificationItem>> {
        Ok(self.shared.store.lock().expect("notifications").list(limit))
    }

    fn dismiss(&self, id: u32) -> SystemResult<bool> {
        let removed = self.shared.forget(id, "dismissed");
        #[cfg(feature = "dbus")]
        if removed {
            if let Some(connection) = self.shared.notification_bus.lock().expect("bus").as_ref() {
                crate::dbus::emit_closed(connection, id, crate::dbus::CLOSED_DISMISSED);
            }
        }
        Ok(removed)
    }

    fn notification_server_owned(&self) -> bool {
        #[cfg(feature = "dbus")]
        return self.shared.notification_bus.lock().expect("bus").is_some();
        #[cfg(not(feature = "dbus"))]
        false
    }

    fn set_notification_hooks(&self, hooks: Arc<dyn NotificationHooks>) {
        self.shared.policy.set_hooks(hooks);
    }

    fn session_state(&self) -> SystemResult<SessionState> {
        Ok(self.shared.session.lock().expect("session").clone())
    }

    fn lock_session(&self) -> SystemResult<()> {
        #[cfg(feature = "dbus")]
        return self.logind()?.lock().map_err(bus_error("Lock"));
        #[cfg(not(feature = "dbus"))]
        Err(SystemError::Unavailable(
            "built without the dbus feature".into(),
        ))
    }

    fn logout(&self) -> SystemResult<()> {
        #[cfg(feature = "dbus")]
        return self.logind()?.terminate().map_err(bus_error("Terminate"));
        #[cfg(not(feature = "dbus"))]
        Err(SystemError::Unavailable(
            "built without the dbus feature".into(),
        ))
    }

    fn suspend(&self) -> SystemResult<()> {
        #[cfg(feature = "dbus")]
        return self.logind()?.suspend().map_err(bus_error("Suspend"));
        #[cfg(not(feature = "dbus"))]
        Err(SystemError::Unavailable(
            "built without the dbus feature".into(),
        ))
    }

    fn poweroff(&self) -> SystemResult<()> {
        #[cfg(feature = "dbus")]
        return self.logind()?.power_off().map_err(bus_error("PowerOff"));
        #[cfg(not(feature = "dbus"))]
        Err(SystemError::Unavailable(
            "built without the dbus feature".into(),
        ))
    }

    fn set_session_hooks(&self, hooks: Arc<dyn SessionHooks>) {
        *self.shared.session_hooks.write().expect("session hooks") = Some(hooks);
    }

    fn set_lock_state(&self, locked: bool, client_running: bool) {
        let mut session = self.shared.session.lock().expect("session");
        session.locked = locked;
        session.lock_client_running = client_running;
    }

    fn component_available(&self, component: &str) -> bool {
        match component {
            "launcher" => self.shared.config.systemd_run.is_file(),
            "notifications" => self.notification_server_owned(),
            "logind" => {
                self.shared
                    .session
                    .lock()
                    .expect("session")
                    .logind_available
            }
            _ => false,
        }
    }
}

/// How long the watcher waits after the last event before rescanning: a
/// package upgrade touches many files in a burst.
pub(crate) const DEBOUNCE: Duration = Duration::from_millis(250);

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir()
                .join(format!("ditto-system-real-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(root.join("home/applications")).unwrap();
            fs::create_dir_all(root.join("usr/applications")).unwrap();
            fs::create_dir_all(root.join("bin")).unwrap();
            Self { root }
        }

        fn entry(&self, dir: &str, name: &str, body: &str) {
            fs::write(
                self.root.join(dir).join("applications").join(name),
                format!("[Desktop Entry]\nType=Application\n{body}"),
            )
            .unwrap();
        }

        fn script(&self, name: &str, body: &str) -> PathBuf {
            let path = self.root.join("bin").join(name);
            fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            path
        }

        fn config(&self, watch: bool) -> RealSystemConfig {
            RealSystemConfig {
                cache_path: self.root.join("cache/ditto/app-index.db"),
                application_dirs: vec![self.root.join("home/applications"), self.root.join("usr/applications")],
                environment: Environment::default(),
                locale: Locale::parse("zh_TW.UTF-8"),
                // A stand-in that records its arguments instead of creating a scope.
                systemd_run: self.script("systemd-run", &format!("printf '%s\\n' \"$@\" > {}/launched", self.root.display())),
                xdg_mime: self.script(
                    "xdg-mime",
                    "case \"$2 $3\" in\n  'filetype '*.txt) echo text/plain ;;\n  'default text/plain') echo org.kde.kate.desktop ;;\n  'default x-scheme-handler/https') echo firefox.desktop ;;\n  *) exit 1 ;;\nesac",
                ),
                terminal: vec!["foot".into()],
                watch,
                notifications: false,
                logind: false,
            }
        }

        fn launched(&self) -> Vec<String> {
            for _ in 0..100 {
                if let Ok(text) = fs::read_to_string(self.root.join("launched")) {
                    if text.ends_with('\n') {
                        return text.lines().map(String::from).collect();
                    }
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            panic!("the launch stand-in did not run");
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn index_search_and_launch_through_the_trait() {
        let f = Fixture::new("launch");
        f.entry("usr", "firefox.desktop", "Name=Firefox\nExec=firefox %u\n");
        f.entry(
            "usr",
            "org.kde.kate.desktop",
            "Name=Kate\nName[zh_TW]=Kate 編輯器\nExec=kate -b %U\n",
        );
        let system = RealSystem::with_config(f.config(false));
        assert!(system.component_available("launcher"));
        assert!(!system.component_available("notifications"));
        assert!(!system.notification_server_owned());
        assert_eq!(
            system.search_apps("編輯", 5).unwrap().apps[0].app_id,
            "org.kde.kate"
        );
        assert!(system.search_apps("fire", 5).unwrap().indexed_at.is_some());
        assert!(f.root.join("cache/ditto/app-index.db").is_file());
        assert_eq!(system.app("org.kde.kate").unwrap().name, "Kate 編輯器");
        system.set_locale("en_US");
        assert_eq!(system.app("org.kde.kate").unwrap().name, "Kate");

        let input = LauncherLaunchInput {
            app_id: None,
            open_uri: Some("https://example.org".into()),
        };
        let output = system.launch(&input, "op-1").unwrap();
        assert_eq!(output.app_id, "firefox");
        assert!(output.unit.starts_with("app-ditto-firefox-") && output.unit.ends_with(".scope"));
        let args = f.launched();
        assert_eq!(&args[..4], ["--user", "--scope", "--quiet", "--collect"]);
        assert_eq!(&args[args.len() - 2..], ["firefox", "https://example.org"]);

        fs::remove_file(f.root.join("launched")).unwrap();
        let file = f.root.join("note.txt");
        fs::write(&file, "x").unwrap();
        let input = LauncherLaunchInput {
            app_id: None,
            open_uri: Some(file.display().to_string()),
        };
        assert_eq!(
            system.launch(&input, "op-2").unwrap().app_id,
            "org.kde.kate"
        );
        let args = f.launched();
        assert_eq!(args.last().unwrap(), &format!("file://{}", file.display()));

        let missing = LauncherLaunchInput {
            app_id: Some("nope".into()),
            open_uri: None,
        };
        assert!(matches!(
            system.launch(&missing, "op-3"),
            Err(SystemError::NotFound(_))
        ));
        let unknown = LauncherLaunchInput {
            app_id: None,
            open_uri: Some("gopher://x".into()),
        };
        assert!(matches!(
            system.launch(&unknown, "op-4"),
            Err(SystemError::NotFound(_))
        ));
        let relative = LauncherLaunchInput {
            app_id: None,
            open_uri: Some("note.txt".into()),
        };
        assert!(matches!(
            system.launch(&relative, "op-5"),
            Err(SystemError::Invalid(_))
        ));
        assert!(matches!(
            system.launch(&LauncherLaunchInput::default(), "op-6"),
            Err(SystemError::Invalid(_))
        ));
        assert!(matches!(
            system.lock_session(),
            Err(SystemError::Unavailable(_))
        ));
        assert!(!system.session_state().unwrap().logind_available);
    }

    #[test]
    fn inotify_picks_up_new_and_removed_entries() {
        let f = Fixture::new("watch");
        f.entry("usr", "foot.desktop", "Name=Foot\nExec=foot\n");
        let system = RealSystem::with_config(f.config(true));
        assert!(system.problems().is_empty(), "{:?}", system.problems());
        let wait_for = |query: &str, expected: usize| {
            for _ in 0..100 {
                if system.search_apps(query, 10).unwrap().apps.len() == expected {
                    return true;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            false
        };
        f.entry("home", "kate.desktop", "Name=Kate\nExec=kate\n");
        assert!(wait_for("kate", 1), "a new user entry appears");
        f.entry("home", "foot.desktop", "Hidden=true\n");
        assert!(
            wait_for("foot", 0),
            "a user Hidden entry deletes the system one"
        );
        fs::remove_file(f.root.join("home/applications/foot.desktop")).unwrap();
        assert!(wait_for("foot", 1), "removing the mask brings it back");
        fs::create_dir_all(f.root.join("usr/applications/sub")).unwrap();
        fs::write(
            f.root.join("usr/applications/sub/editor.desktop"),
            "[Desktop Entry]\nType=Application\nName=Sub Editor\nExec=e\n",
        )
        .unwrap();
        assert!(
            wait_for("sub editor", 1),
            "entries in a new subdirectory are found"
        );
    }

    struct Recorder(Mutex<Vec<String>>);

    impl NotificationHooks for Recorder {
        fn decide(&self, _: &str, _: ditto_protocol::services::Urgency) -> crate::notify::Decision {
            None
        }
        fn posted(&self, item: &NotificationItem) {
            self.0.lock().unwrap().push(format!("posted {}", item.id));
        }
        fn closed(&self, id: u32, reason: &str) {
            self.0.lock().unwrap().push(format!("closed {id} {reason}"));
        }
    }

    #[test]
    fn notifications_without_a_bus() {
        let f = Fixture::new("notify");
        let system = RealSystem::with_config(f.config(false));
        let recorder = Arc::new(Recorder(Mutex::new(Vec::new())));
        system.set_notification_hooks(recorder.clone());
        let item = system.shared.ingest(Incoming {
            app_name: "mail".into(),
            replaces_id: 0,
            summary: "new".into(),
            body: String::new(),
            urgency: ditto_protocol::services::Urgency::Normal,
        });
        assert!(
            item.policy_unavailable,
            "a hook that answers None means the policy was unreachable"
        );
        assert_eq!(system.notifications(10).unwrap().len(), 1);
        assert!(system.dismiss(item.id).unwrap());
        assert!(!system.dismiss(item.id).unwrap());
        assert_eq!(
            *recorder.0.lock().unwrap(),
            ["posted 1", "closed 1 dismissed"]
        );
    }
}
