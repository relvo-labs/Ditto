#!/usr/bin/env python3
"""Generate a mkosi 26 project from pinned source and an audited runtime tree."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-tar", type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--runtime-tree", type=Path, required=True)
    parser.add_argument("--runtime-lock", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--snapshot", default="20261020T000000Z")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for value, pattern in ((args.version, r"[0-9][A-Za-z0-9.\-]{0,31}"),
                           (args.snapshot, r"[0-9]{8}T[0-9]{6}Z"),
                           (args.source_commit, r"[0-9a-f]{40}"),
                           (args.source_sha256, r"[0-9a-f]{64}")):
        if not re.fullmatch(pattern, value):
            parser.error("invalid version, snapshot, commit or source digest")
    if args.output.exists():
        parser.error("output must not exist (use a fresh build directory)")
    if digest(args.source_tar) != args.source_sha256:
        parser.error("source archive digest mismatch")
    lock = json.loads(args.runtime_lock.read_text())
    expected = {"source_commit": args.source_commit,
                "source_sha256": args.source_sha256, "snapshot": args.snapshot,
                "qt": "6.10.2", "node": "22.23.2", "rust": "1.98.1",
                "quickshell_revision": "1a4716cde794a59928d9d9fc15f2afc7a95de360",
                "wayfire_revision": "d39902379c5737eebe1dc3a830659fa3f0fa22e0"}
    if any(lock.get(k) != v for k, v in expected.items()):
        parser.error("runtime provenance does not match the requested inputs/pins")
    if set(lock) - (expected.keys() | {"files", "symlinks"}):
        parser.error("runtime lock contains unsupported metadata")

    # Explicit destination allowlist. No whole machine/cache tree is copied.
    runtime_files = lock.get("files", {})
    runtime_links = lock.get("symlinks", {})
    if not isinstance(runtime_files, dict) or not isinstance(runtime_links, dict):
        parser.error("runtime files/symlinks must be objects")

    def allowed(name):
        path = PurePosixPath(name)
        return (not path.is_absolute() and ".." not in path.parts and
                (name in {"usr/bin/quickshell", "usr/bin/wayfire",
                          "usr/local/libexec/xdg-desktop-portal-wlr",
                          "usr/lib/ditto-node/bin/node"} or
                 name.startswith(("usr/lib/ditto/target/release/",
                                  "usr/lib/ditto/packages/host-runtime/dist/",
                                  "usr/lib/ditto/packages/agent-runtime/dist/",
                                  "usr/lib/ditto/target/ditto-packages/",
                                  "usr/lib/x86_64-linux-gnu/",
                                  "usr/lib/wayfire/",
                                  "usr/share/wayfire/", "usr/include/wayfire/",
                                  "usr/share/doc/ditto-runtime/"))))

    for name, sha in runtime_files.items():
        source = args.runtime_tree / name
        if (not allowed(name) or source.is_symlink() or
                not source.is_file() or not re.fullmatch(r"[0-9a-f]{64}", sha) or
                digest(source) != sha):
            parser.error(f"invalid runtime file or digest: {name}")
    for name, target in runtime_links.items():
        link = args.runtime_tree / name
        if (not allowed(name) or not isinstance(target, str) or
                not link.is_symlink() or link.readlink().as_posix() != target):
            parser.error(f"invalid runtime symlink: {name}")
        # Resolve against an image root, not against the build host.
        resolved = PurePosixPath(target) if target.startswith("/") else PurePosixPath(name).parent / target
        parts = []
        for part in resolved.parts:
            if part in ("/", "."):
                continue
            if part == "..":
                if not parts:
                    parser.error(f"escaping runtime link: {name}")
                parts.pop()
            else:
                parts.append(part)
        if "/".join(parts) not in runtime_files:
            parser.error(f"runtime link target must be a listed file: {name}")
    required = {"usr/bin/quickshell", "usr/bin/wayfire",
                "usr/lib/ditto-node/bin/node", "usr/local/libexec/xdg-desktop-portal-wlr"}
    required |= {f"usr/lib/ditto/target/release/{name}" for name in
                 ("ditto-core", "ditto-worker", "ditto-confine", "ditto-supervisor",
                  "dittoctl", "ditto-test-host", "ditto-dbus-proxy", "ditto-generation-runner")}
    required |= {"usr/lib/ditto/packages/host-runtime/dist/ditto-hostd.mjs",
                 "usr/lib/ditto/packages/agent-runtime/dist/ditto-agentd.mjs"}
    if not required <= runtime_files.keys():
        parser.error(f"missing runtime files: {sorted(required - runtime_files.keys())}")
    if not any(n.startswith("usr/lib/ditto/target/ditto-packages/") for n in runtime_files):
        parser.error("built-in package payload is missing")
    if not any(n.startswith("usr/share/doc/ditto-runtime/") for n in runtime_files):
        parser.error("runtime source/license/NOTICE material is missing")

    here = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="ditto-source-") as temp:
        source = Path(temp)
        with tarfile.open(args.source_tar) as archive:
            # git archive layout at tar root; data filter confines repository links.
            for member in archive.getmembers():
                if not (member.isfile() or member.isdir() or member.issym()):
                    parser.error(f"unsupported source archive member: {member.name}")
            archive.extractall(source, filter="data")
        needed = ["shell", "packaging/reference-image/session", "packaging/systemd/user"]
        if (not all((source / n).is_dir() for n in needed) or
                not (source / "tests/g0/input-method/fcitx5-profile").is_file()):
            parser.error("expected a source archive with repository paths at its root")
        output = args.output
        output.mkdir(parents=True)
        extra = output / "extra"

        def put(name, value, mode=0o644):
            path = output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
            path.chmod(mode)

        for name in ("shell", "packaging/reference-image/session"):
            shutil.copytree(source / name, extra / "usr/lib/ditto" / name,
                            symlinks=(name == "shell"))
        profile = extra / "usr/lib/ditto/tests/g0/input-method/fcitx5-profile"
        profile.parent.mkdir(parents=True)
        shutil.copy2(source / "tests/g0/input-method/fcitx5-profile", profile)
        for name in runtime_files:
            dest = extra / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(args.runtime_tree / name, dest)
        for name, target in runtime_links.items():
            dest = extra / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.symlink_to(target)
        flags = " ".join(line.split("#")[0].strip() for line in
                         (source / "packages/host-runtime/hostd.node-flags").read_text().splitlines()).strip()
        replacements = {"@DITTO_WORKSPACE@": "/usr/lib/ditto", "@DITTO_QT_PREFIX@": "/usr",
                        "@DITTO_WAYFIRE_PREFIX@": "/usr", "@DITTO_LIBEXEC@": "/usr/local/libexec",
                        "@DITTO_NODE@": "/usr/lib/ditto-node/bin/node",
                        "@DITTO_HOSTD_NODE_FLAGS@": flags, "@DITTO_AGENT_BACKEND_ARGS@": "",
                        "@DITTO_CODEX_STATUS@": "backend_unsupported", "@DITTO_CODEX_LANDLOCK_ABI@": "-1",
                        "@DITTO_SESSION_EXEC@": "/usr/local/libexec/ditto-image-session"}

        def expand(text):
            for key, value in replacements.items():
                text = text.replace(key, value)
            if re.search(r"@DITTO_[A-Z_]+@", text):
                parser.error("unexpanded session/unit placeholder")
            return text

        for unit in (source / "packaging/systemd/user").iterdir():
            put("extra/usr/lib/systemd/user/" + unit.name, expand(unit.read_text()))
        session = source / "packaging/reference-image/session"
        for name in ("ditto-session", "ditto-logout", "ditto-relogin", "ditto-end-sessions", "ditto-rescue-ui"):
            put("extra/usr/local/libexec/" + name, expand((session / name).read_text()), 0o755)
        put("extra/usr/share/wayland-sessions/ditto.desktop", expand((session / "ditto.desktop").read_text()))
        for src, dest in (("wayfire-portals.conf", "etc/xdg/xdg-desktop-portal/wayfire-portals.conf"),
                          ("xdpw-wayfire.conf", "etc/xdg/xdg-desktop-portal-wlr/Wayfire"),
                          ("xdpw-service.conf", "usr/lib/systemd/user/xdg-desktop-portal-wlr.service.d/ditto.conf")):
            put("extra/" + dest, (session / src).read_text())
        put("extra/usr/local/libexec/ditto-image-session", """#!/bin/sh
