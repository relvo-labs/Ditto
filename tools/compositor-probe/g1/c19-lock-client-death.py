#!/usr/bin/env python3
"""C-19: lock the session with a client that shows an opaque magenta surface,
SIGKILL that client, and find out whether the compositor keeps the session
locked. Evidence per phase: a screenshot (grim over screencopy) reduced to its
dominant colours, whether typed keys reach an ordinary window, whether a
focus request is honoured, which command bindings fire, and whether a second
lock client can take over and unlock."""

import collections
import json
import os
import select
import signal
import subprocess
import sys
import time

import common
import wfipc

RUNTIME = os.environ["XDG_RUNTIME_DIR"]
ARTIFACTS = os.environ.get("DITTO_G1_PROBE_ARTIFACTS", RUNTIME)
RUN_ID = os.environ.get("DITTO_G1_RUN_ID", "local")
HERE = os.path.dirname(os.path.abspath(__file__))
TYPED = os.path.join(RUNTIME, "c19-typed.txt")
MAGENTA, CRASH_BLACK = (255, 0, 255), (0, 0, 0)
# Colours covering >1% of the unlocked baseline (background, the terminal).
# Their share in a locked screenshot is the "desktop visible" measure.
DESKTOP_COLOURS: list[tuple] = []


def screenshot(name: str) -> dict:
    png = os.path.join(ARTIFACTS, f"c19-{RUN_ID}-{name}.png")
    shot = subprocess.run(["grim", "-t", "ppm", "-"], capture_output=True, timeout=15)
    result = {"grim_exit": shot.returncode, "grim_stderr": shot.stderr.decode(errors="replace").strip()}
    if shot.returncode != 0:
        return result
    subprocess.run(["grim", png], capture_output=True, timeout=15)
    data = shot.stdout
    # Binary PPM: "P6\n<w> <h>\n<max>\n" then RGB triples.
    header, rest = data.split(b"\n", 3)[:3], data.split(b"\n", 3)[3]
    width, height = map(int, header[1].split())
    counts = collections.Counter(rest[i : i + 3] for i in range(0, width * height * 3, 3 * 7))
    total = sum(counts.values())
    top = [{"rgb": list(rgb), "fraction": round(n / total, 4)} for rgb, n in counts.most_common(5)]
    fraction = lambda rgb: round(counts.get(bytes(rgb), 0) / total, 4)
    desktop = sum(counts.get(bytes(rgb), 0) for rgb in DESKTOP_COLOURS) / total if DESKTOP_COLOURS else None
    result.update({"size": [width, height], "png": png, "dominant": top,
                   "baseline_desktop_colour_fraction": None if desktop is None else round(desktop, 4),
                   "magenta_fraction": fraction(MAGENTA), "black_fraction": fraction(CRASH_BLACK)})
    return result


def typed_reaches_window(c: wfipc.Client, letter: str) -> bool:
    wfipc.press(c, f"KEY_{letter.upper()}")
    wfipc.press(c, "KEY_ENTER")
    deadline = time.monotonic() + 1.5
    while time.monotonic() < deadline:
        if os.path.exists(TYPED) and letter in open(TYPED).read():
            return True
        time.sleep(0.05)
    return False


def bindings_fired(c: wfipc.Client, tag: str) -> dict:
    fired = {}
    for kind, key in (("normal", "KEY_F9"), ("exec_always", "KEY_F10")):
        path = os.path.join(RUNTIME, f"c19-binding-{kind}-{tag}")
        # Each phase gets its own marker through a fresh binding command.
        data = {"binding": f"<super> {key}", "command": f"touch {path}"}
        if kind == "exec_always":
            data["exec-always"] = True
        binding = c.call("command/register-binding", data)
        wfipc.press(c, "KEY_LEFTMETA", key)
        time.sleep(1.0)
        fired[kind] = os.path.exists(path)
        c.call("command/unregister-binding", {"binding-id": binding.get("binding-id")})
    return fired


def phase(c: wfipc.Client, name: str, victim: int, letter: str) -> dict:
    return {
        "phase": name,
        "screenshot": screenshot(name),
        "focus_request": c.call("window-rules/focus-view", {"id": victim}),
        "typed_reaches_window": typed_reaches_window(c, letter),
        "bindings_fired": bindings_fired(c, name),
        "views": common.toplevels(c),
    }


def read_lines(process: subprocess.Popen, want: set[str], timeout: float) -> list[str]:
    lines, deadline = [], time.monotonic() + timeout
    while time.monotonic() < deadline and not want.issubset(lines):
        ready, _, _ = select.select([process.stdout], [], [], max(0.0, deadline - time.monotonic()))
        if not ready:
            break
        line = process.stdout.readline().decode().strip()
        if not line:
            break
        lines.append(line)
    return lines


def main() -> int:
    build = subprocess.run(["bash", os.path.join(HERE, "build-lock-holder.sh"), RUNTIME],
                           capture_output=True, text=True)
    if build.returncode != 0:
        json.dump({"row": "C-19", "completed": False, "build_error": build.stderr}, sys.stdout)
        return 1
    holder = os.path.join(RUNTIME, "lock-holder")
    c = wfipc.Client()
    phases, ok = [], True
    try:
        victim = common.open_window(c, "probe-victim", "sh", "-c", f"cat > {TYPED}")
        time.sleep(0.5)
        phases.append(phase(c, "unlocked_baseline", victim, "a"))
        DESKTOP_COLOURS.extend(tuple(item["rgb"]) for item in
                               phases[0]["screenshot"].get("dominant", []) if item["fraction"] > 0.01)

        first = subprocess.Popen([holder], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        lines = read_lines(first, {"locked"}, 5.0)
        time.sleep(0.5)
        locked_phase = phase(c, "locked_by_client", victim, "b")
        locked_phase["client_output"] = lines
        phases.append(locked_phase)

        first.send_signal(signal.SIGKILL)
        first.wait()
        time.sleep(1.0)
        killed = phase(c, "after_sigkill_of_lock_client", victim, "c")
        killed["client_exit"] = first.returncode
        phases.append(killed)

        second = subprocess.Popen([holder, "unlock"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        lines = read_lines(second, {"locked", "unlocked"}, 5.0)
        try:
            second.wait(timeout=3)
        except subprocess.TimeoutExpired:
            second.kill()
            second.wait()
        time.sleep(0.5)
        takeover = phase(c, "second_client_locked_then_unlocked", victim, "d")
        takeover["client_output"] = lines
        takeover["client_exit"] = second.returncode
        takeover["client_stderr"] = second.stderr.read().decode(errors="replace")
        phases.append(takeover)
        # Keys sent while locked must not surface later either (no queueing).
        time.sleep(0.5)
        phases.append({"phase": "typed_file_at_end",
                       "content": open(TYPED).read() if os.path.exists(TYPED) else None})
    except Exception as error:
        phases.append({"phase": "exception", "error": repr(error)})
        ok = False
    finally:
        common.stop_children()
    log = os.environ.get("COMPOSITOR_LOG")
    lock_log = []
    if log and os.path.exists(log):
        lock_log = [line.rstrip() for line in open(log, errors="replace") if "lock" in line.lower()]
    json.dump({"row": "C-19", "probe": "ext_session_lock_v1 client death",
               "renderer": os.environ.get("WLR_RENDERER"), "phases": phases,
               "compositor_log_lock_lines": lock_log[-40:], "completed": ok},
              sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
