//! The notification server on a private session bus. The test starts its own
//! `dbus-daemon` rather than using the developer's bus, where a real
//! notification daemon may own the name; without `dbus-daemon` it is skipped
//! and says why.
#![cfg(feature = "dbus")]

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ditto_protocol::services::{NotificationItem, PolicyDecision, Urgency};
use ditto_system::{NotificationHooks, RealSystem, RealSystemConfig, SystemServices};
use zbus::zvariant::Value;

struct Bus(Child);

impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn private_bus() -> Option<(Bus, String)> {
    let mut child = Command::new("dbus-daemon")
        .args(["--session", "--nofork", "--print-address=1"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut line = String::new();
    BufReader::new(child.stdout.take()?)
        .read_line(&mut line)
        .ok()?;
    Some((Bus(child), line.trim().to_string()))
}

struct Policy(Mutex<Vec<String>>);

impl NotificationHooks for Policy {
    fn decide(&self, app_name: &str, _: Urgency) -> Option<(PolicyDecision, Option<String>)> {
        match app_name {
            "quiet" => Some((PolicyDecision::Silence, Some("rule-quiet".into()))),
            "slow" => {
                std::thread::sleep(Duration::from_millis(500));
                Some((PolicyDecision::Silence, None))
            }
            _ => Some((PolicyDecision::Show, None)),
        }
    }
    fn posted(&self, item: &NotificationItem) {
        self.0
            .lock()
            .unwrap()
            .push(format!("posted {} {}", item.id, item.app_name));
    }
    fn closed(&self, id: u32, reason: &str) {
        self.0.lock().unwrap().push(format!("closed {id} {reason}"));
    }
}

fn config(root: &std::path::Path) -> RealSystemConfig {
    let mut config = RealSystemConfig::from_env(root.join("app-index.db"));
    config.application_dirs = vec![root.join("applications")];
    config.watch = false;
    config.logind = false;
    config
}

#[test]
fn serves_org_freedesktop_notifications() {
    let Some((_bus, address)) = private_bus() else {
        eprintln!(
            "skipped: dbus-daemon is not available, so no private session bus can be started"
        );
        return;
    };
    // The only test in this binary, so setting the variable races nothing.
    std::env::set_var("DBUS_SESSION_BUS_ADDRESS", &address);
    let root = std::env::temp_dir().join(format!("ditto-system-bus-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();

    let system = RealSystem::with_config(config(&root));
    assert!(
        system.notification_server_owned(),
        "{:?}",
        system.problems()
    );
    assert!(system.component_available("notifications"));
    let hooks = Arc::new(Policy(Mutex::new(Vec::new())));
    system.set_notification_hooks(hooks.clone());

    let client = zbus::blocking::Connection::session().unwrap();
    let proxy = zbus::blocking::Proxy::new(
        &client,
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
    )
    .unwrap();
    let (name, vendor, _version, spec): (String, String, String, String) =
        proxy.call("GetServerInformation", &()).unwrap();
    assert_eq!(
        (name.as_str(), vendor.as_str(), spec.as_str()),
        ("Ditto", "Ditto", "1.2")
    );
    let capabilities: Vec<String> = proxy.call("GetCapabilities", &()).unwrap();
    assert!(capabilities.contains(&"body".to_string()));

    let notify = |app: &str, urgency: u8| -> u32 {
        let hints: HashMap<&str, Value<'_>> = HashMap::from([("urgency", Value::U8(urgency))]);
        proxy
            .call(
                "Notify",
                &(
                    app,
                    0u32,
                    "",
                    "summary",
                    "body",
                    Vec::<&str>::new(),
                    hints,
                    -1i32,
                ),
            )
            .unwrap()
    };
    let shown = notify("mail", 1);
    let quiet = notify("quiet", 1);
    let critical = notify("quiet", 2);
    let started = std::time::Instant::now();
    let slow = notify("slow", 1);
    assert!(
        started.elapsed() < Duration::from_millis(300),
        "Notify waited {:?}",
        started.elapsed()
    );

    let items = system.notifications(10).unwrap();
    let by_id = |id: u32| items.iter().find(|item| item.id == id).unwrap().clone();
    assert_eq!(by_id(shown).decision, PolicyDecision::Show);
    assert_eq!(by_id(quiet).decision, PolicyDecision::Silence);
    assert_eq!(
        by_id(critical).decision,
        PolicyDecision::Show,
        "critical is always shown"
    );
    assert!(
        by_id(slow).policy_unavailable,
        "a policy past its bound counts as unavailable"
    );
    assert_eq!(by_id(slow).decision, PolicyDecision::Show);

    let closed = zbus::blocking::MessageIterator::for_match_rule(
        "type='signal',interface='org.freedesktop.Notifications',member='NotificationClosed'",
        &client,
        Some(8),
    )
    .unwrap();
    let () = proxy.call("CloseNotification", &(shown,)).unwrap();
    assert!(system.dismiss(quiet).unwrap());
    let reasons: Vec<(u32, u32)> = closed
        .take(2)
        .map(|message| message.unwrap().body().deserialize::<(u32, u32)>().unwrap())
        .collect();
    assert_eq!(reasons, [(shown, 3), (quiet, 2)]);
    assert!(hooks
        .0
        .lock()
        .unwrap()
        .contains(&format!("closed {shown} closed_by_call")));

    // A second server does not take the name; it reports that it could not.
    let second = RealSystem::with_config(config(&root));
    assert!(!second.notification_server_owned());
    assert!(!second.component_available("notifications"));
    assert!(second
        .problems()
        .iter()
        .any(|(component, _)| component == "notifications"));
    let _ = std::fs::remove_dir_all(&root);
}