export DITTO_WORKSPACE=/usr/lib/ditto DITTO_QT_PREFIX=/usr DITTO_WAYFIRE_PREFIX=/usr
export DITTO_DRM_VENDOR=
exec /usr/local/libexec/ditto-session
""", 0o755)
        put("extra/etc/greetd/config.toml", """[terminal]
vt = 1
[default_session]
command = "/usr/sbin/agreety --cmd /usr/local/libexec/ditto-image-session"
user = "_greetd"
""")
        # Generalize the successful tty conflict/udev patch; no device PCI address.
        put("extra/etc/systemd/system/greetd.service.d/seat.conf", """[Unit]
Conflicts=getty@tty1.service
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
""")
        put("extra/usr/lib/systemd/network/20-wired.network", "[Match]\nName=en* eth*\n[Network]\nDHCP=yes\n")
        shutil.copytree(here / "repart.d", output / "mkosi.repart")
        shutil.copytree(here / "overlay", extra, dirs_exist_ok=True)
        shutil.copy2(here / "finalize.sh", output / "finalize.sh")
        put("extra/usr/share/ditto/image-inputs.json", json.dumps(expected | {"version": args.version,
            "runtime_lock_sha256": digest(args.runtime_lock)}, indent=2) + "\n")
        put("extra/usr/share/ditto/runtime-lock.json", json.dumps(lock, indent=2) + "\n")
        packages = [line for line in (here / "packages.txt").read_text().splitlines()
                    if line and not line.startswith("#")]
        put("mkosi.conf", f"""[Distribution]
Distribution=ubuntu
Release=resolute
Architecture=x86-64
Snapshot={args.snapshot}
Repositories=universe
[Output]
Format=disk
Output=ditto
OutputDirectory=out
ManifestFormat=json
ImageId=ditto
ImageVersion={args.version}
SplitArtifacts=partitions,uki,os-release
Seed=bb8fc9b5-47af-47a3-8f5e-c888bc480403
[Content]
Packages={','.join(packages)}
ExtraTrees=extra
FinalizeScripts=finalize.sh
Bootable=yes
Bootloader=systemd-boot
KernelCommandLine=console=tty0 rw root=PARTLABEL=ditto-state mount.usr=PARTLABEL=ditto-usr-%v mount.usrflags=ro rd.systemd.gpt_auto=no systemd.gpt_auto=no
[Validation]
SecureBoot=no
""")
    print(args.output)


if __name__ == "__main__":
    main()
