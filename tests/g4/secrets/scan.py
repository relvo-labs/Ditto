#!/usr/bin/env python3
"""Exact synthetic sentinel scan. No third-party modules, no network."""
import argparse
import base64
import json
from pathlib import Path
import sqlite3
import subprocess
import urllib.parse


def scan(roots, sentinels):
    result = {"scope": {}, "files": [], "file_count": 0, "hit_count": 0,
              "hits": [], "errors": [], "sqlite_databases": [], "archives": []}
    needles = []
    if not sentinels:
        result["errors"].append("no injection sentinels configured")
    for label, value in sentinels.items():
        if not isinstance(value, str) or not value:
            result["errors"].append(f"invalid sentinel: {label}")
            continue
        variants = set()
        for encoding, text in {"literal": value, "json": json.dumps(value)[1:-1],
                               "url": urllib.parse.quote(value, safe=""),
                               "base64": base64.b64encode(value.encode()).decode()}.items():
            if text not in variants:
                needles.append((label, encoding, text.encode()))
                variants.add(text)

    def inspect(data, source):
        for label, encoding, needle in needles:
            count = data.count(needle)
            if count:
                # Never echo the matched value or surrounding private content.
                result["hits"].append({"source": source, "sentinel": label,
                                       "encoding": encoding, "count": count})

    seen = set()
    for category, directory in roots.items():
        root = Path(directory).absolute()
        result["scope"][category] = {"path": str(root), "file_count": 0}
        if not root.exists():
            result["errors"].append(f"missing scope: {root}")
            continue
        for path in sorted(root.rglob("*")) if root.is_dir() else [root]:
            if path.is_symlink():
                result["errors"].append(f"unscanned symlink: {path}")
                continue
            if not path.is_file():
                continue  # Unix sockets/directories contain no persistent bytes.
            result["scope"][category]["file_count"] += 1
            if path in seen:
                continue
            seen.add(path)
            result["files"].append(str(path))
            try:
                data = path.read_bytes()
                inspect(data, str(path))  # Includes WAL, freelist and deleted pages.
                if data.startswith(b"SQLite format 3\0"):
                    # SQL values as well as bytes: SQLite UTF-16 text is not UTF-8.
                    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
                        for index, row in enumerate(db.iterdump()):
                            inspect(row.encode(), f"{path}#sql:{index}")
                    result["sqlite_databases"].append(str(path))
                if path.suffix == ".dittopkg":
                    # Scan decompressed members without extracting paths to disk.
                    members = subprocess.run(["tar", "--zstd", "-tf", str(path)],
                                             capture_output=True, check=True, timeout=30)
                    for member in members.stdout.decode().splitlines():
                        if not member.endswith("/"):
                            content = subprocess.run(["tar", "--zstd", "-xOf", str(path), "--", member],
                                                     capture_output=True, check=True, timeout=30)
                            inspect(content.stdout, f"{path}!{member}")
                    result["archives"].append(str(path))
            except (OSError, sqlite3.Error, subprocess.SubprocessError, UnicodeError) as error:
                result["errors"].append(f"{path}: {type(error).__name__}")
    result["file_count"] = len(result["files"])
    result["hit_count"] = len(result["hits"])
    result["ok"] = not result["hits"] and not result["errors"] and bool(seen)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="JSON: roots and sentinels")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    report = scan(manifest["roots"], manifest["sentinels"])
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("ok", "file_count", "hit_count", "errors")}))
    raise SystemExit(0 if report["ok"] else 1)
