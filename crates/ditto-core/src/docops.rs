//! Apply ChangeSet ops to a Profile document, and describe the difference
//! between two documents as change-card items. Pure functions: no store, no
//! participant, no clock. Preflight and `profiles.diff` both build on them.

use std::collections::{BTreeMap, BTreeSet};

use ditto_protocol::{
    change::{ChangeCard, ChangeOp, PreflightCode, PreflightReason},
    ids,
    profile::{DiffItem, DiffKind, EntrySpec, ProfileDocument, SLOTS},
};
use serde_json::{json, Value};

/// Paths a `set_value` op may write. Entries and slots change only through
/// their own ops, so the entry id and slot invariants cannot be bypassed.
pub const WRITABLE_ROOTS: &[&str] = &["/appearance", "/avatar", "/layout", "/shortcuts"];

pub fn reason(code: PreflightCode, op_index: Option<usize>, detail: Value) -> PreflightReason {
    PreflightReason {
        code,
        op_index: op_index.map(|index| index as u32),
        detail_key: code.key(),
        detail: match detail {
            Value::Object(map) => map.into_iter().collect(),
            Value::Null => BTreeMap::new(),
            other => [("value".to_string(), other)].into_iter().collect(),
        },
    }
}

pub struct Applied {
    pub document: ProfileDocument,
    /// The ops with `before` filled from the base and new entry ids assigned.
    pub ops: Vec<ChangeOp>,
    pub reasons: Vec<PreflightReason>,
}

fn pointer_parent<'a>(root: &'a mut Value, pointer: &str) -> Option<(&'a mut Value, String)> {
    let (parent, last) = pointer.rsplit_once('/')?;
    let key = last.replace("~1", "/").replace("~0", "~");
    let parent = if parent.is_empty() {
        Some(root)
    } else {
        root.pointer_mut(parent)
    }?;
    Some((parent, key))
}

fn set_pointer(root: &mut Value, pointer: &str, value: Value) -> Result<(), String> {
    let (parent, key) = pointer_parent(root, pointer).ok_or("path does not exist")?;
    match parent {
        Value::Object(map) => {
            map.insert(key, value);
            Ok(())
        }
        Value::Array(items) => {
            let index: usize = key.parse().map_err(|_| "array index expected")?;
            if index < items.len() {
                items[index] = value;
                Ok(())
            } else if index == items.len() {
                items.push(value);
                Ok(())
            } else {
                Err("array index out of range".into())
            }
        }
        _ => Err("path does not name a container".into()),
    }
}

