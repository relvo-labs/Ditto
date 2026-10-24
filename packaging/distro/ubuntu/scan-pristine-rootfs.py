#!/usr/bin/env python3
"""Scan a mounted pristine image; emit paths/fingerprints, never file contents."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tomllib
import shlex

def account_records(data, shadow):
    """Parse pristine account metadata without ever returning credential values."""
    try:
        text = data.decode("utf-8")
        lines = text.removesuffix("\n").split("\n")
        accounts = set()
        for line in lines:
            fields = line.split(":")
            if (len(fields) != (9 if shadow else 7) or
                    any(ord(char) < 32 or ord(char) == 127 for char in line) or
                    not re.fullmatch(r"[a-z_][a-z0-9_-]*[$]?", fields[0]) or fields[0] in accounts):
                return None
            locked = re.fullmatch(r"[!*]+", fields[1]) is not None
            if shadow:
                if (not locked or any(value and not re.fullmatch(r"[0-9]+", value)
                                      for value in fields[2:8]) or fields[8]):
                    return None
            elif ((fields[1] != "x" and not locked) or
                  any(not re.fullmatch(r"[0-9]+", value) for value in fields[2:4])):
                return None
            accounts.add(fields[0])
        return accounts if "root" in accounts else None
    except UnicodeError:
        return None


def check_accounts(root, report):
    accounts = {}
    for rel in ("etc/passwd", "etc/shadow"):
        path = root / rel
        try:
            if (any(parent.is_symlink() for parent in (path, path.parent)) or
                    not stat.S_ISREG(path.lstat().st_mode)):
                raise ValueError("unsafe account file")
            records = account_records(path.read_bytes(), shadow=(rel == "etc/shadow"))
            if records is None:
                report["identity_files"].append(rel)
            else:
                accounts[rel] = records
        except (OSError, ValueError):
            report["errors"].append({"file": rel, "error": "required account file missing, unreadable or unsafe"})
    if len(accounts) == 2 and accounts["etc/passwd"] != accounts["etc/shadow"]:
        report["identity_files"].extend(("etc/passwd", "etc/shadow"))


def authentication_path(rel):
    return (rel == "etc/greetd" or rel.startswith("etc/greetd/") or
            rel in {"etc/sudoers", "usr/lib/sudo/sudoers"} or
            rel.startswith(("etc/sudoers.d/", "etc/systemd/system/", "usr/lib/systemd/system/",
                            "etc/gdm", "etc/lightdm/", "etc/sddm")))


def unsafe_authentication(rel, data):
    try:
        text = data.decode("utf-8")
        if rel == "etc/greetd/config.toml":
            config = tomllib.loads(text)
            if "initial_session" in config:
                return True
            default = config.get("default_session", {})
            if default and not re.fullmatch(
                    r"/usr/sbin/agreety --cmd /usr/local/libexec/ditto-image-session", default.get("command", "")):
                return True
        continued = text.replace("\\\n", "")
        # A numeric sudo user/group id starts with '#'; it is not a comment.
        active = "\n".join(re.split(r"(?<!\S)#(?![0-9]+(?:\s|$))", line, maxsplit=1)[0]
                           for line in continued.splitlines())
        if rel == "etc/sudoers" or rel.startswith("etc/sudoers.d/") or rel == "usr/lib/sudo/sudoers":
            return bool(re.search(r"NOPASSWD\s*:|!\s*authenticate\b|\bexempt_group\s*=", active, re.I))
        return bool(re.search(
            r"(?:agetty[^\n]*(?:--autologin\b|\s-a(?:\s|=)))|"
            r"(?:\blogin\s+-f\b)|"
            r"(?:^\s*(?:AutomaticLoginEnable|TimedLoginEnable)\s*=\s*(?:true|yes|1)\s*$)|"
            r"(?:^\s*autologin-user\s*=\s*\S+)|"
            r"(?:\[Autologin\][\s\S]*?^\s*User\s*=\s*\S+)", active, re.I | re.M))
    except (UnicodeError, tomllib.TOMLDecodeError, AttributeError, TypeError):
        return True


def check_sudo_includes(root, report):
    pending = [root / "etc/sudoers", root / "usr/lib/sudo/sudoers"]
    directory = root / "etc/sudoers.d"
    if directory.is_symlink():
        report["authentication_config"].append("etc/sudoers.d")
    elif directory.is_dir():
        pending.extend(directory.iterdir())
    seen = set()
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        rel = path.relative_to(root).as_posix()
        try:
            # An include must not redirect the scanner outside the mounted image.
            if any(parent.is_symlink() for parent in [path, *path.parents] if parent != root):
                report["authentication_config"].append(rel)
                continue
            if not path.exists():
                if rel not in {"etc/sudoers", "usr/lib/sudo/sudoers"}:
                    report["authentication_config"].append(rel)
                continue
            if not path.is_file() or len(seen) > 256:
                report["authentication_config"].append(rel)
                continue
            data = path.read_bytes()
            if unsafe_authentication("etc/sudoers", data):
                report["authentication_config"].append(rel)
            for line in data.decode("utf-8").splitlines():
                match = re.match(r"^\s*[@#]include(dir)?\s+(.+)$", line)
                if not match:
                    continue
                words = shlex.split(match[2], comments=True)
                if (len(words) != 1 or not words[0].startswith("/") or
                        ".." in Path(words[0]).parts):
                    report["authentication_config"].append(rel)
                    continue
                target = root / words[0].lstrip("/")
                if match[1]:
                    if (any(parent.is_symlink() for parent in [target, *target.parents] if parent != root) or
                            not target.is_dir()):
                        report["authentication_config"].append(rel)
                    else:
                        pending.extend(target.iterdir())
                else:
                    pending.append(target)
        except (OSError, ValueError, UnicodeError):
            report["authentication_config"].append(rel)


def unit_link_contents(root, rel):
    """Read unit aliases inside the image; /dev/null is a systemd mask."""
    current = rel
    seen = set()
    for _ in range(64):
        if current in seen:
            raise ValueError("unit alias cycle")
        seen.add(current)
        path = root / current
        if any(parent.is_symlink() for parent in path.parents if parent != root):
            raise ValueError("unit alias parent symlink")
        if not path.is_symlink():
            return path.read_bytes()
        target = path.readlink().as_posix()
        if target == "/dev/null":
            return b""
        parts = [] if target.startswith("/") else list(Path(current).parent.parts)
        for part in target.split("/"):
            if part in ("", "."):
                continue
            if part == "..":
                if not parts:
                    raise ValueError("unit alias outside image")
                parts.pop()
            else:
                parts.append(part)
        current = "/".join(parts)
    raise ValueError("unit alias depth")


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
    terms = [s.encode() for s in args.forbid]
    # Named user homes and build-producer paths, not generic AppArmor home roots.
    producer_path = re.compile(
        rb"/home/[A-Za-z0-9_-][A-Za-z0-9_.-]*(?=/|[\s\"'\x00]|$)|"
        rb"/data/[A-Za-z0-9_.-]+/(?:worktrees|agent-runs|ditto-runs|cache/scratch)(?=/|[\s\"'\x00]|$)")
    private = re.compile(rb"-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----\r?\n"
                         rb"(?:[A-Za-z0-9+/=]+\r?\n){2,}-----END \1-----")
    report = {"regular_files": 0, "bytes_scanned": 0, "literal_matches": [],
              "unapproved_keys": [], "public_fixtures": [], "identity_files": [],
              "authentication_config": [], "errors": []}
    for required in ("usr/lib/os-release",):
        if not (root / required).is_file():
            report["errors"].append({"file": required, "error": "required pristine root file missing"})
    check_accounts(root, report)

    def walk_error(error):
        report["errors"].append({"file": str(error.filename), "errno": error.errno})

    for directory, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        for name in dirs:
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink() and authentication_path(rel):
                report["authentication_config"].append(rel)
        dirs[:] = [n for n in dirs if not (Path(directory) / n).is_symlink()]
        for name in files:
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            try:
                if path.is_symlink():
                    if (name in {"authorized_keys", "known_hosts"} or
                            rel.startswith("etc/ssh/ssh_host_") or
                            rel in {"etc/machine-id", "var/lib/systemd/random-seed"}):
                        report["identity_files"].append(rel)
                    if rel.startswith(("etc/systemd/system/", "usr/lib/systemd/system/")):
                        try:
                            if unsafe_authentication(rel, unit_link_contents(root, rel)):
                                report["authentication_config"].append(rel)
                        except (ValueError, OSError):
                            report["authentication_config"].append(rel)
                    elif rel in {"etc/passwd", "etc/shadow"} or authentication_path(rel):
                        report["authentication_config"].append(rel)
                    if (any(term in os.fsencode(path.readlink()) for term in terms) or
                            producer_path.search(os.fsencode(path.readlink()))):
                        report["literal_matches"].append(rel)
                    continue
                if not stat.S_ISREG(path.lstat().st_mode):
                    continue
                data = path.read_bytes()
                report["regular_files"] += 1
                report["bytes_scanned"] += len(data)
                if any(term in data for term in terms) or producer_path.search(data):
                    report["literal_matches"].append(rel)
                if authentication_path(rel) and unsafe_authentication(rel, data):
                    report["authentication_config"].append(rel)
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
            except OSError as error:
                report["errors"].append({"file": rel, "errno": error.errno})
    check_sudo_includes(root, report)
    print(json.dumps(report, indent=2))
    return int(any(report[key] for key in
                   ("literal_matches", "unapproved_keys", "identity_files", "authentication_config", "errors")))


if __name__ == "__main__":
    raise SystemExit(main())
