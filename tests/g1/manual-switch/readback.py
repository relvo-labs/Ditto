#!/usr/bin/env python3
"""Read back one EX1-01 step through Core (the relay driver) and judge it.

  readback.py <step> [args...]

Prints one JSON object: {"ok": bool, "detail": str, "change_id", "revision",
"state", ...}. Waits up to 20 s for the step's change to reach a terminal
state; the GUI is never asked whether it worked.
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from gui import relay  # noqa: E402

TERMINAL = {"committed", "rejected", "aborted", "rolled_back", "partially_applied", "unknown"}


def result(method: str, params: dict | None = None) -> dict:
    answer = relay(method, params or {})
    if "error" in answer:
        raise RuntimeError(f"{method}: {answer['error']}")
    return answer["result"]


def latest_change(after: str | None) -> dict | None:
    changes = result("desktop.changes.list", {"limit": 5})["changes"]
    for change in changes:
        if after is None or change["change_id"] > after:
            return change
    return None


def settled_change(after: str | None, timeout: float = 20.0) -> dict | None:
    deadline = time.monotonic() + timeout
    change = None
    while time.monotonic() < deadline:
        change = latest_change(after)
        if change and change["state"] in TERMINAL:
            return change
        time.sleep(0.25)
    return change


def active_document() -> tuple[dict, dict]:
    listed = result("desktop.profiles.get", {})
    return listed["profile"], listed["document"]


def slot_package(document: dict, slot: str) -> str | None:
    entry_id = document.get("slots", {}).get(slot)
    for entry in document.get("entries", []):
        if entry.get("entry_id") == entry_id:
            return entry.get("package")
    return None


def mounted(slot: str) -> dict | None:
    for panel in result("desktop.panels.list", {})["panels"]:
        if panel["slot"] == slot:
            return panel
    return None


def wait_until(predicate, timeout: float = 10.0):
    deadline = time.monotonic() + timeout
    value = predicate()
    while not value and time.monotonic() < deadline:
        time.sleep(0.25)
        value = predicate()
    return value


def profile_named(name: str) -> dict | None:
    for profile in result("desktop.profiles.list", {})["profiles"]:
        if profile["name"] == name:
            return profile
    return None


def owners_unique() -> tuple[bool, dict]:
    shortcuts = result("desktop.shortcuts.list", {})["shortcuts"]
    commands = result("desktop.commands.list", {})["commands"]
    chords: dict[str, set] = {}
    for shortcut in shortcuts:
        chords.setdefault(shortcut["chord"], set()).add(shortcut["owner"])
    ids: dict[str, set] = {}
    for command in commands:
        ids.setdefault(command["command_id"], set()).add(command["owner"])
    duplicate_chords = {chord: sorted(owners) for chord, owners in chords.items() if len(owners) > 1}
    duplicate_commands = {command: sorted(owners) for command, owners in ids.items() if len(owners) > 1}
    # A command listed twice by the same owner is a duplicate too.
    repeated = [c["command_id"] for c in commands]
    repeated = sorted({c for c in repeated if repeated.count(c) > 1})
    ok = not duplicate_chords and not duplicate_commands and not repeated
    return ok, {"duplicate_chords": duplicate_chords, "duplicate_commands": duplicate_commands,
                "repeated_command_ids": repeated, "shortcuts": len(shortcuts), "commands": len(commands)}


def emit(ok: bool, detail: str, **extra) -> None:
    print(json.dumps({"ok": ok, "detail": detail, **extra}, ensure_ascii=False))


def swap(after: str | None, slot: str, package: str) -> None:
    change = settled_change(after)
    if not change:
        return emit(False, "no change appeared after the GUI action")
    profile, document = active_document()
    bound = slot_package(document, slot)
    panel = wait_until(lambda: (lambda p: p if p and p.get("package") == package and p.get("mounted") else None)(mounted(slot)))
    ok = change["state"] == "committed" and bound == package and bool(panel)
    emit(ok, f"{slot}: change {change['state']}, profile binds {bound}, Shell mounts {(panel or mounted(slot) or {}).get('package')}",
         change_id=change["change_id"], revision=change.get("committed_revision"), state=change["state"],
         profile=profile["name"])


def layout(after: str | None, package: str, observed: str) -> None:
    change = settled_change(after)
    if not change:
        return emit(False, "no change appeared after the GUI action")
    current = wait_until(lambda: (lambda l: l if l.get("observed_strategy") == observed else None)(result("desktop.layout.get", {})))
    current = current or result("desktop.layout.get", {})
    ok = change["state"] == "committed" and current.get("strategy_package") == package and current.get("observed_strategy") == observed
    emit(ok, f"layout: change {change['state']}, profile {current.get('strategy_package')}, compositor reports {current.get('observed_strategy')}",
         change_id=change["change_id"], revision=change.get("committed_revision"), state=change["state"])


def saved_as(name: str, expect: dict) -> None:
    profile = wait_until(lambda: (lambda p: p if p and p.get("active") else None)(profile_named(name)))
    if not profile:
        found = profile_named(name)
        return emit(False, f"profile {name}: {'exists but is not active' if found else 'does not exist'}")
    _, document = active_document()
    mismatched = {slot: slot_package(document, slot) for slot, package in expect.items() if slot_package(document, slot) != package}
    emit(not mismatched, f"profile {name} is active; slots {'match' if not mismatched else 'differ: ' + json.dumps(mismatched)}",
         profile_id=profile["profile_id"], revision=profile["head_revision"])


def appearance(after: str | None, name: str, path: str, value: str) -> None:
    change = settled_change(after)
    if not change:
        return emit(False, "no change appeared after the GUI action")
    profile, document = active_document()
    actual = document
    for part in path.strip("/").split("/"):
        actual = actual.get(part) if isinstance(actual, dict) else None
    ok = change["state"] == "committed" and profile["name"] == name and str(actual) == value
    emit(ok, f"{name}: change {change['state']}, {path} = {actual}", change_id=change["change_id"],
         revision=change.get("committed_revision"), state=change["state"])


def compared(first: str, second: str, path_prefix: str) -> None:
    a, b = profile_named(first), profile_named(second)
    if not a or not b:
        return emit(False, "a profile to compare is missing")
    diff = result("desktop.profiles.diff", {"from": {"profile_id": a["profile_id"]}, "to": {"profile_id": b["profile_id"]}})
    paths = [item.get("path", "") for item in diff["items"]]
    ok = bool(paths) and all(path.startswith(path_prefix) for path in paths)
    emit(ok, f"{first} → {second}: {len(paths)} difference(s) {paths}", from_revision=diff["from_revision"],
         to_revision=diff["to_revision"])


def last_change_id() -> None:
    change = latest_change(None)
    print(change["change_id"] if change else "")


def main(argv: list[str]) -> None:
    step = argv[0]
    try:
        if step == "last-change":
            return last_change_id()
        if step == "swap":
            return swap(argv[1] or None, argv[2], argv[3])
        if step == "layout":
            return layout(argv[1] or None, argv[2], argv[3])
        if step == "saved-as":
            return saved_as(argv[1], json.loads(argv[2]))
        if step == "appearance":
            return appearance(argv[1] or None, argv[2], argv[3], argv[4])
        if step == "compared":
            return compared(argv[1], argv[2], argv[3])
        if step == "slot-package":
            _, document = active_document()
            return print(slot_package(document, argv[1]) or "")
        if step == "owners":
            ok, detail = owners_unique()
            return emit(ok, "no command or shortcut has two owners" if ok else "duplicate owners", **detail)
        raise SystemExit(f"unknown step {step}")
    except Exception as error:  # a readback that fails is a failed step
        emit(False, f"readback failed: {error}")


if __name__ == "__main__":
    main(sys.argv[1:])
