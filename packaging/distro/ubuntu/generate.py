#!/usr/bin/env python3
"""Generate a mkosi 26 project from pinned source and an audited runtime tree."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
from runtime_policy import WAYFIRE_LIBRARY, validate

FIRSTBOOT_UNITS = ("ditto-firstboot-account.socket", "ditto-firstboot-account.service",
                   "ditto-firstboot-account-recover.service", "ditto-firstboot-account-tty.service",
                   "ditto-firstboot-tty-dispatch.socket", "ditto-firstboot-tty-dispatch.service",
                   "ditto-firstboot-tty-prepare.service")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


INSTALLER_UNITS = ("ditto-installer-backend.service", "ditto-installer-ui.service")
INSTALLER_LAUNCHERS = ("ditto-installer-backend", "ditto-installer-text", "ditto-installer-ui")


def installer_runtime(lock):
    """Only Quickshell, Wayfire (+ its libraries/plugins/data) and the runtime
    licence material go into the installer; Core, Node and the agent stay out."""
    def wanted(name):
        return (name in ("usr/bin/quickshell", "usr/bin/wayfire") or WAYFIRE_LIBRARY.fullmatch(name) is not None
                or re.fullmatch(r"usr/lib/wayfire/[A-Za-z0-9_.-]+\.so", name) is not None
                or name.startswith(("usr/share/wayfire/", "usr/share/doc/ditto-runtime/")))
    subset = {key: value for key, value in lock.items() if key not in ("files", "symlinks")}
    subset["files"] = {name: sha for name, sha in lock.get("files", {}).items() if wanted(name)}
    subset["symlinks"] = {name: target for name, target in lock.get("symlinks", {}).items() if wanted(name)}
    return subset


def read_packages(path):
    return [line for line in path.read_text().splitlines() if line and not line.startswith("#")]


def generate_installer(args, parser, source, here, expected, lock):
    """#221 installer: a full OS packed as the initrd of one UKI, run from RAM.

    It carries the installer backend/frontends from the same source archive and
    the payload manifest SHA256; it never stages the Ditto runtime, greetd or the
    first-account flow. Same snapshot, kernel pin and runtime-lock provenance.
    """
    installer = source / "packaging/distro/installer"
    modules = sorted((installer / "ditto_installer").glob("*.py"))
    files = [*modules, *(installer / "image" / name for name in INSTALLER_LAUNCHERS),
             *(installer / "image/units" / unit for unit in INSTALLER_UNITS),
             installer / "image/sysusers.d/ditto-installer.conf", installer / "image/wayfire-installer.ini",
             installer / "image/pam.d/ditto-installer", source / "shell/installer/shell.qml"]
    if not modules or not all(path.is_file() and not path.is_symlink() for path in files):
        parser.error("installer sources missing from the source archive")
    runtime = installer_runtime(lock)
    try:
        validate(runtime, args.runtime_tree)
    except (ValueError, OSError) as error:
        parser.error(f"installer runtime subset: {error}")
    output = args.output
    output.mkdir(parents=True)

    def put(name, value, mode=0o644):
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value)
        path.chmod(mode)

    for module in modules:
        put("extra/usr/lib/ditto-installer/ditto_installer/" + module.name, module.read_bytes())
    for name in INSTALLER_LAUNCHERS:
        put("extra/usr/lib/ditto-installer/" + name, (installer / "image" / name).read_bytes(), 0o755)
    for unit in INSTALLER_UNITS:
        put("extra/usr/lib/systemd/system/" + unit, (installer / "image/units" / unit).read_bytes())
    put("extra/usr/lib/sysusers.d/ditto-installer.conf",
        (installer / "image/sysusers.d/ditto-installer.conf").read_bytes())
    put("extra/usr/lib/ditto-installer/wayfire-installer.ini", (installer / "image/wayfire-installer.ini").read_bytes())
    put("extra/etc/pam.d/ditto-installer", (installer / "image/pam.d/ditto-installer").read_bytes())
    put("extra/usr/lib/ditto-installer/wait-drm", (here / "wait-drm.py").read_bytes(), 0o755)
    # The zh-TW screen uses the shared Shell components (Jelly, ui, i18n).
    shutil.copytree(source / "shell", output / "extra/usr/lib/ditto-installer/shell", symlinks=True)
    for name in runtime["files"]:
        dest = output / "runtime" / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.runtime_tree / name, dest)
    for name, target in runtime["symlinks"].items():
        dest = output / "runtime" / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.symlink_to(target)
    for helper in ("apply-runtime.py", "runtime_policy.py"):
        shutil.copy2(here / helper, output / helper)
    put("extra/usr/share/ditto/runtime-lock.json", (json.dumps(runtime, indent=2) + "\n").encode())
    put("extra/usr/lib/ditto-installer/installer.json", (json.dumps({
        "schema": 1, "manifest_sha256": args.payload_manifest_sha256, "medium_label": args.medium_label,
        "payload_dir": "ditto/payload", "frontend_user": "ditto-installer"}, indent=2) + "\n").encode())
    put("extra/usr/share/ditto/image-inputs.json", (json.dumps(expected | {
        "version": args.version, "runtime_lock_sha256": digest(args.runtime_lock), "mode": "installer",
        "runtime_subset_files": len(runtime["files"]), "runtime_subset_symlinks": len(runtime["symlinks"]),
        "payload_manifest_sha256": args.payload_manifest_sha256, "medium_label": args.medium_label},
        indent=2) + "\n").encode())
    shutil.copy2(here / "finalize-installer.sh", output / "finalize.sh")
    packages = read_packages(here / "packages-installer.txt")
    put("mkosi.conf", f"""[Distribution]
