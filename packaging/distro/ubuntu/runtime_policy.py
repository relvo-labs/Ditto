"""Shared admission for the locked runtime; target packages remain authoritative."""

import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import subprocess

NATIVE = {"ditto-core", "ditto-worker", "ditto-confine", "ditto-supervisor", "dittoctl",
          "ditto-test-host", "ditto-dbus-proxy", "ditto-generation-runner"}
FIXED = {"usr/bin/quickshell", "usr/bin/wayfire", "usr/local/libexec/xdg-desktop-portal-wlr",
         "usr/lib/ditto-node/bin/node"} | {f"usr/lib/ditto/target/release/{n}" for n in NATIVE}
WAYFIRE_LIBRARY = re.compile(
    r"usr/lib/x86_64-linux-gnu/(?:libwf-(?:config|utils|touch|json)\.so(?:\.[0-9]+)*|"
    r"libwlroots-0\.20\.so(?:\.[0-9]+)*|wayfire/[A-Za-z0-9_.-]+\.so)")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def allowed(name):
    if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_./+\-]+", name) or
            name.startswith("/") or PurePosixPath(name).as_posix() != name or
            ".." in PurePosixPath(name).parts):
        return False
    return (name in FIXED or WAYFIRE_LIBRARY.fullmatch(name) is not None or
            re.fullmatch(r"usr/lib/wayfire/[A-Za-z0-9_.-]+\.so", name) is not None or
            name.startswith(("usr/lib/ditto/packages/host-runtime/dist/",
                             "usr/lib/ditto/packages/agent-runtime/dist/",
                             "usr/lib/ditto/target/ditto-packages/",
                             "usr/share/wayfire/", "usr/share/doc/ditto-runtime/")))


def link_destination(name, target, names, tree):
    if not isinstance(target, str) or not target or "\x00" in target:
        raise ValueError(f"invalid runtime link target: {name}")
    parts = [] if target.startswith("/") else list(PurePosixPath(name).parent.parts)
    tokens = target.split("/")
    for index, part in enumerate(tokens):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise ValueError(f"runtime link outside image: {name}")
            parts.pop()
        else:
            parts.append(part)
            if any(piece for piece in tokens[index + 1:]):
                prefix = "/".join(parts)
                if prefix in names:
                    raise ValueError(f"runtime link parent is a locked file/link: {name}")
                if tree is not None:
                    parent = confined_path(tree, prefix)
                    if parent.is_symlink() or not parent.is_dir():
                        raise ValueError(f"runtime link parent is missing or a symlink: {name}")
    return "/".join(parts)


def confined_path(root, name):
    """Reject parent symlinks before opening a file, including unlisted parents."""
    path = root
    for part in PurePosixPath(name).parts[:-1]:
        path /= part
        if path.is_symlink():
            raise ValueError(f"runtime parent symlink: {name}")
    return root / name


def validate(lock, tree=None):
    if tree is not None and (tree.is_symlink() or not tree.is_dir()):
        raise ValueError("runtime tree must be a real directory")
    files, links = lock.get("files"), lock.get("symlinks", {})
    if not isinstance(files, dict) or not isinstance(links, dict) or files.keys() & links.keys():
        raise ValueError("invalid runtime files/symlinks objects")
    names = files.keys() | links.keys()
    for name in names:
        if not allowed(name):
            raise ValueError(f"runtime destination is not admitted: {name}")
        for parent in PurePosixPath(name).parents:
            if parent.as_posix() in names:
                raise ValueError(f"runtime parent is a locked file/link: {name}")
    for name in links:
        seen, current = set(), name
        while current in links:
            if current in seen or len(seen) >= 64:
                raise ValueError(f"runtime link cycle/depth: {name}")
            seen.add(current)
            current = link_destination(current, links[current], names, tree)
            if current not in names:
                raise ValueError(f"runtime link target unlisted/outside admission: {name}")
        if current not in files:
            raise ValueError(f"runtime link has no regular file: {name}")
    for name, sha in files.items():
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
            raise ValueError(f"invalid runtime digest: {name}")
        if tree is not None:
            path = confined_path(tree, name)
            if path.is_symlink() or not path.is_file() or digest(path) != sha:
                raise ValueError(f"runtime file/digest mismatch: {name}")
    if tree is not None:
        for name, target in links.items():
            path = confined_path(tree, name)
            if not path.is_symlink() or path.readlink().as_posix() != target:
                raise ValueError(f"runtime link mismatch: {name}")
    return sorted(names)


def check_target_ownership(root, names):
    """Query only the installed TARGET database, never the builder's default DB."""
    root = root.absolute()
    if root == Path("/") or root.is_symlink():
        raise ValueError("refusing host root as a runtime target")
    admindir = confined_path(root, "var/lib/dpkg/status").parent
    if not (admindir / "status").is_file() or (admindir / "status").is_symlink():
        raise ValueError("target dpkg status database missing or unsafe")
    command = ["dpkg-query", f"--admindir={admindir}"]
    env = os.environ | {"LC_ALL": "C"}
    probe = subprocess.run(command + ["-W"], text=True, capture_output=True, env=env, timeout=30)
    if probe.returncode or probe.stderr:
        raise ValueError("target dpkg database query failed")
    for name in names:
        confined_path(root, name)
        paths = ["/" + name]
        # Account for package file lists using the legacy merged-/usr spelling.
        if name.startswith("usr/lib/") and (root / "lib").is_symlink():
            if (root / "lib").readlink().as_posix() in ("usr/lib", "/usr/lib"):
                paths.append("/" + name.removeprefix("usr/"))
        for path in paths:
            result = subprocess.run(command + ["-S", path], text=True, capture_output=True,
                                    env=env, timeout=30)
            if result.returncode == 0:
                raise ValueError(f"runtime path owned by an installed target package: {name}")
            expected = f"dpkg-query: no path found matching pattern {path}\n"
            if result.returncode != 1 or result.stdout or result.stderr != expected:
                raise ValueError(f"target dpkg ownership query failed closed: {name}")
