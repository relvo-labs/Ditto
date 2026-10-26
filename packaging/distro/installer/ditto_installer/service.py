"""Production wiring of the root backend inside the installer image."""

import json
from pathlib import Path
import pwd
import re
import subprocess

from . import disks, layout, manifest, writer
from .backend import Backend, listen, serve
from .medium import LABEL, find_medium

CONFIG = Path("/usr/lib/ditto-installer/installer.json")
SOCKET = Path("/run/ditto-installer/backend.sock")
MOUNT_POINT = Path("/run/ditto-installer/medium")
CONFIG_FIELDS = {"schema", "manifest_sha256", "medium_label", "payload_dir", "frontend_user"}


class ConfigError(ValueError):
    pass


def parse_config(data):
    try:
        config = json.loads(data)
    except ValueError as error:
        raise ConfigError("installer config is not JSON") from error
    if not isinstance(config, dict) or set(config) != CONFIG_FIELDS:
        raise ConfigError("installer config fields")
    checks = {
        "schema": lambda v: type(v) is int and v == 1,
        "manifest_sha256": lambda v: isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v),
        "medium_label": lambda v: isinstance(v, str) and LABEL.fullmatch(v),
        "payload_dir": lambda v: v == "ditto/payload",
        "frontend_user": lambda v: v == "ditto-installer",
    }
    for key, check in checks.items():
        if not check(config[key]):
            raise ConfigError(f"installer config value: {key}")
    return config


def _read(path):
    try:
        return Path(path).read_text()
    except OSError:
        return ""


def make_prepare(config, *, find=find_medium, sysfs="/sys", dev_root=Path("/dev"),
                 mountinfo_path="/proc/self/mountinfo", swaps_path="/proc/swaps", install=writer.install,
                 **find_kwargs):
    def prepare():
        medium = find(config["medium_label"], payload_subdir=config["payload_dir"], **find_kwargs)
        # The embedded SHA256 binds every manifest field, including version and commit.
        man = manifest.load(medium.payload_dir / "payload-manifest.json", config["manifest_sha256"])
        minimum = layout.minimum_disk_bytes(man)

        def enumerate_fn():
            return disks.enumerate_disks(sysfs, mountinfo=_read(mountinfo_path), swaps=_read(swaps_path),
                                         medium_devnums=medium.devnums, min_bytes=minimum)

        def install_fn(disk, cancel_check, progress):
            return install(man, medium.payload_dir, Path(dev_root) / disk.name, disk,
                           cancel_check=cancel_check, progress=progress)
        return enumerate_fn, install_fn
    return prepare


def reboot():
    subprocess.run(["systemctl", "reboot"], stdin=subprocess.DEVNULL, timeout=60, check=False)


def main():
    config = parse_config(CONFIG.read_text())
    user = pwd.getpwnam(config["frontend_user"])
    backend = Backend(make_prepare(config, mount_point=MOUNT_POINT), reboot)
    backend.start()
    server = listen(SOCKET, socket_gid=user.pw_gid)
    serve(server, backend, user.pw_uid)
