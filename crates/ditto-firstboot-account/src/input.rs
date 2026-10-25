use crate::Code;
use serde::{Deserialize, Deserializer};
use serde_json::value::RawValue;
use std::sync::atomic::{compiler_fence, Ordering};
pub const MAX_REQUEST: usize = 4096;
// libxcrypt CRYPT_MAX_PASSPHRASE_SIZE includes the terminating NUL.
pub const MAX_PASSWORD: usize = 511;

pub(crate) fn wipe(bytes: &mut [u8]) {
    for b in bytes {
        // SAFETY: b points to a live, exclusively borrowed byte.
        unsafe { std::ptr::write_volatile(b, 0) };
    }
    compiler_fence(Ordering::SeqCst);
}
/// No Debug/Serialize/Clone: passwords must not enter diagnostics accidentally.
#[derive(Default)]
pub struct Secret(pub(crate) Vec<u8>);
impl Secret {
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
    pub fn as_str(&self) -> Result<&str, std::str::Utf8Error> {
        std::str::from_utf8(&self.0)
    }
    pub(crate) fn bounded(capacity: usize) -> Self {
        Self(Vec::with_capacity(capacity))
    }
    pub(crate) fn push(&mut self, byte: u8) {
        assert!(self.0.len() < self.0.capacity());
        self.0.push(byte);
    }
}
impl From<String> for Secret {
    fn from(s: String) -> Self {
        Self(s.into_bytes())
    }
}
impl From<&str> for Secret {
    fn from(s: &str) -> Self {
        Self(s.as_bytes().to_vec())
    }
}
impl Drop for Secret {
    fn drop(&mut self) {
        // Wipe the full allocation, including spare capacity and truncated bytes.
        for i in 0..self.0.capacity() {
            // SAFETY: every byte within Vec's allocation is writable; no reads.
            unsafe { std::ptr::write_volatile(self.0.as_mut_ptr().add(i), 0) };
        }
        compiler_fence(Ordering::SeqCst);
    }
}
pub struct Request {
    pub display_name: String,
    pub username: String,
    pub password: Secret,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireRequest<'a> {
    display_name: String,
    username: String,
    #[serde(borrow)]
    password: &'a RawValue,
}
impl<'de> Deserialize<'de> for Request {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let wire = WireRequest::deserialize(d)?;
        // RawValue validates JSON without copying the password into serde_json's
        // unzeroized escape scratch. Decode only that string into owned Secret.
        let password = decode_password(wire.password.get())
            .ok_or_else(|| serde::de::Error::custom("invalid password string"))?;
        Ok(Self {
            display_name: wire.display_name,
            username: wire.username,
            password,
        })
    }
}
fn decode_password(raw: &str) -> Option<Secret> {
    let bytes = raw.as_bytes();
    if bytes.first() != Some(&b'"') || bytes.last() != Some(&b'"') {
        return None;
    }
    let mut out = Secret::bounded(raw.len());
    let mut i = 1;
    while i < bytes.len() - 1 {
        let b = bytes[i];
        i += 1;
        if b != b'\\' {
            out.push(b);
            continue;
        }
        let escape = *bytes.get(i)?;
        i += 1;
        let decoded = match escape {
            b'"' | b'\\' | b'/' => escape,
            b'b' => 8,
            b'f' => 12,
            b'n' => b'\n',
            b'r' => b'\r',
            b't' => b'\t',
            b'u' => {
                let mut value = u32::from_str_radix(raw.get(i..i + 4)?, 16).ok()?;
                i += 4;
                if (0xd800..=0xdbff).contains(&value) {
                    if bytes.get(i..i + 2)? != b"\\u" {
                        return None;
                    }
                    i += 2;
                    let low = u32::from_str_radix(raw.get(i..i + 4)?, 16).ok()?;
                    i += 4;
                    if !(0xdc00..=0xdfff).contains(&low) {
                        return None;
                    }
                    value = 0x10000 + ((value - 0xd800) << 10) + low - 0xdc00;
                }
                let ch = char::from_u32(value)?;
                let mut encoded = [0; 4];
                for byte in ch.encode_utf8(&mut encoded).as_bytes() {
                    out.push(*byte);
                }
                wipe(&mut encoded);
                continue;
            }
            _ => return None,
        };
        out.push(decoded);
    }
    out.as_str().ok()?;
    Some(out)
}
pub(crate) fn valid_username(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 31
        && bytes[0].is_ascii_lowercase()
        && bytes
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
        && !RESERVED.contains(&name)
}
// System/service identities, including names not necessarily in a pristine image.
const RESERVED: &[&str] = &[
    "root",
    "daemon",
    "bin",
    "sys",
    "sync",
    "games",
    "man",
    "lp",
    "mail",
    "news",
    "uucp",
    "proxy",
    "www-data",
    "backup",
    "list",
    "irc",
    "gnats",
    "nobody",
    "nogroup",
    "sudo",
    "admin",
    "adm",
    "wheel",
    "shadow",
    "staff",
    "users",
    "audio",
    "video",
    "input",
    "render",
    "disk",
    "tty",
    "utmp",
    "plugdev",
    "netdev",
    "messagebus",
    "polkitd",
    "sshd",
    "systemd-network",
    "systemd-resolve",
    "systemd-timesync",
    "systemd-coredump",
    "greetd",
    "ditto",
    "firstboot",
];
pub fn validate(request: &Request) -> Result<bool, Code> {
    if !valid_username(&request.username) {
        return Err(Code::InvalidUsername);
    }
    if request.display_name.chars().count() > 128
        || request.display_name.len() > 512
        || request
            .display_name
            .chars()
            .any(|c| c.is_control() || matches!(c, ':' | ',' | '='))
    {
        return Err(Code::DisplayNameInvalid);
    }
    let password = request
        .password
        .as_str()
        .map_err(|_| Code::PasswordInvalid)?;
    if password.len() > MAX_PASSWORD || password.chars().any(|c| matches!(c, '\0' | '\n' | '\r')) {
        return Err(Code::PasswordInvalid);
    }
    if password.chars().count() < 8 {
        return Err(Code::PasswordTooShort);
    }
    // Warning only: short, single-class, or common exact examples.
    let classes = [
        password.chars().any(|c| c.is_lowercase()),
        password.chars().any(|c| c.is_uppercase()),
        password.chars().any(|c| c.is_numeric()),
        password.chars().any(|c| !c.is_alphanumeric()),
    ];
    // No lowercase copy of the password is allocated.
    let common = [
        "password",
        "password123",
        "12345678",
        "123456789",
        "qwerty123",
        "letmein123",
    ]
    .iter()
    .any(|s| password.eq_ignore_ascii_case(s));
    Ok(password.chars().count() < 12 || classes.iter().filter(|b| **b).count() < 2 || common)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn escaped_password_decoding_matches_json() {
        for original in [
            "12345678",
            "one\"two\\three/",
            "中文密碼🙂🙂🙂🙂",
            "\0\n\r\t\x08\x0c",
            "",
        ] {
            let encoded = serde_json::to_string(original).unwrap();
            assert_eq!(
                decode_password(&encoded).unwrap().as_str().unwrap(),
                original
            );
        }
        assert_eq!(
            decode_password(r#""\uD83D\uDE42\u4e2d""#)
                .unwrap()
                .as_str()
                .unwrap(),
            "🙂中"
        );
        for invalid in [
            "null",
            "[]",
            r#""\ud800""#,
            r#""\udc00""#,
            r#""\ud800\u0000""#,
        ] {
            assert!(decode_password(invalid).is_none());
        }
    }
}
