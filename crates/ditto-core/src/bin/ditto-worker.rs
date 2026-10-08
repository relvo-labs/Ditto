//! `ditto-worker <kind>`: one trusted background job, started by Core's job
//! pool in its own systemd scope (G2-CORE-05). Parameters arrive as one JSON
//! document on stdin; progress and the result leave as JSON lines on stdout:
//! `{"phase": "...", "progress": 0.5}` … then `{"result": {...}}` or
//! `{"error": "job.<key>"}`. The kinds are compiled in: there is no way to
//! name an executable, arguments or code.
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    path::PathBuf,
    time::{Duration, Instant},
};

fn emit(value: Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn fail(key: &str) -> ! {
    emit(json!({"error": key}));
    std::process::exit(1);
}

/// Re-hash installed package trees and compare with what was recorded at
/// installation (the same digest preflight uses).
fn verify_packages(params: &Value) -> Value {
    let packages = params["packages"].as_array().cloned().unwrap_or_default();
    let total = packages.len().max(1);
    let mut mismatched = Vec::new();
    let mut missing = Vec::new();
    for (index, package) in packages.iter().enumerate() {
        let id = package["package_id"].as_str().unwrap_or_default();
        let version = package["version"].as_str().unwrap_or_default();
        emit(
            json!({"phase": format!("hashing {}/{}", index + 1, packages.len()), "progress": index as f64 / total as f64}),
        );
        let dir = PathBuf::from(package["dir"].as_str().unwrap_or_default());
        match ditto_store::packages::tree_digest(&dir) {
            Ok(digest) if Some(digest.as_str()) == package["tree_sha256"].as_str() => {}
            Ok(_) => mismatched.push(json!({"package_id": id, "version": version})),
            Err(_) => missing.push(json!({"package_id": id, "version": version})),
        }
    }
    json!({"checked": packages.len(), "mismatched": mismatched, "missing": missing})
}

/// Fixture kinds, enabled by Core only in test runs: a CPU loop, a memory
/// hog (to show the scope's limit is real) and an idle wait (for cancels).
fn spin(params: &Value) -> Value {
    let ms = params["ms"].as_u64().unwrap_or(1_000).min(120_000);
    let started = Instant::now();
    let mut x: u64 = 1;
    let mut last = Instant::now();
    while started.elapsed() < Duration::from_millis(ms) {
        for _ in 0..100_000 {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1);
        }
        if last.elapsed() > Duration::from_millis(250) {
            last = Instant::now();
            emit(
                json!({"phase": "spinning", "progress": started.elapsed().as_millis() as f64 / ms as f64}),
            );
        }
    }
    json!({"spun_ms": ms, "checksum": x % 1000})
}

fn memory(params: &Value) -> Value {
    let mb = params["mb"].as_u64().unwrap_or(64).min(4096) as usize;
    let mut blocks: Vec<Vec<u8>> = Vec::new();
    for i in 0..mb {
        let mut block = vec![0u8; 1 << 20];
        // Touch every page so the memory is really used.
        for page in block.chunks_mut(4096) {
            page[0] = i as u8;
        }
        blocks.push(block);
        if i % 64 == 0 {
            emit(json!({"phase": format!("allocated {i} MiB"), "progress": i as f64 / mb as f64}));
        }
    }
    std::thread::sleep(Duration::from_millis(500));
    json!({"held_mb": blocks.len()})
}

fn sleep(params: &Value) -> Value {
    let ms = params["ms"].as_u64().unwrap_or(1_000).min(120_000);
    emit(json!({"phase": "waiting", "progress": 0.0}));
    std::thread::sleep(Duration::from_millis(ms));
    json!({"slept_ms": ms})
}

fn main() {
    let kind = std::env::args().nth(1).unwrap_or_default();
    let mut input = String::new();
    if std::io::stdin()
        .take(1 << 20)
        .read_to_string(&mut input)
        .is_err()
    {
        fail("job.invalid_params");
    }
    let params: Value = serde_json::from_str(if input.trim().is_empty() {
        "null"
    } else {
        &input
    })
    .unwrap_or_else(|_| fail("job.invalid_params"));
    let result = match kind.as_str() {
        "packages.verify" => verify_packages(&params),
        "test.spin" => spin(&params),
        "test.memory" => memory(&params),
        "test.sleep" => sleep(&params),
        _ => fail("job.unknown_kind"),
    };
    emit(json!({"result": result}));
}
