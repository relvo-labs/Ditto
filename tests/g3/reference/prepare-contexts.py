"""Copy actual binaries for serial reference-seat failure contexts.

Build release normally and the fault host in target/g3-fault-fixtures first.
This does not install anything, alter the original binaries, or forge reports.
"""
import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
base = pathlib.Path(sys.argv[1]).resolve()
base.mkdir(mode=0o700)  # Never overwrite evidence from a previous run.
for mode in ["faults", "partial", "unavailable"]:
    destination = base / mode
    destination.mkdir(mode=0o700)
    for name in ["ditto-core", "ditto-worker", "ditto-confine", "ditto-generation-host", "ditto-generation-runner", "ditto-generation-runner.json"]:
        if mode == "unavailable" and name.startswith("ditto-generation-runner"):
            continue
        source = ROOT / ("target/g3-fault-fixtures/debug/ditto-generation-host" if mode == "faults" and name == "ditto-generation-host" else "target/release/" + name)
        shutil.copy2(source, destination / name)
    if mode == "partial":
        empty = destination / "empty-qt"
        empty.mkdir()
        metadata = destination / "ditto-generation-runner.json"
        pin = json.loads(metadata.read_text())
        pin["qt_prefix"] = str(empty)
        metadata.write_text(json.dumps(pin) + "\n")
