//! Profile export and import validation (G1-CORE-09). An export carries the
//! document, package locks and schema version; never plugin data, never the
//! paths behind file grants, never anything that looks like a secret. An
//! import is a declaration to check, not instructions to run (CFG-04).

use std::collections::BTreeSet;

use ditto_protocol::{
    jcs,
    profile::{
        EntrySpec, ImportProblem, ImportProblemKind, PackageLock, ProfileDocument, ProfileExport,
    },
    PROTOCOL_VERSION,
};
use serde_json::{json, Value};

use crate::projection::PackageSet;

pub const FORMAT: &str = "ditto-profile";
pub const FORMAT_VERSION: u32 = 1;

const SECRET_MARKERS: &[&str] = &[
    "-----BEGIN",
    "sk-",
    "ghp_",
    "xoxb-",
    "AKIA",
    "api_key",
    "apikey",
    "password",
    "secret",
    "token",
];

fn looks_private_path(text: &str) -> bool {
    text.starts_with("/home/")
        || text.starts_with("/root/")
        || text.starts_with("~/")
        || text.starts_with("file:///home/")
        || std::env::var("HOME").is_ok_and(|home| home.len() > 1 && text.starts_with(&home))
}

fn looks_secret(key: &str, text: &str) -> bool {
    let key = key.to_ascii_lowercase();
    [
        "password",
        "secret",
        "token",
        "api_key",
        "apikey",
        "credential",
    ]
    .iter()
    .any(|marker| key.contains(marker))
        || SECRET_MARKERS[..5]
            .iter()
            .any(|marker| text.starts_with(marker))
        || text.contains("-----BEGIN")
}

/// Walk every string in `value`; returns (pointer, kind) of offenders.
pub fn scan(value: &Value) -> Vec<(String, ImportProblemKind)> {
    let mut found = Vec::new();
    walk(value, String::new(), "", &mut found);
    found
}

fn walk(value: &Value, pointer: String, key: &str, found: &mut Vec<(String, ImportProblemKind)>) {
    match value {
        Value::String(text) => {
            if looks_secret(key, text) {
                found.push((pointer, ImportProblemKind::SecretDetected));
            } else if looks_private_path(text) {
                found.push((pointer, ImportProblemKind::PrivatePathDetected));
            }
        }
        Value::Array(items) => {
            for (index, item) in items.iter().enumerate() {
                walk(item, format!("{pointer}/{index}"), key, found);
            }
        }
        Value::Object(map) => {
            for (child, item) in map {
                let escaped = child.replace('~', "~0").replace('/', "~1");
                walk(item, format!("{pointer}/{escaped}"), child, found);
            }
        }
        _ => {}
    }
}

fn grant_references(value: &Value, out: &mut BTreeSet<String>) {
    match value {
        Value::String(text)
            if ditto_protocol::ids::has_prefix(text, ditto_protocol::ids::GRANT) =>
        {
            out.insert(text.clone());
        }
        Value::Array(items) => items.iter().for_each(|item| grant_references(item, out)),
        Value::Object(map) => map.values().for_each(|item| grant_references(item, out)),
        _ => {}
    }
}

pub fn export(
    name: &str,
    document: &ProfileDocument,
    packages: &PackageSet,
) -> Result<ProfileExport, String> {
    let mut value = document.to_value();
    let offenders = scan(&value);
    let mut redacted = Vec::new();
    for (pointer, _) in &offenders {
        if let Some(slot) = value.pointer_mut(pointer) {
            *slot = Value::Null;
            redacted.push(pointer.clone());
        }
    }
    // Nulling a field can make an entry config invalid for its schema; the
    // importer sees the pointers and is asked to fill them in again.
    // A required typed field cannot always be replaced with null. Returning
    // the original document here would put the value we just found back into
    // the export. Refuse the export instead.
    let document: ProfileDocument = serde_json::from_value(value.clone())
        .map_err(|error| format!("redaction would invalidate the profile document: {error}"))?;
    let mut grants = BTreeSet::new();
    grant_references(&value, &mut grants);
    let mut locks: Vec<PackageLock> = document
        .entries
        .iter()
        .filter_map(|entry| {
            packages
                .get(&entry.package, &entry.version)
                .map(|row| PackageLock {
                    package: entry.package.clone(),
                    version: entry.version.clone(),
                    sha256: row.summary.sha256.clone(),
                })
        })
        .collect();
    locks.sort_by(|a, b| (&a.package, &a.version).cmp(&(&b.package, &b.version)));
    locks.dedup();
    let export = ProfileExport {
        format: FORMAT.into(),
        format_version: FORMAT_VERSION,
        protocol_version: PROTOCOL_VERSION.into(),
        profile_name: name.into(),
        document_sha256: document.digest(),
        document,
        packages: locks,
        required_grants: grants.into_iter().collect(),
        redacted,
    };
    // The document scan alone does not cover the profile name or package
    // metadata. Refuse the whole export if those contain a private value.
    if !scan(&serde_json::to_value(&export).map_err(|error| error.to_string())?).is_empty() {
        return Err("the profile export still contains a private value".into());
    }
    Ok(export)
}

fn problem(kind: ImportProblemKind, blocking: bool, detail: Value) -> ImportProblem {
    let key = serde_json::to_value(kind)
        .ok()
        .and_then(|value| value.as_str().map(String::from))
        .unwrap_or_default();
    ImportProblem {
        kind,
        blocking,
        detail_key: format!("import.{key}"),
        detail: match detail {
            Value::Object(map) => map.into_iter().collect(),
            _ => Default::default(),
        },
    }
}

