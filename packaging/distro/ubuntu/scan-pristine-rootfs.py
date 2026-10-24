#!/usr/bin/env python3
"""Scan a mounted pristine image; emit paths/fingerprints, never file contents."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--forbid", action="append", default=[])
    args = parser.parse_args()
    if any(not term for term in args.forbid):
        parser.error("--forbid must not be empty")
    root = args.root.resolve(strict=True)
    if not root.is_dir():
        parser.error("root must be a mounted image directory")
    approved = set(json.loads((Path(__file__).parent / "public-selftest-key-sha256.json").read_text()))
    # Broad classes also reject other developer home/workspace paths.
    terms = [b"/home/", b"/data/"] + [s.encode() for s in args.forbid]
    private = re.compile(rb"-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----\r?\n"
                         rb"(?:[A-Za-z0-9+/=]+\r?\n){2,}-----END \1-----")
    report = {"regular_files": 0, "bytes_scanned": 0, "literal_matches": [],
              "unapproved_keys": [], "public_fixtures": [], "identity_files": [], "errors": []}
    for required in ("usr/lib/os-release", "etc/shadow"):
        if not (root / required).is_file():
            report["errors"].append({"file": required, "error": "required pristine root file missing"})

    def walk_error(error):
        report["errors"].append({"file": str(error.filename), "errno": error.errno})

    for directory, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        dirs[:] = [n for n in dirs if not (Path(directory) / n).is_symlink()]
        for name in files:
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            try:
                if path.is_symlink():
                    if any(term in os.fsencode(path.readlink()) for term in terms):
                        report["literal_matches"].append(rel)
                    continue
                if not stat.S_ISREG(path.lstat().st_mode):
                    continue
                data = path.read_bytes()
                report["regular_files"] += 1
                report["bytes_scanned"] += len(data)
                # Broad home/data strings appear legitimately in distro code.
                # Reject explicit --forbid literals everywhere; apply broad
                # developer-path detection to configuration and provenance.
                forbidden = [s.encode() for s in args.forbid]
                if rel.startswith(("etc/", "usr/share/ditto/")):
                    forbidden += terms[:2]
                if any(term in data for term in forbidden):
                    report["literal_matches"].append(rel)
                hashes = {hashlib.sha256(m.group()).hexdigest() for m in private.finditer(data)}
                if hashes:
                    if rel == "usr/lib/x86_64-linux-gnu/libgnutls.so.30.41.1" and hashes <= approved:
                        report["public_fixtures"].append({"file": rel, "sha256": sorted(hashes)})
                    else:
                        report["unapproved_keys"].append(rel)
                if (name in {"authorized_keys", "known_hosts"} or
                        (rel.startswith("etc/ssh/ssh_host_") and "key" in name) or
                        (rel == "etc/machine-id" and data.strip()) or
                        rel == "var/lib/systemd/random-seed"):
                    report["identity_files"].append(rel)
                if rel == "etc/shadow" and any(
                    line.split(b":")[1].strip(b"!*") for line in data.splitlines() if b":" in line
                ):
                    report["identity_files"].append(rel)
            except OSError as error:
                report["errors"].append({"file": rel, "errno": error.errno})
    print(json.dumps(report, indent=2))
    return int(any(report[key] for key in
                   ("literal_matches", "unapproved_keys", "identity_files", "errors")))


if __name__ == "__main__":
    raise SystemExit(main())
