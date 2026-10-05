//! Timestamps are ISO 8601 with a time-zone designator (PRD §16). Core writes
//! UTC; the monotonic clock is stored separately for latency measurements.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub fn now() -> String {
    format_system(SystemTime::now())
}

pub fn format_system(time: SystemTime) -> String {
    let since = time.duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO);
    format_unix_millis(since.as_millis() as i64)
}

pub fn format_unix_millis(millis: i64) -> String {
    let seconds = millis.div_euclid(1000);
    let fraction = millis.rem_euclid(1000);
    let days = seconds.div_euclid(86_400);
    let of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{fraction:03}Z",
        of_day / 3600,
        (of_day % 3600) / 60,
        of_day % 60
    )
}

/// Parse what `format_unix_millis` writes (and whole seconds, and `+00:00`).
pub fn parse_unix_millis(text: &str) -> Option<i64> {
    let (date, rest) = text.split_once('T')?;
    let mut parts = date.split('-');
    let year: i64 = parts.next()?.parse().ok()?;
    let month: u32 = parts.next()?.parse().ok()?;
    let day: u32 = parts.next()?.parse().ok()?;
    let clock = rest
        .strip_suffix('Z')
        .or_else(|| rest.strip_suffix("+00:00"))?;
    let (hms, fraction) = match clock.split_once('.') {
        Some((hms, fraction)) => (hms, fraction),
        None => (clock, "0"),
    };
    let mut fields = hms.split(':');
    let hour: i64 = fields.next()?.parse().ok()?;
    let minute: i64 = fields.next()?.parse().ok()?;
    let second: i64 = fields.next()?.parse().ok()?;
    let millis: i64 = format!("{fraction:0<3}")[..3].parse().ok()?;
    let days = days_from_civil(year, month, day);
    Some(((days * 86_400 + hour * 3600 + minute * 60 + second) * 1000) + millis)
}

pub fn unix_millis_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

/// Monotonic nanoseconds (CLOCK_MONOTONIC); only differences are meaningful.
pub fn monotonic_ns() -> i64 {
    let mut spec = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: spec is a valid writable timespec.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut spec) };
    spec.tv_sec * 1_000_000_000 + spec.tv_nsec
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    // Howard Hinnant's algorithm.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let m = i64::from(month);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_and_parses_iso_8601_utc() {
        assert_eq!(format_unix_millis(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(
            format_unix_millis(1_790_000_000_123),
            "2026-09-21T14:13:20.123Z"
        );
        for millis in [0, 951_782_400_000, 1_790_000_000_123, 4_102_444_800_999] {
            assert_eq!(parse_unix_millis(&format_unix_millis(millis)), Some(millis));
        }
        assert_eq!(
            parse_unix_millis("2026-09-21T14:13:20+00:00"),
            Some(1_790_000_000_000)
        );
    }
}
