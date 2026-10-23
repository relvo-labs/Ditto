//! An entry's `config` checked against its manifest `config_schema` (#161).
//!
//! The SDK decides what a `config_schema` may contain
//! (`packages/host-sdk/src/manifest/json-schema.ts`: `configSchemaKeywords`,
//! `configSchemaIssues`) and how a value is judged (`validateJsonSchema`).
//! This module mirrors both for that subset, so a config the SDK accepts at
//! author time is the config Core accepts at preflight, and the other way
//! round. `tests/config-schema/parity.json` holds cases both sides run.
//!
//! - Allowed keywords: `type`, `properties`, `required`, `enum`, `items`,
//!   `minimum`, `maximum`, `additionalProperties`, plus the annotations
//!   `default`, `title`, `description` and `$schema`, which judge nothing.
//! - The top level is an object schema with `"type": "object"`.
//! - Any other keyword makes the schema unsupported, and so does a keyword
//!   value that cannot be judged: `properties` that is not an object,
//!   `required` that is not a list of strings, or a subschema (a property,
//!   `items`, `additionalProperties`) that is neither an object nor a
//!   boolean. `supported` is the one check for this: `Manifest::check` runs
//!   it when a package is installed or seeded, the SDK runs the same rule
//!   when it validates a manifest, and preflight refuses to judge a config
//!   by a schema that fails it (a package stored before the install check).
//! - A malformed value the SDK quietly ignores is ignored here too:
//!   `minimum`/`maximum` that is not a number, `enum` that is not an array,
//!   `properties` or `required` that is `null`.
//! - Property names are own keys on both sides: `toString`, `constructor`
//!   and `__proto__` are ordinary names.
//!
//! Pointers are RFC 6901 (`/a~1b` for the key `a/b`, `""` for the whole
//! config); the SDK writes the same paths without escaping and uses `/` for
//! the whole value.

use serde_json::{Map, Value};

/// Keywords a `config_schema` may use (SDK `configSchemaKeywords`).
pub const KEYWORDS: &[&str] = &[
    "type",
    "properties",
    "required",
    "enum",
    "items",
    "default",
    "minimum",
    "maximum",
    "additionalProperties",
    "title",
    "description",
    "$schema",
];

/// One place where the config does not match the schema.
#[derive(Clone, Debug, PartialEq)]
pub struct Violation {
    /// RFC 6901 pointer into the config.
    pub pointer: String,
    /// The schema keyword that refused the value.
    pub keyword: &'static str,
    /// The SDK's wording, for diagnostics only.
    pub message: String,
}

/// The schema itself is outside the subset; no config is judged by it.
#[derive(Clone, Debug, PartialEq)]
pub struct Unsupported {
    /// RFC 6901 pointer into the `config_schema`.
    pub schema_pointer: String,
    pub message: String,
}

/// Check `schema` is inside the subset, then judge `config` by it. Every
/// violation is returned, in a fixed order (see `validate`).
pub fn check(schema: &Value, config: &Value) -> Result<Vec<Violation>, Unsupported> {
    supported(schema)?;
    Ok(validate(schema, config))
}

fn escape(key: &str) -> String {
    key.replace('~', "~0").replace('/', "~1")
}

fn unsupported(schema_pointer: String, message: impl Into<String>) -> Unsupported {
    Unsupported {
        schema_pointer,
        message: message.into(),
    }
}

/// Is `schema` a `config_schema` the SDK accepts and Core can evaluate?
pub fn supported(schema: &Value) -> Result<(), Unsupported> {
    let Some(top) = schema.as_object() else {
        return Err(unsupported(
            String::new(),
            "config_schema must be a JSON Schema object",
        ));
    };
    if top.get("type") != Some(&Value::String("object".into())) {
        return Err(unsupported(
            "/type".into(),
            "the top level must be an object schema",
        ));
    }
    supported_node(schema, "")
}

fn supported_node(node: &Value, at: &str) -> Result<(), Unsupported> {
    let object = match node {
        Value::Bool(_) => return Ok(()),
        Value::Object(object) => object,
        _ => {
            return Err(unsupported(
                at.into(),
                "a subschema must be an object or a boolean",
            ))
        }
    };
    for (key, value) in object {
        let here = format!("{at}/{}", escape(key));
        if !KEYWORDS.contains(&key.as_str()) {
            return Err(unsupported(
                here,
                format!("keyword \"{key}\" is outside the config_schema subset"),
            ));
        }
        match key.as_str() {
            "properties" => match value {
                Value::Null => {}
                Value::Object(properties) => {
                    for (name, sub) in properties {
                        supported_node(sub, &format!("{here}/{}", escape(name)))?;
                    }
                }
                _ => return Err(unsupported(here, "properties must be an object")),
            },
            "required" => match value {
                Value::Null => {}
                Value::Array(names) if names.iter().all(Value::is_string) => {}
                _ => {
                    return Err(unsupported(
                        here,
                        "required must be a list of property names",
                    ))
                }
            },
            "items" | "additionalProperties" => supported_node(value, &here)?,
            _ => {}
        }
    }
    Ok(())
}

