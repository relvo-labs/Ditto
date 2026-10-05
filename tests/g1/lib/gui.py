#!/usr/bin/env python3
"""Keyboard-driven GUI steps for G1 verification runs.

Every action here is synthetic input that the compositor delivers to the
focused surface (Wayfire's stipc plugin), the way a keyboard user works the
centers: Tab to a control, Enter or Space to press it, Ctrl+V to paste text.
The only thing read from the Shell is where focus is (`focus` on its control
socket: accessible name, role and enclosing group names). Nothing is pressed
through the socket.

Results are read back through Core with `relay` (tests/g1/lib/relay.mjs),
never from the Shell.

  gui.py focus
  gui.py tab-to <name> [--group <group>] [--max 300]
  gui.py press [enter|space]
  gui.py key <KEY_NAME>
  gui.py chord <MOD_KEY> <KEY_NAME>
  gui.py paste <text>           (wl-copy, then Ctrl+V into the focused field)
  gui.py relay <method> [<params-json>]
"""

import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "tools", "compositor-probe", "g1"))
from wfipc import Client  # noqa: E402


def runtime_dir() -> str:
    return os.environ.get("DITTO_RUNTIME_DIR") or os.path.join(os.environ["XDG_RUNTIME_DIR"], "ditto")


def line_request(path: str, text: str, timeout: float = 20.0) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(path)
        connection.sendall(text.encode("utf-8") + b"\n")
        buffer = b""
        while b"\n" not in buffer:
            chunk = connection.recv(65536)
            if not chunk:
                break
            buffer += chunk
        return buffer.decode("utf-8").split("\n", 1)[0]


def focus() -> dict:
    return json.loads(line_request(os.path.join(runtime_dir(), "shell.sock"), "focus", 5.0))


def feed(client: Client, key: str, state: bool) -> None:
    client.call("stipc/feed_key", {"key": key, "state": state})


def tap(client: Client, key: str) -> None:
    feed(client, key, True)
    feed(client, key, False)


def chord(client: Client, modifier: str, key: str) -> None:
    feed(client, modifier, True)
    tap(client, key)
    feed(client, modifier, False)


def settle(seconds: float = 0.08) -> None:
    time.sleep(seconds)


def tab_to(client: Client, name: str, group: str | None, limit: int) -> dict:
    """Press Tab until the focused control has `name` (and sits in `group`).
    Fails after `limit` presses or when focus comes back to where it started
    without a match, which means the control is not reachable by keyboard."""
    seen = []
    first = None
    for _ in range(limit):
        state = focus()
        focused = state.get("focused") or {}
        key = (focused.get("name"), tuple(focused.get("groups") or []))
        if focused.get("name") == name and (group is None or group in (focused.get("groups") or [])):
            return state
        if first is None:
            first = key
        elif key == first and len(seen) > 1:
            break
        seen.append(focused.get("name"))
        tap(client, "KEY_TAB")
        settle()
    raise SystemExit(json.dumps({"error": "not reachable by Tab", "name": name, "group": group,
                                 "visited": seen[-60:]}, ensure_ascii=False))


def relay(method: str, params: dict) -> dict:
    path = os.environ.get("DITTO_G1_RELAY")
    if not path:
        raise SystemExit("DITTO_G1_RELAY is not set")
    return json.loads(line_request(path, json.dumps({"method": method, "params": params})))


def main(argv: list[str]) -> None:
    if not argv:
        raise SystemExit(__doc__)
    command, rest = argv[0], argv[1:]
    if command == "focus":
        print(json.dumps(focus(), ensure_ascii=False))
        return
    if command == "relay":
        params = json.loads(rest[1]) if len(rest) > 1 else {}
        print(json.dumps(relay(rest[0], params), ensure_ascii=False))
        return
    client = Client()
    try:
        if command == "tab-to":
            name = rest[0]
            group = rest[rest.index("--group") + 1] if "--group" in rest else None
            limit = int(rest[rest.index("--max") + 1]) if "--max" in rest else 300
            print(json.dumps(tab_to(client, name, group, limit), ensure_ascii=False))
        elif command == "press":
            tap(client, "KEY_SPACE" if rest and rest[0] == "space" else "KEY_ENTER")
            settle(0.2)
        elif command == "key":
            tap(client, rest[0])
            settle()
        elif command == "chord":
            chord(client, rest[0], rest[1])
            settle()
        elif command == "paste":
            subprocess.run(["wl-copy", "--", rest[0]], check=True, timeout=5)
            settle(0.2)
            chord(client, "KEY_LEFTCTRL", "KEY_V")
            settle(0.2)
        else:
            raise SystemExit(f"unknown command {command}")
    finally:
        client.close()


if __name__ == "__main__":
    main(sys.argv[1:])