/// Apply every op in order to `base`, collecting every problem instead of
/// stopping at the first, so the caller sees all of them at once.
pub fn apply(base: &ProfileDocument, ops: &[ChangeOp]) -> Applied {
    let mut document = base.clone();
    let mut normalized = Vec::with_capacity(ops.len());
    let mut reasons = Vec::new();
    for (index, op) in ops.iter().enumerate() {
        let at = Some(index);
        match op {
            ChangeOp::SetValue {
                path,
                before,
                after,
            } => {
                if !WRITABLE_ROOTS
                    .iter()
                    .any(|root| path == root || path.starts_with(&format!("{root}/")))
                {
                    reasons.push(reason(
                        PreflightCode::SchemaInvalid,
                        at,
                        json!({"path": path, "why": "path_not_writable"}),
                    ));
                    normalized.push(op.clone());
                    continue;
                }
                let mut value = document.to_value();
                let actual = value.pointer(path).cloned();
                if let (Some(expected), Some(actual)) = (before, &actual) {
                    if expected != actual {
                        reasons.push(reason(
                            PreflightCode::StaleIntent,
                            at,
                            json!({"path": path}),
                        ));
                    }
                } else if before.is_some() && actual.is_none() {
                    reasons.push(reason(
                        PreflightCode::StaleIntent,
                        at,
                        json!({"path": path}),
                    ));
                }
                match set_pointer(&mut value, path, after.clone()).and_then(|()| {
                    serde_json::from_value::<ProfileDocument>(value).map_err(|e| e.to_string())
                }) {
                    Ok(changed) => document = changed,
                    Err(why) => reasons.push(reason(
                        PreflightCode::SchemaInvalid,
                        at,
                        json!({"path": path, "why": why}),
                    )),
                }
                normalized.push(ChangeOp::SetValue {
                    path: path.clone(),
                    before: actual,
                    after: after.clone(),
                });
            }
            ChangeOp::AddEntry { entry, slot } => {
                let entry_id = ids::new(ids::ENTRY);
                if !entry.config.is_object() {
                    reasons.push(reason(
                        PreflightCode::SchemaInvalid,
                        at,
                        json!({"why": "config_not_object"}),
                    ));
                }
                document.entries.push(EntrySpec {
                    entry_id: entry_id.clone(),
                    package: entry.package.clone(),
                    version: entry.version.clone(),
                    host: entry.host,
                    config: entry.config.clone(),
                    disabled: entry.disabled,
                });
                if let Some(slot) = slot {
                    if !SLOTS.contains(&slot.as_str()) {
                        reasons.push(reason(
                            PreflightCode::SchemaInvalid,
                            at,
                            json!({"slot": slot, "why": "unknown_slot"}),
                        ));
                    } else {
                        document.slots.insert(slot.clone(), entry_id.clone());
                    }
                }
                // The id Core assigned lives in the target document, which is
                // what readback and recovery compare against.
                normalized.push(op.clone());
            }
            ChangeOp::RemoveEntry { entry_id } => {
                let before_count = document.entries.len();
                document.entries.retain(|entry| &entry.entry_id != entry_id);
                if document.entries.len() == before_count {
                    reasons.push(reason(
                        PreflightCode::StaleIntent,
                        at,
                        json!({"entry_id": entry_id, "why": "no_such_entry"}),
                    ));
                }
                document.slots.retain(|_, bound| bound != entry_id);
                normalized.push(op.clone());
            }
            ChangeOp::SetEntryConfig {
                entry_id,
                before,
                after,
            } => {
                let actual = document.entry(entry_id).map(|entry| entry.config.clone());
                match (&actual, before) {
                    (None, _) => reasons.push(reason(
                        PreflightCode::StaleIntent,
                        at,
                        json!({"entry_id": entry_id, "why": "no_such_entry"}),
                    )),
                    (Some(actual), Some(expected)) if actual != expected => reasons.push(reason(
                        PreflightCode::StaleIntent,
                        at,
                        json!({"entry_id": entry_id}),
                    )),
                    _ => {}
                }
                if !after.is_object() {
                    reasons.push(reason(
                        PreflightCode::SchemaInvalid,
                        at,
                        json!({"why": "config_not_object"}),
                    ));
                }
                if let Some(entry) = document.entry_mut(entry_id) {
                    entry.config = after.clone();
                }
                normalized.push(ChangeOp::SetEntryConfig {
                    entry_id: entry_id.clone(),
                    before: actual,
                    after: after.clone(),
                });
            }
            ChangeOp::SetEntryDisabled { entry_id, disabled } => {
                match document.entry_mut(entry_id) {
                    Some(entry) => entry.disabled = *disabled,
                    None => reasons.push(reason(
                        PreflightCode::StaleIntent,
                        at,
                        json!({"entry_id": entry_id, "why": "no_such_entry"}),
                    )),
                }
                normalized.push(op.clone());
            }
            ChangeOp::BindSlot { slot, from, to } => {
                if !SLOTS.contains(&slot.as_str()) {
                    reasons.push(reason(
                        PreflightCode::SchemaInvalid,
                        at,
                        json!({"slot": slot, "why": "unknown_slot"}),
                    ));
                }
                let actual = document.slots.get(slot).cloned();
                if from.is_some() && from != &actual {
                    reasons.push(reason(
                        PreflightCode::StaleIntent,
                        at,
                        json!({"slot": slot}),
                    ));
                }
                if document.entry(to).is_none() {
                    reasons.push(reason(
                        PreflightCode::StaleIntent,
                        at,
                        json!({"entry_id": to, "why": "no_such_entry"}),
                    ));
                }
                document.slots.insert(slot.clone(), to.clone());
                normalized.push(ChangeOp::BindSlot {
                    slot: slot.clone(),
                    from: actual,
                    to: to.clone(),
                });
            }
            ChangeOp::SwitchProfile { .. } => {
                // Resolved by the coordinator: the target is another profile's
                // head, not an edit of this document.
                if ops.len() != 1 {
                    reasons.push(reason(
                        PreflightCode::SchemaInvalid,
                        at,
                        json!({"why": "switch_profile_must_be_alone"}),
                    ));
                }
                normalized.push(op.clone());
            }
        }
    }
    Applied {
        document,
        ops: normalized,
        reasons,
    }
}

