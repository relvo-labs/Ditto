use ditto_generation::{Description, MAX_DESCRIPTION_BYTES};
use std::io::{self, Read};

fn main() {
    if std::env::args().skip(1).collect::<Vec<_>>() != ["inspect"] {
        eprintln!("usage: ditto-generation inspect < description.json");
        std::process::exit(64);
    }
    let mut bytes = Vec::new();
    let result = io::stdin()
        .take(MAX_DESCRIPTION_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())
        .and_then(|_| Description::parse(&bytes))
        .and_then(|description| description.inspect())
        .and_then(|inspection| {
            serde_json::to_string_pretty(&inspection).map_err(|e| e.to_string())
        });
    match result {
        Ok(json) => println!("{json}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
