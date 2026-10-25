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
            if (default.get("command") == "/usr/lib/ditto/ditto-greeter" and default.get("user") != "_greetd"):
                return True
            if default and not re.fullmatch(
                    r"(?:/usr/sbin/agreety --cmd /usr/local/libexec/ditto-image-session|/usr/lib/ditto/ditto-greeter)", default.get("command", "")):
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


# Symlinks followed across one whole unit alias chain, parent and leaf
# components together; never reset per component (Linux MAXSYMLINKS).
UNIT_ALIAS_MAX_HOPS = 40


def unit_link_contents(root, rel):
    """Read a unit alias in IMAGE coordinates; exact leaf /dev/null is a mask.

    Every component is resolved under root, including merged-/usr parent links
    such as lib -> usr/lib: an absolute target restarts at the image root, never
    at the host's. A parent link is expanded before any following '..'. Escapes,
    cycles/over-long chains, dangling or missing components and non-regular
    destinations raise; types are checked before opening, so a FIFO is never
    opened. OSError propagates for the caller to report without its text.
    """
    pending, parts, hops = rel.split("/"), [], 0
    while pending:
        part = pending.pop(0)
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise ValueError("unit alias outside image")
            parts.pop()
            continue
        path = root.joinpath(*parts, part)
        mode = os.lstat(path).st_mode
        if stat.S_ISLNK(mode):
            hops += 1
            if hops > UNIT_ALIAS_MAX_HOPS:
                raise ValueError("unit alias cycle/depth")
            target = os.readlink(path)
            if not pending and target == "/dev/null":
                return b""
            if target.startswith("/"):
                parts = []
            pending = target.split("/") + pending
        elif pending and not stat.S_ISDIR(mode):
            raise ValueError("unit alias component is not a directory")
        elif not pending and not stat.S_ISREG(mode):
            raise ValueError("unit alias destination is not a regular file")
        else:
            parts.append(part)
    if not parts:
        raise ValueError("unit alias destination is not a regular file")
    descriptor = os.open(root.joinpath(*parts),
                         os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with open(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("unit alias destination is not a regular file")
        return stream.read()


# Exact public producer-path fixtures (#205 owner decision): only a regular file
# whose image path AND complete bytes equal one manifest entry has its
# producer-path hit reported as public instead of literal. Every other check
# still runs on those bytes.
PUBLIC_PRODUCER_MANIFEST = "public-producer-path-fixtures.json"
# Ditto's own install locations hold Ditto-built bytes: never registrable.
OWNED_IMAGE_PREFIXES = ("usr/lib/ditto/", "usr/share/ditto/", "usr/share/doc/ditto-runtime/",
                        "usr/local/libexec/")
SOURCE_KINDS = {
    "ubuntu-deb": ({"kind", "package", "version", "deb", "deb_sha256", "packages_index", "index_sha256"},
                   "signed-snapshot-index"),
    "upstream-archive": ({"kind", "name", "version", "url", "member", "archive_sha256", "shasums_url"},
                         "https-shasums-pgp-unverified"),
}
SHA256_HEX = re.compile(r"[0-9a-f]{64}")


def _unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(_name):
    raise ValueError("non-finite JSON number")


def canonical_image_path(path):
    return (isinstance(path, str) and not path.startswith("/") and
            not any(ord(char) < 32 or char in "\\\x7f" for char in path) and
            all(part not in ("", ".", "..") for part in path.split("/")))


def load_public_producer_fixtures(path):
    """Return {image path: entry}; any missing, malformed or ambiguous data raises ValueError."""
    def text(value):
        return isinstance(value, str) and value != "" and value == value.strip()

    try:
        manifest = json.loads(path.read_bytes().decode("utf-8"), object_pairs_hook=_unique_keys,
                              parse_constant=_reject_constant)
    except (OSError, UnicodeError, RecursionError) as error:
        raise ValueError("manifest unreadable") from error
    if (not isinstance(manifest, dict) or set(manifest) != {"schema", "authority", "entries"} or
            type(manifest["schema"]) is not int or manifest["schema"] != 1 or
            not text(manifest["authority"]) or
            not isinstance(manifest["entries"], list) or not manifest["entries"]):
        raise ValueError("manifest structure")
    fixtures = {}
    for entry in manifest["entries"]:
        if (not isinstance(entry, dict) or
                set(entry) != {"path", "sha256", "bytes", "source", "verification", "classification"}):
            raise ValueError("entry fields")
        path_value, source, verification = entry["path"], entry["source"], entry["verification"]
        if (not canonical_image_path(path_value) or path_value in fixtures or
                (path_value + "/").startswith(OWNED_IMAGE_PREFIXES)):
            raise ValueError("entry path not canonical, duplicated or Ditto-owned")
        if (not isinstance(entry["sha256"], str) or not SHA256_HEX.fullmatch(entry["sha256"]) or
                type(entry["bytes"]) is not int or entry["bytes"] <= 0 or
                not text(entry["classification"])):
            raise ValueError("entry digest, size or classification")
        kind = source.get("kind") if isinstance(source, dict) else None
        if not isinstance(kind, str) or kind not in SOURCE_KINDS or set(source) != SOURCE_KINDS[kind][0]:
            raise ValueError("entry source")
        if not all(text(value) for value in source.values()) or not all(
                SHA256_HEX.fullmatch(source[key]) for key in source if key.endswith("_sha256")):
            raise ValueError("entry source values")
        if (not isinstance(verification, dict) or set(verification) != {"level", "detail"} or
                not isinstance(verification["level"], str) or
                verification["level"] != SOURCE_KINDS[kind][1] or not text(verification["detail"])):
            raise ValueError("entry verification")
        fixtures[path_value] = entry
    return fixtures


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
              "unapproved_keys": [], "public_fixtures": [], "public_producer_fixtures": [],
              "identity_files": [], "authentication_config": [], "errors": []}
    try:
        producer_fixtures = load_public_producer_fixtures(Path(__file__).parent / PUBLIC_PRODUCER_MANIFEST)
    except ValueError:
        # Fail closed: nothing is classified and the scan cannot succeed.
        producer_fixtures = {}
        report["errors"].append({"file": PUBLIC_PRODUCER_MANIFEST,
                                 "error": "public producer fixture manifest missing, unreadable or invalid"})
    for required in ("usr/lib/os-release",):
        if not (root / required).is_file():
            report["errors"].append({"file": required, "error": "required pristine root file missing"})
    check_accounts(root, report)
    # Any marker presence (including a link/directory or unsafe parent) is
    # machine-specific state. lstat each component; never follow outside root.
    for marker in ("account-created", "pending"):
        rel = "var/lib/ditto/firstboot/" + marker
        path = root
        for part in Path(rel).parts:
            path /= part
            try:
                mode = path.lstat().st_mode
            except FileNotFoundError:
                break
            except OSError as error:
                report["errors"].append({"file": rel, "errno": error.errno})
                break
            if stat.S_ISLNK(mode) or path == root / rel:
                report["identity_files"].append(rel)
                break
            if not stat.S_ISDIR(mode):
                report["identity_files"].append(rel)
                break

    def walk_error(error):
        report["errors"].append({"file": str(error.filename), "errno": error.errno})

    for directory, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        for name in dirs:
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            # os.walk puts directory symlinks here, before pruning them below.
            if rel == "boot/loader/random-seed":
                report["identity_files"].append(rel)
            if path.is_symlink() and authentication_path(rel):
                report["authentication_config"].append(rel)
        dirs[:] = [n for n in dirs if not (Path(directory) / n).is_symlink()]
        for name in files:
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            # Presence alone is disallowed, even an empty file or dangling link.
            # Keep scanning regular bytes/link text with all existing rules.
            if rel == "boot/loader/random-seed":
                report["identity_files"].append(rel)
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
                if any(term in data for term in terms):
                    report["literal_matches"].append(rel)
                elif producer_path.search(data):
                    fixture = producer_fixtures.get(rel)
                    if (fixture and len(data) == fixture["bytes"] and
                            hashlib.sha256(data).hexdigest() == fixture["sha256"]):
                        report["public_producer_fixtures"].append({
                            "file": rel, "sha256": fixture["sha256"], "source": fixture["source"],
                            "verification": fixture["verification"]["level"]})
                    else:
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
