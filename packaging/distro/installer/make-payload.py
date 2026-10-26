#!/usr/bin/env python3
"""Builder only: cut the installer payload out of a finished, scanned Ditto disk."""

import argparse
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ditto_installer.payload import PayloadBuildError, extract  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disk", type=Path, required=True, help="out/ditto.raw after finish-image.sh")
    parser.add_argument("--disk-sha256", required=True, help="value recorded in out/disk.sha256")
    parser.add_argument("--image-version", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output", type=Path, required=True, help="fresh directory")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{64}", args.disk_sha256) or not re.fullmatch(r"[0-9a-f]{40}", args.source_commit):
        parser.error("invalid digest or commit")
    try:
        digest = extract(args.disk, args.output, expected_disk_sha256=args.disk_sha256,
                         image_version=args.image_version, source_commit=args.source_commit)
    except (PayloadBuildError, ValueError, OSError) as error:
        parser.error(str(error))
    print(digest)


if __name__ == "__main__":
    main()