/// Why an imported entry's config does not fit its package's
/// `config_schema`, in the detail shape preflight uses.
fn config_problem(entry: &EntrySpec, schema: &Value) -> Option<Value> {
    let mut detail = if !entry.config.is_object() {
        json!({"why": "config_not_object"})
    } else {
        match crate::config_schema::check(schema, &entry.config) {
            Ok(violations) if violations.is_empty() => return None,
            Ok(violations) => json!({
                "why": "config_schema_violation",
                "pointer": violations[0].pointer,
                "violation_count": violations.len(),
            }),
            Err(unsupported) => json!({
                "why": "config_schema_unsupported",
                "schema_pointer": unsupported.schema_pointer,
            }),
        }
    };
    detail["entry_id"] = json!(entry.entry_id);
    detail["package"] = json!(entry.package);
    detail["version"] = json!(entry.version);
    Some(detail)
}

/// Validate without executing anything. Returns the parsed export when it is
/// structurally usable, plus every problem found.
pub fn validate(raw: &Value, packages: &PackageSet) -> (Option<ProfileExport>, Vec<ImportProblem>) {
    let mut problems = Vec::new();
    for (pointer, kind) in scan(raw) {
        problems.push(problem(kind, true, json!({"pointer": pointer})));
    }
    let export: ProfileExport = match serde_json::from_value(raw.clone()) {
        Ok(export) => export,
        Err(error) => {
            problems.push(problem(
                ImportProblemKind::SchemaInvalid,
                true,
                json!({"why": error.to_string()}),
            ));
            return (None, problems);
        }
    };
    if export.format != FORMAT || export.format_version != FORMAT_VERSION {
        problems.push(problem(
            ImportProblemKind::FormatUnsupported,
            true,
            json!({"format": export.format, "version": export.format_version}),
        ));
    }
    let protocol_ok = semver::Version::parse(&export.protocol_version)
        .ok()
        .zip(semver::Version::parse(PROTOCOL_VERSION).ok())
        .is_some_and(|(theirs, ours)| theirs.major == ours.major && theirs.minor == ours.minor);
    if !protocol_ok {
        problems.push(problem(
            ImportProblemKind::ProtocolIncompatible,
            true,
            json!({"protocol_version": export.protocol_version}),
        ));
    }
    if export.document.digest() != export.document_sha256 {
        problems.push(problem(ImportProblemKind::DigestMismatch, true, json!({})));
    }
    for entry in &export.document.entries {
        let lock = export
            .packages
            .iter()
            .find(|lock| lock.package == entry.package && lock.version == entry.version);
        match packages.get(&entry.package, &entry.version) {
            None => problems.push(problem(
                ImportProblemKind::PackageMissing,
                true,
                json!({"package": entry.package, "version": entry.version}),
            )),
            Some(row) => {
                if lock.is_some_and(|lock| lock.sha256 != row.summary.sha256) {
                    problems.push(problem(
                        ImportProblemKind::IntegrityMismatch,
                        true,
                        json!({"package": entry.package, "version": entry.version}),
                    ));
                }
                if let Some(detail) = config_problem(entry, &row.manifest.config_schema) {
                    // Not blocking: an export nulls redacted values, which a
                    // schema may refuse, and the person fills them in after
                    // the import. The imported Profile is not active; the
                    // switch to it runs preflight, which refuses the config
                    // until it is fixed (#161).
                    problems.push(problem(ImportProblemKind::SchemaInvalid, false, detail));
                }
            }
        }
    }
    for grant in &export.required_grants {
        problems.push(problem(
            ImportProblemKind::GrantRequired,
            false,
            json!({"grant": grant}),
        ));
    }
    (Some(export), problems)
}

pub fn sha256_of(value: &Value) -> String {
    jcs::digest(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::docops::tests::document;

    #[test]
    fn exports_drop_private_paths_and_secrets_and_imports_refuse_them() {
        let mut doc = document();
        doc.entries[0].config = json!({"source": {"kind": "todo_txt", "path_grant": "grant-01J9ZZZZZZZZZZZZZZZZZZZZZZ", "path": "/home/someone/todo.txt"}, "api_key": "abc"});
        let export = export("開發", &doc, &PackageSet::default()).unwrap();
        let text = serde_json::to_string(&export).unwrap();
        assert!(!text.contains("/home/someone"));
        assert!(!text.contains("\"abc\""));
        assert_eq!(export.redacted.len(), 2);
        assert_eq!(
            export.required_grants,
            vec!["grant-01J9ZZZZZZZZZZZZZZZZZZZZZZ".to_string()]
        );
        let mut tampered = serde_json::to_value(&export).unwrap();
        tampered["document"]["entries"][0]["config"]["path"] = json!("/home/other/secret.txt");
        let (_, problems) = validate(&tampered, &PackageSet::default());
        assert!(problems
            .iter()
            .any(|p| p.kind == ImportProblemKind::PrivatePathDetected && p.blocking));
        assert!(problems
            .iter()
            .any(|p| p.kind == ImportProblemKind::DigestMismatch));
        assert!(problems
            .iter()
            .any(|p| p.kind == ImportProblemKind::PackageMissing));
    }

    #[test]
    fn export_refuses_a_sensitive_required_field_instead_of_restoring_it() {
        let mut doc = document();
        doc.appearance.theme = "/home/someone/private-theme".into();
        assert!(export("開發", &doc, &PackageSet::default()).is_err());
    }

    #[test]
    fn export_refuses_a_sensitive_profile_name() {
        let doc = document();
        assert!(export("/home/someone/private", &doc, &PackageSet::default()).is_err());
    }
}
