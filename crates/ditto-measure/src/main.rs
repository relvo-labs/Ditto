use std::{
    env, fs,
    io::{self, Write},
    path::PathBuf,
    thread,
    time::Duration,
};

use ditto_measure::{report, validate_manifest, Manifest, Sampler};

fn main() -> io::Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    if args.len() == 6 && args[0] == "report" {
        let conditions: report::Conditions = serde_json::from_slice(&fs::read(&args[1])?)?;
        let paths = [
            PathBuf::from(&args[2]),
            PathBuf::from(&args[3]),
            PathBuf::from(&args[4]),
        ];
        let content = report::generate(&conditions, &[&paths[0], &paths[1], &paths[2]])?;
        return fs::write(&args[5], content);
    }
    if args.len() != 5 || args[0] != "sample" {
        eprintln!(
            "usage: ditto-measure sample <manifest.json> <count> <interval-ms> <output.jsonl>\n       ditto-measure report <conditions.json> <run1.jsonl> <run2.jsonl> <run3.jsonl> <output.md>"
        );
        std::process::exit(2);
    }
    let manifest: Manifest = serde_json::from_slice(&fs::read(&args[1])?)?;
    validate_manifest(&manifest)?;
    let count: usize = args[2]
        .parse()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid sample count"))?;
    let interval_ms: u64 = args[3]
        .parse()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid interval"))?;
    if count == 0 || (count > 1 && interval_ms == 0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "count must be positive and repeated samples need an interval",
        ));
    }
    let output = PathBuf::from(&args[4]);
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut writer = io::BufWriter::new(fs::File::create(output)?);
    let mut sampler = Sampler::new()?;
    for index in 0..count {
        if index > 0 {
            thread::sleep(Duration::from_millis(interval_ms));
        }
        serde_json::to_writer(&mut writer, &sampler.sample(&manifest))?;
        writer.write_all(b"\n")?;
    }
    writer.flush()
}