/// Entries whose content differs between two documents, by id.
pub fn changed_entries(base: &ProfileDocument, target: &ProfileDocument) -> BTreeSet<String> {
    let mut ids = BTreeSet::new();
    for entry in &target.entries {
        if base.entry(&entry.entry_id) != Some(entry) {
            ids.insert(entry.entry_id.clone());
        }
    }
    for entry in &base.entries {
        if target.entry(&entry.entry_id).is_none() {
            ids.insert(entry.entry_id.clone());
        }
    }
    ids
}

fn item(
    path: String,
    kind: DiffKind,
    before: Option<Value>,
    after: Option<Value>,
    key: &str,
    args: Value,
) -> DiffItem {
    DiffItem {
        path,
        kind,
        before,
        after,
        label_key: key.into(),
        label_args: match args {
            Value::Object(map) => map.into_iter().collect(),
            _ => BTreeMap::new(),
        },
    }
}

fn package_of(document: &ProfileDocument, entry_id: Option<&String>) -> Value {
    entry_id
        .and_then(|id| document.entry(id))
        .map_or(Value::Null, |entry| json!(entry.package))
}

/// A structured difference in the change-card format: every item carries a
/// translation key; product text is the Shell's job.
pub fn diff(base: &ProfileDocument, target: &ProfileDocument) -> Vec<DiffItem> {
    let mut items = Vec::new();
    let slots: BTreeSet<&String> = base.slots.keys().chain(target.slots.keys()).collect();
    for slot in slots {
        let (before, after) = (base.slots.get(slot), target.slots.get(slot));
        if before != after {
            items.push(item(
                format!("/slots/{slot}"),
                match (before, after) {
                    (None, Some(_)) => DiffKind::Added,
                    (Some(_), None) => DiffKind::Removed,
                    _ => DiffKind::Changed,
                },
                before.map(|value| json!(value)),
                after.map(|value| json!(value)),
                "diff.slot.changed",
                json!({"slot": slot, "from_package": package_of(base, before), "to_package": package_of(target, after)}),
            ));
        }
    }
    for entry in &target.entries {
        match base.entry(&entry.entry_id) {
            None => items.push(item(
                format!("/entries/{}", entry.entry_id),
                DiffKind::Added,
                None,
                Some(json!(entry.package)),
                "diff.entry.added",
                json!({"package": entry.package, "version": entry.version}),
            )),
            Some(old) => {
                if old.config != entry.config {
                    items.push(item(
                        format!("/entries/{}/config", entry.entry_id),
                        DiffKind::Changed,
                        Some(old.config.clone()),
                        Some(entry.config.clone()),
                        "diff.entry.config",
                        json!({"package": entry.package}),
                    ));
                }
                if old.disabled != entry.disabled {
                    items.push(item(
                        format!("/entries/{}/disabled", entry.entry_id),
                        DiffKind::Changed,
                        Some(json!(old.disabled)),
                        Some(json!(entry.disabled)),
                        if entry.disabled {
                            "diff.entry.disabled"
                        } else {
                            "diff.entry.enabled"
                        },
                        json!({"package": entry.package}),
                    ));
                }
                if old.version != entry.version {
                    items.push(item(
                        format!("/entries/{}/version", entry.entry_id),
                        DiffKind::Changed,
                        Some(json!(old.version)),
                        Some(json!(entry.version)),
                        "diff.entry.version",
                        json!({"package": entry.package}),
                    ));
                }
            }
        }
    }
    for entry in &base.entries {
        if target.entry(&entry.entry_id).is_none() {
            items.push(item(
                format!("/entries/{}", entry.entry_id),
                DiffKind::Removed,
                Some(json!(entry.package)),
                None,
                "diff.entry.removed",
                json!({"package": entry.package, "version": entry.version}),
            ));
        }
    }
    let (before, after) = (base.to_value(), target.to_value());
    for section in ["appearance", "avatar", "layout"] {
        diff_values(
            &format!("/{section}"),
            &before[section],
            &after[section],
            section,
            &mut items,
        );
    }
    if before["shortcuts"] != after["shortcuts"] {
        items.push(item(
            "/shortcuts".into(),
            DiffKind::Changed,
            Some(before["shortcuts"].clone()),
            Some(after["shortcuts"].clone()),
            "diff.shortcuts",
            json!({}),
        ));
    }
    items
}

