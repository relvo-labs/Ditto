//! Structured log lines on stderr for journald (REC-06): one JSON object per
//! line with `session_id`, `change_id` and `operation_id` when the
//! event has them. Redaction happens here, before anything is written: window
//! titles, notification text, clipboard content, proposal subjects, error text,
//! launch arguments and paths under the home directory never reach the log.

use std::{io::Write, sync::OnceLock};

use serde_json::{json, Map, Value};

/// Field names whose values are content, not diagnostics.
const CONTENT_KEYS: &[&str] = &[
    "title",
    "summary",
    "body",
    "clipboard",
    "text",
    "content",
    "window_title",
    "subject",
    "reason",
    "error",
    "spec",
];

static SESSION: OnceLock<String> = OnceLock::new();

pub fn set_session(session_id: &str) {
    let _ = SESSION.set(session_id.to_string());
}

pub fn redact_value(key: &str, value: &str) -> String {
    if CONTENT_KEYS.contains(&key) {
        return "[redacted]".into();
    }
    redact_paths(value)
}

/// Replace anything below `$HOME` with `~/…`: the fact that a path was used
/// is diagnostic, which file it was is not.
pub fn redact_paths(text: &str) -> String {
    let Some(home) = std::env::var_os("HOME").map(|home| home.to_string_lossy().into_owned())
    else {
        return text.to_string();
    };
    if home.len() < 2 {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(index) = rest.find(&home) {
        out.push_str(&rest[..index]);
        out.push_str("~/…");
        let after = &rest[index + home.len()..];
        let end = after
            .find(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == ',')
            .unwrap_or(after.len());
        rest = &after[end..];
    }
    out.push_str(rest);
    out
}

pub fn line(name: &str, fields: &[(&str, &str)]) -> String {
    let mut object = Map::new();
    object.insert("ts".into(), json!(ditto_store::time::now()));
    object.insert("event".into(), json!(name));
    if let Some(session) = SESSION.get() {
        object.insert("session_id".into(), json!(session));
    }
    for (key, value) in fields {
        object.insert((*key).into(), Value::String(redact_value(key, value)));
    }
    Value::Object(object).to_string()
}

pub fn event(name: &str, fields: &[(&str, &str)]) {
    let text = line(name, fields);
    let mut stderr = std::io::stderr().lock();
    let _ = writeln!(stderr, "{text}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draft_subject_is_redacted_while_change_id_remains_traceable() {
        let subject = "QA04_PRIVATE_PROPOSAL_SUBJECT 私人提案";
        let text = line(
            "change.draft",
            &[("change_id", "chg-private-subject"), ("subject", subject)],
        );
        assert!(!text.contains(subject), "{text}");
        let logged: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(logged["event"], "change.draft");
        assert_eq!(logged["subject"], "[redacted]");
        assert_eq!(logged["change_id"], "chg-private-subject");
    }

    #[test]
    fn free_text_errors_and_launch_arguments_never_reach_the_log() {
        let fields = [
            ("reason", "backend rejected QA04_PRIVATE_ERROR_CONTENT"),
            ("error", "worker failed with QA04_PRIVATE_WORKER_CONTENT"),
            ("spec", "dittoctl 0.3.0 command QA04_PRIVATE_LAUNCH_ARGUMENT"),
            ("operation_id", "op-1"),
        ];
        let text = line("failure", &fields);
        let logged: Value = serde_json::from_str(&text).unwrap();
        for (key, value) in &fields[..3] {
            assert!(!text.contains(value), "{text}");
            assert_eq!(logged[*key], "[redacted]");
        }
        assert_eq!(logged["operation_id"], "op-1");
    }

    #[test]
    fn content_and_home_paths_never_reach_the_log() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/tester".into());
        std::env::set_var("HOME", &home);
        let text = line(
            "window.focus",
            &[
                ("change_id", "chg-1"),
                ("title", "Secret plans.odt — LibreOffice"),
                ("summary", "Your bank code is 1234"),
                (
                    "detail",
                    &format!("opened {home}/Documents/todo.txt for grant-1"),
                ),
            ],
        );
        assert!(!text.contains("Secret plans"), "{text}");
        assert!(!text.contains("1234"), "{text}");
        assert!(!text.contains("Documents/todo.txt"), "{text}");
        assert!(text.contains("chg-1"));
        assert!(text.contains("grant-1"));
    }
}
