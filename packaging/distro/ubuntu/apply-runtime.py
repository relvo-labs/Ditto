#!/usr/bin/env python3
"""Preflight all target ownership before copying any locked runtime payload."""

import argparse
import json
from pathlib import Path
import shutil
import stat
import subprocess
from runtime_policy import check_target_ownership, confined_path, validate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--runtime-lock", type=Path, required=True)
    parser.add_argument("--runtime-tree", type=Path)
    args = parser.parse_args()
    try:
        lock = json.loads(args.runtime_lock.read_text())
        names = validate(lock, args.runtime_tree if args.runtime_tree else args.root)
        check_target_ownership(args.root, names)
        if args.runtime_tree:
            for name in lock["files"]:
                dest = confined_path(args.root, name)
                if dest.is_symlink():
                    raise ValueError(f"existing target symlink: {name}")
                try:
                    existing = dest.lstat()
                except FileNotFoundError:
                    continue
                if not stat.S_ISREG(existing.st_mode):
                    raise ValueError(f"existing target non-regular file: {name}")
                if existing.st_nlink > 1:
                    raise ValueError(f"existing target hardlink: {name}")
            for name in lock.get("symlinks", {}):
                dest = confined_path(args.root, name)
                if dest.exists() or dest.is_symlink():
                    raise ValueError(f"existing target runtime link: {name}")
            for name in names:
                dest = args.root / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                if name in lock["files"]:
                    shutil.copy2(args.runtime_tree / name, dest)
                else:
                    dest.symlink_to(lock["symlinks"][name])
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