/// The SDK's `typeOf`: a number without a fractional part is an integer.
fn type_of(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(number) => {
            if number.is_i64()
                || number.is_u64()
                || number
                    .as_f64()
                    .is_some_and(|n| n.is_finite() && n.fract() == 0.0)
            {
                "integer"
            } else {
                "number"
            }
        }
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn matches_type(value: &Value, wanted: &Value) -> bool {
    let actual = type_of(value);
    wanted
        .as_str()
        .is_some_and(|wanted| wanted == actual || (wanted == "number" && actual == "integer"))
}

/// The SDK's `equal`: JSON equality where numbers compare by value.
fn equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(a, b)| equal(a, b))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(key, a)| y.get(key).is_some_and(|b| equal(a, b)))
        }
        _ => a == b,
    }
}

/// `JSON.stringify` for the values a schema holds.
fn show(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

fn label(type_name: &Value) -> String {
    match type_name {
        Value::String(text) => text.clone(),
        other => show(other),
    }
}

/// Judge `value` by a schema that `supported` accepted. Order follows the
/// SDK: `type` (and nothing else at that place when it fails), `enum`,
/// `minimum`, `maximum`, array items, then for an object its `required`
/// names followed by its properties in key order.
pub fn validate(schema: &Value, value: &Value) -> Vec<Violation> {
    let mut found = Vec::new();
    node(schema, value, "", "type", &mut found);
    found
}

fn node(schema: &Value, value: &Value, at: &str, via: &'static str, found: &mut Vec<Violation>) {
    let object = match schema {
        Value::Bool(true) => return,
        Value::Bool(false) => {
            found.push(Violation {
                pointer: at.into(),
                keyword: via,
                message: "no value is allowed here".into(),
            });
            return;
        }
        Value::Object(object) => object,
        // `supported` refuses every other shape.
        _ => return,
    };
    if let Some(wanted) = object.get("type") {
        let types: Vec<&Value> = match wanted {
            Value::Array(items) => items.iter().collect(),
            single => vec![single],
        };
        if !types.iter().any(|wanted| matches_type(value, wanted)) {
            let names: Vec<String> = types.iter().map(|t| label(t)).collect();
            found.push(Violation {
                pointer: at.into(),
                keyword: "type",
                message: format!("expected {}, got {}", names.join(" | "), type_of(value)),
            });
            return;
        }
    }
    if let Some(Value::Array(choices)) = object.get("enum") {
        if !choices.iter().any(|choice| equal(choice, value)) {
            let listed: Vec<String> = choices.iter().map(show).collect();
            found.push(Violation {
                pointer: at.into(),
                keyword: "enum",
                message: format!("must be one of {}", listed.join(", ")),
            });
        }
    }
    if let Some(number) = value.as_f64() {
        if let Some(minimum) = object.get("minimum").and_then(Value::as_f64) {
            if number < minimum {
                found.push(Violation {
                    pointer: at.into(),
                    keyword: "minimum",
                    message: format!("must be ≥ {}", show(&object["minimum"])),
                });
            }
        }
        if let Some(maximum) = object.get("maximum").and_then(Value::as_f64) {
            if number > maximum {
                found.push(Violation {
                    pointer: at.into(),
                    keyword: "maximum",
                    message: format!("must be ≤ {}", show(&object["maximum"])),
                });
            }
        }
    }
    if let (Value::Array(items), Some(item_schema)) = (value, object.get("items")) {
        for (index, item) in items.iter().enumerate() {
            node(item_schema, item, &format!("{at}/{index}"), "items", found);
        }
    }
    if let Value::Object(fields) = value {
        object_keywords(object, fields, at, found);
    }
}

fn object_keywords(
    schema: &Map<String, Value>,
    fields: &Map<String, Value>,
    at: &str,
    found: &mut Vec<Violation>,
) {
    if let Some(Value::Array(names)) = schema.get("required") {
        for name in names.iter().filter_map(Value::as_str) {
            if !fields.contains_key(name) {
                found.push(Violation {
                    pointer: format!("{at}/{}", escape(name)),
                    keyword: "required",
                    message: "is required".into(),
                });
            }
        }
    }
    let properties = schema.get("properties").and_then(Value::as_object);
    let additional = schema.get("additionalProperties");
    for (key, item) in fields {
        let here = format!("{at}/{}", escape(key));
        match (properties.and_then(|p| p.get(key)), additional) {
            (Some(sub), _) => node(sub, item, &here, "properties", found),
            (None, Some(sub)) => node(sub, item, &here, "additionalProperties", found),
            (None, None) => {}
        }
    }
}

/// The config a manifest implies when nothing was chosen: each top-level
/// property's `default`, as the SDK collects them to check them.
pub fn defaults(schema: &Value) -> Value {
    let mut config = Map::new();
    if let Some(properties) = schema.get("properties").and_then(Value::as_object) {
        for (key, sub) in properties {
            if let Some(default) = sub.get("default") {
                config.insert(key.clone(), default.clone());
            }
        }
    }
    Value::Object(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn issues(schema: Value, value: Value) -> Vec<(String, &'static str)> {
        check(&schema, &value)
            .expect("supported")
            .into_iter()
            .map(|v| (v.pointer, v.keyword))
            .collect()
    }

    fn refused(schema: Value) -> String {
        check(&schema, &json!({})).unwrap_err().schema_pointer
    }

    #[test]
    fn type_names_follow_the_sdk() {
        let schema = |t: Value| json!({"type": "object", "properties": {"v": {"type": t}}});
        for (t, value, ok) in [
            (json!("integer"), json!(3), true),
            (json!("integer"), json!(3.0), true),
            (json!("integer"), json!(3.5), false),
            (json!("number"), json!(3), true),
            (json!("number"), json!(3.5), true),
            (json!("string"), json!(3), false),
            (json!("boolean"), json!(false), true),
            (json!("null"), json!(null), true),
            (json!("array"), json!([]), true),
            (json!("object"), json!({}), true),
            (json!("object"), json!([]), false),
            (json!(["string", "null"]), json!(null), true),
            (json!(["string", "null"]), json!(1), false),
            (json!([]), json!(1), false),
            (json!("nonsense"), json!(1), false),
        ] {
            let found = issues(schema(t.clone()), json!({ "v": value }));
            assert_eq!(found.is_empty(), ok, "{t} {value}: {found:?}");
        }
    }

    #[test]
    fn a_type_mismatch_hides_the_other_keywords_at_that_place() {
        let schema = json!({"type": "object", "properties": {
            "v": {"type": "integer", "enum": [1], "minimum": 5}}});
        assert_eq!(
            issues(schema.clone(), json!({"v": "x"})),
            [("/v".to_string(), "type")]
        );
        assert_eq!(
            issues(schema, json!({"v": 2})),
            [("/v".to_string(), "enum"), ("/v".to_string(), "minimum")]
        );
    }

    #[test]
    fn enum_compares_json_values_and_numbers_by_value() {
        let schema =
            json!({"type": "object", "properties": {"v": {"enum": [1, "a", [1, {"b": null}]]}}});
        for (value, ok) in [
            (json!(1), true),
            (json!(1.0), true),
            (json!("a"), true),
            (json!([1, {"b": null}]), true),
            (json!([1, {"b": 0}]), false),
            (json!("1"), false),
        ] {
            assert_eq!(
                issues(schema.clone(), json!({ "v": value })).is_empty(),
                ok,
                "{value}"
            );
        }
    }

    #[test]
    fn bounds_apply_to_numbers_only() {
        let schema = json!({"type": "object", "properties": {"v": {"minimum": 1, "maximum": 2.5}}});
        assert!(issues(schema.clone(), json!({"v": 1})).is_empty());
        assert!(issues(schema.clone(), json!({"v": 2.5})).is_empty());
        assert_eq!(
            issues(schema.clone(), json!({"v": 0.5})),
            [("/v".to_string(), "minimum")]
        );
        assert_eq!(
            issues(schema.clone(), json!({"v": 3})),
            [("/v".to_string(), "maximum")]
        );
        assert!(issues(schema, json!({"v": "a string"})).is_empty());
    }

    #[test]
    fn items_required_and_additional_properties() {
        let schema = json!({
            "type": "object",
            "required": ["a", "x/y"],
            "properties": {
                "a": {"type": "array", "items": {"type": "object", "required": ["id"],
                       "properties": {"id": {"type": "string"}}, "additionalProperties": false}}
            },
            "additionalProperties": {"type": "integer"}
        });
        assert_eq!(
            issues(
                schema.clone(),
                json!({"a": [{"id": "1"}, {"id": 2, "extra": 1}, {}], "n": 1, "m~": "x"})
            ),
            [
                ("/x~1y".to_string(), "required"),
                ("/a/1/extra".to_string(), "additionalProperties"),
                ("/a/1/id".to_string(), "type"),
                ("/a/2/id".to_string(), "required"),
                ("/m~0".to_string(), "type"),
            ]
        );
        assert!(issues(schema, json!({"a": [], "x/y": 3})).is_empty());
    }

    #[test]
    fn boolean_subschemas() {
        let schema = json!({"type": "object", "properties": {"never": false, "any": true},
                            "additionalProperties": false});
        assert_eq!(
            issues(schema, json!({"never": 1, "any": [1], "other": 2})),
            [
                ("/never".to_string(), "properties"),
                ("/other".to_string(), "additionalProperties"),
            ]
        );
    }

    #[test]
    fn annotations_judge_nothing_and_malformed_values_the_sdk_ignores_are_ignored() {
        let schema = json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "t", "description": "d", "type": "object",
            "required": null,
            "properties": {"v": {"default": 1, "minimum": "5", "maximum": null, "enum": "x"}}
        });
        assert!(issues(schema, json!({"v": 0})).is_empty());
        assert!(issues(
            json!({"type": "object", "properties": null}),
            json!({"v": 0})
        )
        .is_empty());
    }

    #[test]
    fn schemas_outside_the_subset_are_refused_with_a_pointer() {
        assert_eq!(refused(json!(true)), "");
        assert_eq!(refused(json!({"properties": {}})), "/type");
        assert_eq!(refused(json!({"type": ["object"]})), "/type");
        assert_eq!(
            refused(json!({"type": "object", "pattern": "x"})),
            "/pattern"
        );
        assert_eq!(
            refused(json!({"type": "object", "properties": {"a/b": {"const": 1}}})),
            "/properties/a~1b/const"
        );
        assert_eq!(
            refused(json!({"type": "object", "properties": {"a": {"items": {"minLength": 1}}}})),
            "/properties/a/items/minLength"
        );
        assert_eq!(
            refused(json!({"type": "object", "additionalProperties": {"$ref": "#"}})),
            "/additionalProperties/$ref"
        );
        assert_eq!(
            refused(json!({"type": "object", "x-widget": "slider"})),
            "/x-widget"
        );
        assert_eq!(
            refused(json!({"type": "object", "properties": []})),
            "/properties"
        );
        assert_eq!(
            refused(json!({"type": "object", "required": "a"})),
            "/required"
        );
        assert_eq!(
            refused(json!({"type": "object", "required": [1]})),
            "/required"
        );
        assert_eq!(refused(json!({"type": "object", "items": null})), "/items");
        assert_eq!(
            refused(json!({"type": "object", "items": [{"type": "string"}]})),
            "/items"
        );
        assert_eq!(
            refused(json!({"type": "object", "properties": {"a": 3}})),
            "/properties/a"
        );
    }

    #[test]
    fn messages_keep_the_sdk_wording() {
        let schema = json!({"type": "object", "required": ["r"], "properties": {
            "t": {"type": "string"}, "e": {"enum": ["a", 1]},
            "lo": {"minimum": 2}, "hi": {"maximum": 2}}, "additionalProperties": false});
        let found = check(
            &schema,
            &json!({"t": 1, "e": "b", "lo": 1, "hi": 3, "x": 0}),
        )
        .unwrap();
        let messages: Vec<&str> = found.iter().map(|v| v.message.as_str()).collect();
        assert_eq!(
            messages,
            [
                "is required",
                "must be one of \"a\", 1",
                "must be ≤ 2",
                "must be ≥ 2",
                "expected string, got integer",
                "no value is allowed here",
            ]
        );
    }

    /// The Rust half of tests/config-schema/parity.json; the SDK half is
    /// packages/host-sdk/tests/config-schema-parity.test.ts.
    #[test]
    fn shared_parity_cases_match_the_sdk() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/config-schema/parity.json");
        let parity: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let cases = parity["cases"].as_array().unwrap();
        assert!(cases.len() > 15);
        for case in cases {
            let name = case["name"].as_str().unwrap();
            match check(&case["schema"], &case["value"]) {
                Ok(found) => {
                    let pointers: Vec<&str> = found.iter().map(|v| v.pointer.as_str()).collect();
                    let wanted: Vec<&str> = case["violations"]
                        .as_array()
                        .unwrap_or_else(|| {
                            panic!(
                                "{name}: supported, but the case expects {}",
                                case["unsupported"]
                            )
                        })
                        .iter()
                        .map(|p| p.as_str().unwrap())
                        .collect();
                    assert_eq!(pointers, wanted, "{name}");
                }
                Err(refused) => assert_eq!(
                    Some(refused.schema_pointer.as_str()),
                    case["unsupported"].as_str(),
                    "{name}"
                ),
            }
        }
    }

    #[test]
    fn defaults_collect_top_level_property_defaults() {
        let schema = json!({"type": "object", "properties": {
            "a": {"type": "integer", "default": 3}, "b": {"type": "string"},
            "c": {"type": "object", "properties": {"d": {"default": true}}}}});
        assert_eq!(defaults(&schema), json!({"a": 3}));
        assert_eq!(defaults(&json!({"type": "object"})), json!({}));
    }
}
