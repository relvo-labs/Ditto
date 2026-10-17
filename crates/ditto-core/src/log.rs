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

/// Match the typed store failure, never its Display text or SQLite payload.
pub fn store_error_code(error: &ditto_store::StoreError) -> &'static str {
    use ditto_store::StoreError;
    match error {
        StoreError::StorageFull => "storage_full",
        StoreError::Io(_) => "storage_io",
        StoreError::Corrupt(_) => "store_corrupt",
        StoreError::Locked => "store_locked",
        StoreError::NotFound(_) => "not_found",
        StoreError::Conflict(_) => "conflict",
        StoreError::Invalid(_) => "invalid",
        StoreError::Sqlite(_) => "sqlite",
    }
}

/// Diagnostic category only; this does not validate or grant caller identity.
pub fn subject_kind(subject: &str) -> &'static str {
    use ditto_protocol::Subject;
    match subject {
        Subject::SHELL => "shell",
        Subject::CLI => "cli",
        Subject::CLI_RESCUE => "cli_rescue",
        Subject::RESCUE_UI => "rescue_ui",
        Subject::AGENT => "agent",
        Subject::LOCK => "lock",
        Subject::CORE => "core",
        "hostd" => "host",
        _ if subject.starts_with("host:") => "host",
        _ => "unknown",
    }
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
    fn classified_reason_sites_keep_closed_causes_and_redact_text() {
        let private = "QA04_PRIVATE_FAILURE_CONTENT 私人錯誤";
        let store = ditto_store::StoreError::Invalid(private.into());
        let store_code = store_error_code(&store);
        let io = std::io::Error::new(std::io::ErrorKind::PermissionDenied, private);
        let io_code = format!("{:?}", io.kind());
        let core = crate::error::CoreError::internal(private);
        let core_code = format!("{:?}", core.name);
        // All 27 original reason sites, including both builtin failure paths.
        let sites = [
            (
                "agent.backend_refused",
                Some(crate::agent_backend::Refusal::LaunchFailed.as_str()),
            ),
            ("retention.failed", Some(store_code)),
            ("jobs.recovery_cleanup_failed", Some(store_code)),
            ("boot.profile_failed", Some(store_code)),
            ("agent.tools_reconcile_failed", Some(store_code)),
            ("boot.builtin_refused", Some(store_code)), // insert
            ("boot.builtin_refused", Some(store_code)), // unpack
            ("generation.journal_failed", Some(store_code)),
            ("change.commit_write_failed", Some(store_code)),
            ("change.timed_revert_failed", Some(core_code.as_str())),
            ("recovery.read_failed", Some(store_code)),
            ("host.lost", Some("connection_closed")),
            ("lock.start_failed", Some(io_code.as_str())),
            ("generation.journal_recovery_failed", Some(store_code)),
            ("host.start_refused", Some(io_code.as_str())),
            ("connection.identity_rejected", Some("binding_mismatch")),
            ("compositor.unreachable", Some(io_code.as_str())),
            ("system.component_unavailable", None),
            ("core.store_refused", Some(store_code)),
            ("shortcut.command_failed", Some(core_code.as_str())),
            ("launch.failed", Some(io_code.as_str())),
            ("connection.ended", Some(io_code.as_str())),
            ("outputs.rescue_failed", Some("internal")),
            ("outputs.window_stranded", Some("unsupported")),
            ("outputs.notice_failed", Some("failed")),
            ("shell.start_failed", Some(io_code.as_str())),
            ("shell.rescue_ui_failed", Some(io_code.as_str())),
        ];
        for (event, code) in sites {
            let mut fields = vec![
                ("reason", private),
                ("change_id", "chg-cause"),
                ("operation_id", "op-cause"),
            ];
            if let Some(code) = code {
                fields.push(("reason_code", code));
            }
            let text = line(event, &fields);
            assert!(!text.contains(private), "{text}");
            let logged: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(logged["event"], event);
            assert_eq!(logged["reason"], "[redacted]");
            assert_eq!(logged.get("reason_code"), code.map(|c| json!(c)).as_ref());
            assert_eq!(logged["change_id"], "chg-cause");
            assert_eq!(logged["operation_id"], "op-cause");
        }
    }

    #[test]
    fn store_error_codes_ignore_all_variant_payloads() {
        use ditto_store::StoreError;
        let private = "QA04_PRIVATE_STORE_CONTENT";
        let cases = [
            (StoreError::StorageFull, "storage_full"),
            (StoreError::Io(private.into()), "storage_io"),
            (StoreError::Corrupt(private.into()), "store_corrupt"),
            (StoreError::Locked, "store_locked"),
            (StoreError::NotFound(private.into()), "not_found"),
            (StoreError::Conflict(private.into()), "conflict"),
            (StoreError::Invalid(private.into()), "invalid"),
            (
                StoreError::Sqlite(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(1),
                    Some(private.into()),
                )),
                "sqlite",
            ),
        ];
        for (error, expected) in cases {
            let text = line(
                "core.store_refused",
                &[
                    ("reason", &error.to_string()),
                    ("reason_code", store_error_code(&error)),
                ],
            );
            assert!(!text.contains(private), "{text}");
            let logged: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(logged["reason_code"], expected);
            assert_eq!(logged["reason"], "[redacted]");
        }
    }

    #[test]
    fn subject_categories_are_closed_and_never_expose_identity_payloads() {
        let cases = [
            ("shell", "shell"),
            ("cli", "cli"),
            ("cli:rescue", "cli_rescue"),
            ("rescue_ui", "rescue_ui"),
            ("agent", "agent"),
            ("lock", "lock"),
            ("core", "core"),
            ("hostd", "host"),
            ("host:QA04_PRIVATE_ENTRY", "host"),
            ("QA04_PRIVATE_SUBJECT", "unknown"),
            ("agent.QA04_PRIVATE_SUBJECT", "unknown"),
        ];
        for event in ["change.draft", "change.dropped_before_acceptance"] {
            for (subject, category) in cases {
                let text = line(
                    event,
                    &[
                        ("subject", subject),
                        ("subject_kind", subject_kind(subject)),
                        ("change_id", "chg-category"),
                        ("operation_id", "op-category"),
                    ],
                );
                assert!(!text.contains("QA04_PRIVATE"), "{text}");
                let logged: Value = serde_json::from_str(&text).unwrap();
                assert_eq!(logged["subject"], "[redacted]");
                assert_eq!(logged["subject_kind"], category);
                assert_eq!(logged["change_id"], "chg-category");
                assert_eq!(logged["operation_id"], "op-category");
            }
        }
    }

    #[test]
    fn code_shaped_reason_text_is_still_content() {
        for reason in ["binding_mismatch", "backend_launch_failed", "QA04_PRIVATE"] {
            let text = line("failure", &[("reason", reason)]);
            let logged: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(logged["reason"], "[redacted]");
            assert!(logged.get("reason_code").is_none());
        }
    }

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
            (
                "spec",
                "dittoctl 0.3.0 command QA04_PRIVATE_LAUNCH_ARGUMENT",
            ),
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
