//! Source guards for failure paths that require compositor loss, process
//! launch failures or timed reverts. The handshake has a separate stderr
//! capture test in tests.rs; these guards pin the nine typed-code consumers.

const SOURCES: &[(&str, &str)] = &[
    ("agent_manager.rs", include_str!("agent_manager.rs")),
    ("coordinator.rs", include_str!("coordinator.rs")),
    ("core.rs", include_str!("core.rs")),
    ("generation.rs", include_str!("generation.rs")),
    ("hosts.rs", include_str!("hosts.rs")),
    ("lib.rs", include_str!("lib.rs")),
    ("main.rs", include_str!("main.rs")),
    ("outputs.rs", include_str!("outputs.rs")),
    ("shell.rs", include_str!("shell.rs")),
];

#[test]
fn reason_code_fields_never_use_debug_formatting() {
    for (file, source) in SOURCES {
        for value in source.split("\"reason_code\"").skip(1) {
            let value = value.split_once(')').expect("reason_code tuple").0;
            assert!(
                !value.contains(":?}") && !value.contains(":#?}"),
                "{file}: reason_code must use a closed code, not Debug: {value}"
            );
        }
    }
}

#[test]
fn typed_error_call_sites_use_the_closed_code_converters() {
    for (file, event, converter) in [
        (
            "core.rs",
            "lock.start_failed",
            "crate::log::io_error_code(error.kind())",
        ),
        (
            "hosts.rs",
            "host.start_refused",
            "crate::log::io_error_code(error.kind())",
        ),
        (
            "shell.rs",
            "shell.start_failed",
            "crate::log::io_error_code(error.kind())",
        ),
        (
            "shell.rs",
            "shell.rescue_ui_failed",
            "crate::log::io_error_code(error.kind())",
        ),
        (
            "main.rs",
            "compositor.unreachable",
            "ditto_core::log::io_error_code(error.kind())",
        ),
        (
            "main.rs",
            "launch.failed",
            "ditto_core::log::io_error_code(error.kind())",
        ),
        (
            "main.rs",
            "connection.ended",
            "ditto_core::log::io_error_code(error.kind())",
        ),
        ("main.rs", "shortcut.command_failed", "error.name.as_str()"),
        (
            "coordinator.rs",
            "change.timed_revert_failed",
            "error.name.as_str()",
        ),
    ] {
        let source = SOURCES.iter().find(|(name, _)| *name == file).unwrap().1;
        // Ignore rustfmt whitespace; stop at the end of this event's fields
        // so a safe converter at a neighbouring call cannot satisfy the guard.
        let compact: String = source.chars().filter(|c| !c.is_whitespace()).collect();
        let marker = format!("\"{event}\",");
        let fields = compact.split_once(&marker).expect("log event").1;
        let fields = fields.split_once("],").expect("log fields").0;
        let expected = format!("(\"reason_code\",{converter})");
        assert!(
            fields.contains(&expected),
            "{file}: {event} must use {converter}"
        );
    }
}

#[test]
fn supervised_ui_exits_have_structured_status_events() {
    for (file, event) in [
        ("shell.rs", "shell.exited"),
        ("core.rs", "lock.exited"),
        ("shell.rs", "rescue.exited"),
    ] {
        let source = SOURCES.iter().find(|(name, _)| *name == file).unwrap().1;
        assert!(
            source.contains(&format!("crate::log::process_exit(\"{event}\", status)")),
            "{file} must log the reaped exit status"
        );
    }
}