fn diff_values(
    path: &str,
    before: &Value,
    after: &Value,
    section: &str,
    items: &mut Vec<DiffItem>,
) {
    if before == after {
        return;
    }
    match (before, after) {
        (Value::Object(old), Value::Object(new)) if path.matches('/').count() < 3 => {
            let keys: BTreeSet<&String> = old.keys().chain(new.keys()).collect();
            for key in keys {
                diff_values(
                    &format!("{path}/{key}"),
                    old.get(key.as_str()).unwrap_or(&Value::Null),
                    new.get(key.as_str()).unwrap_or(&Value::Null),
                    section,
                    items,
                );
            }
        }
        _ => {
            let field = path
                .trim_start_matches(&format!("/{section}"))
                .trim_start_matches('/');
            let (label, args) = match field.split_once('/') {
                Some(("tokens", token)) => {
                    ("diff.appearance.token".to_string(), json!({"token": token}))
                }
                _ => (
                    format!("diff.{section}.{}", field.replace('/', ".")),
                    json!({}),
                ),
            };
            items.push(item(
                path.into(),
                match (before, after) {
                    (Value::Null, _) => DiffKind::Added,
                    (_, Value::Null) => DiffKind::Removed,
                    _ => DiffKind::Changed,
                },
                (!before.is_null()).then(|| before.clone()),
                (!after.is_null()).then(|| after.clone()),
                &label,
                args,
            ));
        }
    }
}

/// The card kind: what a person would call this change.
pub fn card(ops: &[ChangeOp], items: Vec<DiffItem>) -> ChangeCard {
    let kind = if ops
        .iter()
        .any(|op| matches!(op, ChangeOp::SwitchProfile { .. }))
    {
        "profile_switch"
    } else if !ops.is_empty()
        && ops.iter().all(|op| {
            matches!(
                op,
                ChangeOp::BindSlot { .. } | ChangeOp::AddEntry { slot: Some(_), .. }
            )
        })
    {
        "provider_swap"
    } else if !ops.is_empty()
        && ops.iter().all(
            |op| matches!(op, ChangeOp::SetValue { path, .. } if path.starts_with("/appearance")),
        )
    {
        "appearance"
    } else if !ops.is_empty()
        && ops
            .iter()
            .all(|op| matches!(op, ChangeOp::SetValue { path, .. } if path.starts_with("/layout")))
    {
        "layout"
    } else if !ops.is_empty()
        && ops
            .iter()
            .all(|op| matches!(op, ChangeOp::SetEntryDisabled { .. }))
    {
        "plugin_state"
    } else {
        "mixed"
    };
    ChangeCard {
        kind: kind.into(),
        title_key: format!("change.title.{kind}"),
        title_args: [("count".to_string(), json!(items.len()))]
            .into_iter()
            .collect(),
        items,
        footnote_key: None,
    }
}

