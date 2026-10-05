//! RFC 8785 (JCS) canonical JSON. Profile documents are hashed, compared and
//! exported in this form, so two documents with the same content and a
//! different key order are the same revision content.

use serde_json::Value;
use sha2::{Digest, Sha256};

pub fn canonicalize(value: &Value) -> String {
    let mut out = String::new();
    write_value(value, &mut out);
    out
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// `sha256:<hex>` of the canonical form.
pub fn digest(value: &Value) -> String {
    format!("sha256:{}", sha256_hex(canonicalize(value).as_bytes()))
}

fn write_value(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => write_number(number, out),
        Value::String(text) => write_string(text, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_value(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            // JCS orders keys by UTF-16 code units, which differs from byte
            // order only outside the BMP-ASCII overlap; sort explicitly.
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
            out.push('{');
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write_value(&map[key], out);
            }
            out.push('}');
        }
    }
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", control as u32));
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

/// ECMAScript `Number.prototype.toString` for finite doubles, which is what
/// JCS requires. Integers stay integers; Rust's shortest round-trip digits
/// are the same digits ECMAScript chooses, only the exponent layout differs.
fn write_number(number: &serde_json::Number, out: &mut String) {
    if let Some(integer) = number.as_i64() {
        out.push_str(&integer.to_string());
        return;
    }
    if let Some(integer) = number.as_u64() {
        out.push_str(&integer.to_string());
        return;
    }
    let value = number.as_f64().unwrap_or(0.0);
    if value == 0.0 {
        out.push('0');
        return;
    }
    let magnitude = value.abs();
    if value.fract() == 0.0 && magnitude < 1e21 {
        out.push_str(&format!("{value:.0}"));
        return;
    }
    if (1e-6..1e21).contains(&magnitude) {
        out.push_str(&format!("{value}"));
        return;
    }
    let scientific = format!("{value:e}");
    let (mantissa, exponent) = scientific.split_once('e').expect("exponent form");
    let exponent: i32 = exponent.parse().expect("exponent digits");
    out.push_str(mantissa);
    out.push('e');
    if exponent >= 0 {
        out.push('+');
    }
    out.push_str(&exponent.to_string());
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn key_order_does_not_change_the_digest() {
        let a = json!({"b": 1, "a": {"y": [1, 2], "x": "é"}});
        let b: Value = serde_json::from_str(r#"{"a":{"x":"é","y":[1,2]},"b":1}"#).unwrap();
        assert_eq!(canonicalize(&a), r#"{"a":{"x":"é","y":[1,2]},"b":1}"#);
        assert_eq!(digest(&a), digest(&b));
    }

    #[test]
    fn numbers_follow_ecmascript_formatting() {
        let cases = [
            (json!(1.0), "1"),
            (json!(1.25), "1.25"),
            (json!(-0.5), "-0.5"),
            (json!(1e21), "1e+21"),
            (json!(1e-7), "1e-7"),
            (json!(1.5e-7), "1.5e-7"),
            (json!(123456789012_i64), "123456789012"),
            (json!(0.000001), "0.000001"),
        ];
        for (value, expected) in cases {
            assert_eq!(canonicalize(&value), expected, "{value}");
        }
    }

    #[test]
    fn strings_escape_only_what_jcs_requires() {
        assert_eq!(
            canonicalize(&json!("a\"b\\c\n\u{1}中")),
            "\"a\\\"b\\\\c\\n\\u0001中\""
        );
    }
}