Distribution=ubuntu
Release=resolute
Architecture=x86-64
Snapshot={args.snapshot}
Repositories=universe
[Output]
Format=uki
Output=ditto-installer
OutputDirectory=out
ManifestFormat=json
ImageId=ditto-installer
ImageVersion={args.version}
[Content]
Packages={','.join(packages)}
ExtraTrees=extra
FinalizeScripts=finalize.sh
KernelCommandLine=console=tty0 rd.systemd.gpt_auto=no systemd.gpt_auto=no
[Build]
BuildSources=.
[Validation]
SecureBoot=no
""".encode())


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
    parser.add_argument("--dev-software-render", action="store_true",
                        help="TEST ONLY: allow software rendering in the generated session")
    parser.add_argument("--profile", choices=("image", "installer"), default="image",
                        help="image: the Ditto disk; installer: the #221 RAM-only installer UKI")
    parser.add_argument("--payload-manifest-sha256",
                        help="installer only: SHA256 printed by make-payload.py for the payload it will carry")
    parser.add_argument("--medium-label", help="installer only: ISO volume label, e.g. DITTO_INSTALL_7")
    args = parser.parse_args()
    installer_args = (args.payload_manifest_sha256, args.medium_label)
    if args.profile == "installer":
        if (not isinstance(args.payload_manifest_sha256, str) or
                not re.fullmatch(r"[0-9a-f]{64}", args.payload_manifest_sha256) or
                not isinstance(args.medium_label, str) or
                not re.fullmatch(r"DITTO_[A-Z0-9_]{1,26}", args.medium_label)):
            parser.error("installer profile needs --payload-manifest-sha256 and a DITTO_ --medium-label")
        if args.dev_software_render:
            parser.error("--dev-software-render applies to the image profile only")
    elif any(value is not None for value in installer_args):
        parser.error("--payload-manifest-sha256/--medium-label apply to the installer profile only")
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

    runtime_files = lock.get("files", {})
    runtime_links = lock.get("symlinks", {})
    try:
        validate(lock, args.runtime_tree)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    with tarfile.open(args.source_tar) as archive:
        if archive.pax_headers.get("comment") != args.source_commit:
            parser.error("source git archive PAX comment does not match source commit")

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
        # TODO_FIRSTBOOT_ACCOUNT_PR_A: retain the all-absent legacy path for
        # older source archives. Merged sources require the complete delivery.
        firstboot = source / "packaging/distro/first-boot"
        helper_sources = [source / "crates/ditto-firstboot-account/Cargo.toml",
                          source / "crates/ditto-firstboot-account/UNICODE-NOTICE.txt",
                          *(firstboot / "units" / unit for unit in FIRSTBOOT_UNITS),
                          firstboot / "tmpfiles.d/ditto-firstboot.conf"]
        helper_binary = "usr/lib/ditto/target/release/ditto-firstboot-account"
        enable_firstboot = (any(path.exists() or path.is_symlink() for path in helper_sources)
                            or helper_binary in runtime_files or helper_binary in runtime_links)
        if enable_firstboot and (not all(path.is_file() and not path.is_symlink() for path in helper_sources)
                                 or helper_binary not in runtime_files
                                 or not (firstboot / "ditto-firstboot-tty").is_file()
                                 or (firstboot / "ditto-firstboot-tty").is_symlink()):
            parser.error("PR A firstboot artifacts incomplete: need helper binary, crate, units and tmpfiles")
        if args.profile == "installer":
            generate_installer(args, parser, source, here, expected, lock)
            print(args.output)
            return
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
            dest = output / "runtime" / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(args.runtime_tree / name, dest)
        for name, target in runtime_links.items():
            dest = output / "runtime" / name
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
        for name, dest, mode in (
                ("ditto-greeter", "usr/lib/ditto/ditto-greeter", 0o755),
                ("wayfire-greeter.ini", "usr/lib/ditto/wayfire-greeter.ini", 0o644),
                ("fcitx5-profile", "usr/lib/ditto/firstboot-fcitx5-profile", 0o644)):
            put("extra/" + dest, (firstboot / name).read_text(), mode)
        if enable_firstboot:
            put("extra/usr/lib/ditto/ditto-firstboot-tty", (firstboot / "ditto-firstboot-tty").read_text(), 0o755)
            for unit in FIRSTBOOT_UNITS:
                put("extra/usr/lib/systemd/system/" + unit, (firstboot / "units" / unit).read_text())
            put("extra/usr/share/doc/ditto-firstboot-account/UNICODE-NOTICE.txt",
                (source / "crates/ditto-firstboot-account/UNICODE-NOTICE.txt").read_text())
            put("extra/usr/lib/tmpfiles.d/ditto-firstboot.conf",
                (firstboot / "tmpfiles.d/ditto-firstboot.conf").read_text())
            (extra / "usr/lib/ditto/ditto-firstboot-account").symlink_to("target/release/ditto-firstboot-account")
            # Match the real units' WantedBy. Recovery orders before greetd,
            # but a recovery setup failure must not prevent existing login.
            for target, unit in (("sockets.target", "ditto-firstboot-account.socket"),
                                 ("sockets.target", "ditto-firstboot-tty-dispatch.socket"),
                                 ("sysinit.target", "ditto-firstboot-account-recover.service"),
                                 ("greetd.service", "ditto-firstboot-account-recover.service")):
                directory = extra / "etc/systemd/system" / (target + ".wants")
                directory.mkdir(parents=True, exist_ok=True)
                (directory / unit).symlink_to("/usr/lib/systemd/system/" + unit)
        greeter_command = ("/usr/lib/ditto/ditto-greeter" if enable_firstboot else
                           "/usr/sbin/agreety --cmd /usr/local/libexec/ditto-image-session")
        put("extra/usr/share/ditto/firstboot-integration.json", json.dumps({
            "enabled": enable_firstboot, "pending": None if enable_firstboot else "TODO_FIRSTBOOT_ACCOUNT_PR_A"}) + "\n")
        put("extra/etc/greetd/config.toml", f"""[terminal]
