#!/usr/bin/env python3
"""Hash an already audited runtime tree; this does not authenticate its origin."""

import argparse
import hashlib
import json
from pathlib import Path
import stat


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-tree", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--snapshot", default="20261020T000000Z")
    args = parser.parse_args()
    if not args.runtime_tree.is_dir():
        parser.error("runtime tree must exist")
    files, links = {}, {}
    for path in sorted(args.runtime_tree.rglob("*")):
        name = path.relative_to(args.runtime_tree).as_posix()
        if path.is_symlink():
            links[name] = path.readlink().as_posix()
        elif stat.S_ISREG(path.lstat().st_mode):
            with path.open("rb") as stream:
                files[name] = hashlib.file_digest(stream, "sha256").hexdigest()
        elif not path.is_dir():
            parser.error(f"unsupported runtime object: {name}")
    print(json.dumps({"source_commit": args.source_commit, "source_sha256": args.source_sha256,
                      "snapshot": args.snapshot, "qt": "6.10.2", "node": "22.23.2", "rust": "1.98.1",
                      "quickshell_revision": "1a4716cde794a59928d9d9fc15f2afc7a95de360",
                      "wayfire_revision": "d39902379c5737eebe1dc3a830659fa3f0fa22e0",
                      "files": files, "symlinks": links}, indent=2))


if __name__ == "__main__":
    main()
