#!/usr/bin/env python3
"""Wait a bounded time for a DRM card with a backing device; no vendor/PCI pin."""

import argparse
from pathlib import Path
import re
import time


def wait_for_card(root, timeout, interval=0.1):
    deadline = time.monotonic() + timeout
    while True:
        if any(re.fullmatch(r"card[0-9]+", card.name) and (card / "device").exists()
               for card in root.glob("card*")):
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(interval, remaining))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sys-class-drm", type=Path, default=Path("/sys/class/drm"))
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    if not 0 <= args.timeout <= 30:
        parser.error("timeout must be between 0 and 30 seconds")
    if wait_for_card(args.sys_class_drm, args.timeout):
        return 0
    print("No backed DRM card became ready within the bounded wait.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
