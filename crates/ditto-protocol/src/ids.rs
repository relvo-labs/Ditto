//! Identifiers Core generates. A ULID sorts by creation time, so a history
//! listed by id is also listed by time, and two ids made in the same
//! millisecond still sort in the order they were made.

use std::{
    fs::File,
    io::Read,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub const CHANGE: &str = "chg";
pub const REVISION: &str = "rev";
pub const PROFILE: &str = "prf";
pub const ENTRY: &str = "ent";
pub const OPERATION: &str = "op";
pub const GRANT: &str = "grant";
pub const SNAPSHOT: &str = "snap";
pub const JOB: &str = "job";
pub const LEASE: &str = "lease";

static LAST: Mutex<(u64, u128)> = Mutex::new((0, 0));

fn random_80() -> u128 {
    let mut bytes = [0_u8; 10];
    // /dev/urandom does not block after boot and never fails short on Linux;
    // a failure here means the system is unusable, not that ids may repeat.
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .expect("kernel random source unavailable");
    bytes
        .iter()
        .fold(0_u128, |value, byte| (value << 8) | u128::from(*byte))
}

fn millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

/// A 26-character ULID, monotonic within this process.
pub fn ulid() -> String {
    let mut last = LAST.lock().expect("ulid state");
    let now = millis().max(last.0);
    let random = if now == last.0 {
        (last.1 + 1) & ((1_u128 << 80) - 1)
    } else {
        random_80()
    };
    *last = (now, random);
    let value = (u128::from(now) << 80) | random;
    let mut text = [0_u8; 26];
    for (index, slot) in text.iter_mut().enumerate() {
        let shift = 125 - index * 5;
        *slot = CROCKFORD[((value >> shift) & 0x1f) as usize];
    }
    String::from_utf8(text.to_vec()).expect("crockford is ascii")
}

pub fn new(prefix: &str) -> String {
    format!("{prefix}-{}", ulid())
}

pub fn has_prefix(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix)
        .and_then(|rest| rest.strip_prefix('-'))
        .is_some_and(|rest| rest.len() == 26 && rest.bytes().all(|b| CROCKFORD.contains(&b)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_sort_in_creation_order_and_carry_their_prefix() {
        let ids: Vec<String> = (0..200).map(|_| new(CHANGE)).collect();
        let mut sorted = ids.clone();
        sorted.sort();
        assert_eq!(ids, sorted);
        assert!(ids.iter().all(|id| has_prefix(id, CHANGE)));
        assert!(!has_prefix(&ids[0], REVISION));
        let unique: std::collections::HashSet<_> = ids.iter().collect();
        assert_eq!(unique.len(), ids.len());
    }
}
