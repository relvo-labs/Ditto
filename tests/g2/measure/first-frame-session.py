#!/usr/bin/env python3
"""NFR-02 (EX2-13) on the reference machine's logged-in seat: warm opens of
the chat (Super+A) or the launcher (Super+Space), N runs after 5 warm-ups.

  first-frame-session.py [runs] [chat|launcher]

Run it in the Ditto login being measured (it drives that login's Wayfire
through its IPC socket, the stipc plugin). Each sample runs from the moment
the chord's key press is fed to the compositor to the Shell's
`ditto-mark <ms> <surface>.frame` (the surface's first swapped frame, QML
frameSwapped), both on this host's wall clock. The display shows that frame
at the next refresh, so presentation is later by at most one refresh
interval, which the report states; QML does not expose the compositor's
presentation feedback. The first sample is reported apart: it is a cold open
only if no earlier open of that surface appears in this login's journal.
Development hosts and the headless fixture use chat-first-frame.sh instead.
"""

import json
import math
import os
import queue
import subprocess
import sys
import threading
import time

here = os.path.dirname(os.path.abspath(__file__))
workspace = os.path.abspath(os.path.join(here, "..", "..", ".."))
sys.path.insert(0, os.path.join(workspace, "tools", "compositor-probe", "g1"))
from wfipc import Client  # noqa: E402

runs = int(sys.argv[1]) if len(sys.argv) > 1 else 200
surface = sys.argv[2] if len(sys.argv) > 2 else "chat"
chords = {"chat": ("KEY_LEFTMETA", "KEY_A"), "launcher": ("KEY_LEFTMETA", "KEY_SPACE")}
if surface not in chords:
    raise SystemExit("usage: first-frame-session.py [runs] [chat|launcher]")
runtime = os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
os.environ.setdefault("WAYFIRE_SOCKET", os.path.join(runtime, "ditto-wayfire-ipc.sock"))
mark = f" {surface}.frame"


def login_start() -> str:
    """When this login's compositor started (journalctl --since form)."""
    out = subprocess.run(["systemctl", "--user", "show", "-p", "ActiveEnterTimestamp", "--value", "ditto-wayfire.scope"],
                         capture_output=True, text=True, check=True).stdout.strip()
    return " ".join(out.split()[1:3]) if out else "today"


since = login_start()
earlier = subprocess.run(["journalctl", "--user", "-o", "cat", "--since", since, "--no-pager"],
                         capture_output=True, text=True).stdout
earlier_opens = sum(1 for line in earlier.splitlines() if "ditto-mark" in line and line.endswith(mark))

journal = subprocess.Popen(["journalctl", "--user", "-f", "-n", "0", "-o", "cat"], stdout=subprocess.PIPE, text=True, bufsize=1)
frames: "queue.Queue[int]" = queue.Queue()


def read_journal() -> None:
    # One reader owns the pipe; select() on a buffered text stream would miss
    # lines already read ahead into the buffer.
    for line in journal.stdout:
        line = line.strip()
        if "ditto-mark" in line and line.endswith(mark):
            frames.put(int(line.split("ditto-mark ", 1)[1].split()[0]))


threading.Thread(target=read_journal, daemon=True).start()
time.sleep(1.0)  # journalctl -f is following before the first press
client = Client()


def feed(key: str, state: bool) -> None:
    client.call("stipc/feed_key", {"key": key, "state": state})


def press_chord() -> int:
    modifier, key = chords[surface]
    feed(modifier, True)
    t0 = time.time_ns() // 1_000_000
    feed(key, True)
    feed(key, False)
    feed(modifier, False)
    return t0


def next_frame(timeout: float = 3.0) -> int | None:
    try:
        return frames.get(timeout=timeout)
    except queue.Empty:
        return None


samples = []
try:
    for i in range(1, runs + 6):
        t0 = press_chord()
        frame = next_frame()
        if frame is None and i == 1:
            # The surface was already open and the chord closed it.
            time.sleep(0.4)
            t0 = press_chord()
            frame = next_frame()
        if frame is None:
            raise SystemExit(f"run {i}: no {surface} frame after the shortcut")
        samples.append({"run": i, "warmup": i <= 5, "ms": frame - t0})
        time.sleep(0.4)
        press_chord()  # close again
        time.sleep(0.4)
finally:
    journal.terminate()

xs = sorted(s["ms"] for s in samples if not s["warmup"])
pick = lambda q: xs[min(len(xs) - 1, math.ceil(q * len(xs)) - 1)]
first = samples[0]
report = {
    "surface": surface,
    "runs": len(xs),
    "p50_ms": pick(0.5),
    "p95_ms": pick(0.95),
    "max_ms": xs[-1],
    "target_p95_ms": 150,
    "first_sample_ms": first["ms"],
    "first_sample_cold": earlier_opens == 0,
    "earlier_opens_in_login": earlier_opens,
    "clock": "key press fed to Wayfire (stipc) → Shell frameSwapped mark; presentation is up to one refresh later",
    "environment": os.environ.get("DITTO_MEASURE_ENVIRONMENT", "reference machine, logged-in Ditto seat"),
    "samples": samples,
}
out_dir = os.path.join(workspace, "artifacts", "g2")
os.makedirs(out_dir, exist_ok=True)
path = os.path.join(out_dir, f"first-frame-session-{surface}-{time.strftime('%Y-%m-%dT%H-%M-%SZ', time.gmtime())}.json")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=1)
print(json.dumps({k: v for k, v in report.items() if k != "samples"} | {"artifact": path}))