/// Ops that turn `current` into `target`, used by undo and timed revert when
/// the change being reverted is the newest one.
pub fn ops_between(current: &ProfileDocument, target: &ProfileDocument) -> Vec<ChangeOp> {
    let mut ops = Vec::new();
    let (now, then) = (current.to_value(), target.to_value());
    for root in WRITABLE_ROOTS {
        let key = &root[1..];
        if now[key] != then[key] {
            ops.push(ChangeOp::SetValue {
                path: root.to_string(),
                before: Some(now[key].clone()),
                after: then[key].clone(),
            });
        }
    }
    for entry in &current.entries {
        match target.entry(&entry.entry_id) {
            None => ops.push(ChangeOp::RemoveEntry {
                entry_id: entry.entry_id.clone(),
            }),
            Some(old) => {
                if old.config != entry.config {
                    ops.push(ChangeOp::SetEntryConfig {
                        entry_id: entry.entry_id.clone(),
                        before: Some(entry.config.clone()),
                        after: old.config.clone(),
                    });
                }
                if old.disabled != entry.disabled {
                    ops.push(ChangeOp::SetEntryDisabled {
                        entry_id: entry.entry_id.clone(),
                        disabled: old.disabled,
                    });
                }
            }
        }
    }
    ops
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use ditto_protocol::{change::NewEntry, profile::*};

    pub fn document() -> ProfileDocument {
        let dock_a = EntrySpec {
            entry_id: "ent-dock-a".into(),
            package: "ditto.dock.bottom".into(),
            version: "1.0.0".into(),
            host: HostKind::Qml,
            config: json!({}),
            disabled: false,
        };
        let dock_b = EntrySpec {
            entry_id: "ent-dock-b".into(),
            package: "ditto.dock.pill".into(),
            ..dock_a.clone()
        };
        ProfileDocument {
            schema_version: SCHEMA_VERSION,
            entries: vec![dock_a, dock_b],
            slots: [("ui.dock".to_string(), "ent-dock-a".to_string())]
                .into_iter()
                .collect(),
            layout: LayoutIntent {
                workspace_grid: [3, 3],
                rules: vec![],
            },
            appearance: Appearance {
                theme: "soft-jelly".into(),
                tokens: [("accent".to_string(), "#b9a4ff".to_string())]
                    .into_iter()
                    .collect(),
                reduced_motion: false,
                reduced_transparency: false,
                low_power_style: false,
                locale: "zh-TW".into(),
            },
            shortcuts: vec![],
            avatar: AvatarSettings {
                enabled: true,
                hidden: false,
                scale: 1.0,
                animations: true,
            },
        }
    }

    #[test]
    fn set_value_refills_before_and_reports_stale_intent() {
        let base = document();
        let applied = apply(
            &base,
            &[ChangeOp::SetValue {
                path: "/appearance/tokens/accent".into(),
                before: Some(json!("#000000")),
                after: json!("#9d7bff"),
            }],
        );
        assert_eq!(applied.document.appearance.tokens["accent"], "#9d7bff");
        assert_eq!(applied.reasons[0].code, PreflightCode::StaleIntent);
        let ChangeOp::SetValue { before, .. } = &applied.ops[0] else {
            panic!()
        };
        assert_eq!(before, &Some(json!("#b9a4ff")));
    }

    #[test]
    fn writes_outside_the_writable_roots_and_bad_types_are_schema_errors() {
        let base = document();
        let applied = apply(
            &base,
            &[
                ChangeOp::SetValue {
                    path: "/slots/ui.dock".into(),
                    before: None,
                    after: json!("x"),
                },
                ChangeOp::SetValue {
                    path: "/avatar/scale".into(),
                    before: None,
                    after: json!("big"),
                },
            ],
        );
        assert_eq!(applied.reasons.len(), 2);
        assert!(applied
            .reasons
            .iter()
            .all(|r| r.code == PreflightCode::SchemaInvalid));
        assert_eq!(applied.document, base, "a refused write changes nothing");
    }

    #[test]
    fn slot_swap_diff_names_both_packages() {
        let base = document();
        let applied = apply(
            &base,
            &[ChangeOp::BindSlot {
                slot: "ui.dock".into(),
                from: Some("ent-dock-a".into()),
                to: "ent-dock-b".into(),
            }],
        );
        assert!(applied.reasons.is_empty());
        let items = diff(&base, &applied.document);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].label_key, "diff.slot.changed");
        assert_eq!(items[0].label_args["to_package"], json!("ditto.dock.pill"));
        assert_eq!(card(&applied.ops, items).kind, "provider_swap");
    }

    #[test]
    fn add_entry_gets_a_core_id_and_binds_its_slot() {
        let base = document();
        let applied = apply(
            &base,
            &[ChangeOp::AddEntry {
                entry: NewEntry {
                    package: "ditto.launcher.search".into(),
                    version: "1.0.0".into(),
                    host: HostKind::Qml,
                    config: json!({}),
                    disabled: false,
                },
                slot: Some("ui.launcher".into()),
            }],
        );
        let bound = applied.document.slots["ui.launcher"].clone();
        assert!(ids::has_prefix(&bound, ids::ENTRY));
        assert_eq!(
            applied.document.entry(&bound).unwrap().package,
            "ditto.launcher.search"
        );
    }

    #[test]
    fn ops_between_restores_the_older_document() {
        let base = document();
        let applied = apply(
            &base,
            &[
                ChangeOp::SetValue {
                    path: "/appearance/tokens/accent".into(),
                    before: None,
                    after: json!("#123456"),
                },
                ChangeOp::SetEntryDisabled {
                    entry_id: "ent-dock-b".into(),
                    disabled: true,
                },
            ],
        );
        let back = apply(&applied.document, &ops_between(&applied.document, &base));
        assert!(back.reasons.is_empty());
        assert_eq!(back.document.digest(), base.digest());
    }
}
