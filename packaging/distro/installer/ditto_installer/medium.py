"""Find and mount the installation medium by its fixed ISO volume label.

The medium is only a payload source. Its block device (and the file system it
backs) is reported so disk enumeration excludes the disk the installer booted
from. The mount command is a fixed argv; nothing comes from the frontend.
"""

from dataclasses import dataclass
import os
from pathlib import Path
import re
import stat
import subprocess
import time

LABEL = re.compile(r"DITTO_[A-Z0-9_]{1,26}")
MOUNT_OPTIONS = "ro,nosuid,nodev,noexec"


class MediumError(RuntimeError):
    def __init__(self, code="medium_unavailable", detail=""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code


@dataclass(frozen=True)
class Medium:
    device: Path
    payload_dir: Path
    devnums: frozenset


def _devnum(value):
    return f"{os.major(value)}:{os.minor(value)}"


def find_medium(label, *, payload_subdir="ditto/payload", by_label=Path("/dev/disk/by-label"),
                dev_root=Path("/dev"), mount_point=Path("/run/ditto-installer/medium"),
                runner=subprocess.run, timeout=90.0, interval=0.5, clock=time.monotonic, sleep=time.sleep,
                allow_regular_device=False):
    if not isinstance(label, str) or not LABEL.fullmatch(label):
        raise MediumError("medium_unavailable", "invalid label")
    link = Path(by_label) / label
    deadline = clock() + timeout
    while not link.exists():
        if clock() >= deadline:
            raise MediumError("medium_unavailable", "label not found")
        sleep(interval)
    device = Path(os.path.realpath(link))
    dev_root = Path(os.path.realpath(dev_root))
    if dev_root not in device.parents:
        raise MediumError("medium_unavailable", "label does not resolve to a device node")
    info = os.stat(device)
    if stat.S_ISBLK(info.st_mode):
        devnums = {_devnum(info.st_rdev)}
    elif allow_regular_device and stat.S_ISREG(info.st_mode):
        devnums = set()
    else:
        raise MediumError("medium_unavailable", "not a block device")
    mount_point = Path(mount_point)
    mount_point.mkdir(mode=0o755, parents=True, exist_ok=True)
    try:
        result = runner(["mount", "-t", "iso9660", "-o", MOUNT_OPTIONS, str(device), str(mount_point)],
                        stdin=subprocess.DEVNULL, capture_output=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        raise MediumError("medium_unavailable", "mount failed") from error
    if result.returncode != 0:
        raise MediumError("medium_unavailable", "mount failed")
    payload_dir = mount_point
    for part in Path(payload_subdir).parts:
        payload_dir = payload_dir / part
        if part in ("", ".", "..") or payload_dir.is_symlink() or not payload_dir.is_dir():
            raise MediumError("medium_unavailable", "payload directory missing")
    devnums.add(_devnum(os.stat(mount_point).st_dev))
    return Medium(device, payload_dir, frozenset(devnums))