vt = 1
[default_session]
command = "{greeter_command}"
user = "_greetd"
""")
        if args.dev_software_render:
            launcher = output / "extra/usr/local/libexec/ditto-image-session"
            launcher.write_text(launcher.read_text().replace(
                "exec /usr/local/libexec/ditto-session",
                "# TEST ONLY: GPU-less development run\n"
                "export WLR_RENDERER_ALLOW_SOFTWARE=1 LIBGL_ALWAYS_SOFTWARE=1\n"
                "exec /usr/local/libexec/ditto-session"))
        # Bounded readiness is advisory: no DRM must reach the wrapper/TTY path.
        put("extra/etc/systemd/system/greetd.service.d/seat.conf", """[Unit]
Conflicts=getty@tty1.service
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
[Service]
ExecStartPre=-/usr/lib/ditto/wait-drm
""")
        put("extra/usr/lib/systemd/network/20-wired.network", "[Match]\nName=en* eth*\n[Network]\nDHCP=yes\n")
        shutil.copytree(here / "repart.d", output / "mkosi.repart")
        shutil.copytree(here / "overlay", extra, dirs_exist_ok=True)
        shutil.copy2(here / "finalize.sh", output / "finalize.sh")
        for helper in ("apply-runtime.py", "runtime_policy.py"):
            shutil.copy2(here / helper, output / helper)
        put("extra/usr/lib/ditto/wait-drm", (here / "wait-drm.py").read_text(), 0o755)
        put("extra/usr/share/ditto/image-inputs.json", json.dumps(expected | {"version": args.version,
            "runtime_lock_sha256": digest(args.runtime_lock),
            "mode": "dev-software-render" if args.dev_software_render else "normal"}, indent=2) + "\n")
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
[Build]
BuildSources=.
[Validation]
SecureBoot=no
""")
    print(args.output)


if __name__ == "__main__":
    main()
