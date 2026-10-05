#!/usr/bin/env python3
"""The D-34 status items against the real Shell (tests/g1/status-items/run.sh).

Runs inside the headless desktop fixture and prints one JSON object per line,
one per sub-check: {"id", "status", "detail", "evidence"}. Every result is
read back through Core (`desktop.profiles.get`, `desktop.panels.list` through
the relay Core launched); the Shell's `status` control line is read beside it
to see the items themselves (where they sit, in what order, their size and
text), never instead of Core.

  drive.py
"""

import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import gui  # noqa: E402

AREA = "ui.status_item"
FIXTURES = os.path.join(os.path.dirname(__file__), "..", "..", "..", "packages", "plugin-fixtures", "qml")



def emit(check_id: str, ok: bool, detail: str, evidence=None) -> None:
    print(json.dumps({"id": check_id, "status": "pass" if ok else "fail", "detail": detail,
                      "evidence": evidence}, ensure_ascii=False), flush=True)


def call(method: str, params: dict | None = None) -> dict:
    response = gui.relay(method, params or {})
    if "result" not in response:
        raise RuntimeError(f"{method}: {json.dumps(response, ensure_ascii=False)[:400]}")
    return response["result"]


def shell_status() -> dict:
    return json.loads(gui.line_request(os.path.join(gui.runtime_dir(), "shell.sock"), "status", 5.0))


def packages() -> list[dict]:
    found = []
    for name in sorted(os.listdir(FIXTURES)):
        manifest = json.load(open(os.path.join(FIXTURES, name, "manifest.json")))
        found.append(manifest)
    return found


def members() -> list[dict]:
    """Enabled members of the area, in Profile entry order, from Core."""
    document = call("desktop.profiles.get")["document"]
    return [entry for entry in document["entries"] if entry.get("area") == AREA and not entry.get("disabled")]


def rows() -> list[dict]:
    return [row for row in call("desktop.panels.list")["panels"] if row["slot"] == AREA]


def settled(expected: int, deadline: float = 10.0) -> tuple[list[dict], list[dict], dict]:
    """Wait for Core's rows and the Shell's items to agree on `expected`."""
    end = time.monotonic() + deadline
    while True:
        listed, shown = rows(), shell_status()
        ready = [row for row in listed if row["mounted"] and row["visible"] and row["mounted_entry"] == row["bound_entry"]]
        if (len(listed) == expected == len(ready) and len(shown["items"]) == expected) or time.monotonic() > end:
            return members(), listed, shown


def judge(expected: int, region: str = "panel") -> tuple[bool, str, dict]:
    entries, listed, shown = settled(expected)
    if expected and shown["region"] != region:
        # The region follows the panel's own commit; give it a moment.
        end = time.monotonic() + 5
        while time.monotonic() < end and shown["region"] != region:
            time.sleep(0.1)
            entries, listed, shown = members(), rows(), shell_status()
    order = [entry["entry_id"] for entry in entries]
    problems = []
    if len(entries) != expected:
        problems.append(f"the Profile has {len(entries)} enabled status items, not {expected}")
    if [row["bound_entry"] for row in listed] != order:
        problems.append("desktop.panels.list does not list the members in Profile order")
    bad = [row for row in listed if not (row["mounted"] and row["visible"] and row["mounted_entry"] == row["bound_entry"])]
    if bad:
        problems.append(f"{len(bad)} rows are not mounted and visible")
    if [item["entry_id"] for item in shown["items"]] != order:
        problems.append("the Shell lays the items out in another order, or holds other items")
    if expected and (shown["region"] != region or not shown["region_shown"]):
        problems.append(f"the items are in '{shown['region']}' (shown: {shown['region_shown']}), not the {region}")
    hidden = [item for item in shown["items"] if not (item["in_region"] and item["visible"] and item["width"] > 0 and item["height"] > 0)]
    if hidden:
        problems.append(f"{len(hidden)} items are not placed with a size on screen")
    evidence = {"members": order, "panels": listed, "shell": shown}
    return not problems, "; ".join(problems), evidence


def propose(ops: list[dict]) -> dict:
    head = call("desktop.profiles.get")["profile"]["head_revision"]
    response = gui.relay("desktop.changes.propose", {"base_revision": head, "ops": ops})
    return response.get("result") or response.get("error") or {}


def add(manifest: dict) -> dict:
    return {"op": "add_entry", "entry": {"package": manifest["id"], "version": manifest["version"], "host": "qml"}, "slot": AREA}


fixtures = packages()
clock = next(manifest for manifest in fixtures if manifest["id"].endswith("status_clock"))
rest = [manifest for manifest in fixtures if manifest is not clock]

# ① The plugin center enables one by keyboard: Tab to its button, Enter.
# Opening the center is the Shell-owned command the panel menu runs.
try:
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(os.path.join(gui.runtime_dir(), "shell.sock"))
        connection.sendall(b"command plugins.open\n")
    for _ in range(50):
        if gui.focus().get("open"):
            break
        time.sleep(0.1)
    name = f"在狀態列顯示「{clock['name']['zh-TW']}」"
    client = gui.Client()
    try:
        gui.tab_to(client, name, None, 400)
        gui.tap(client, "KEY_ENTER")
    finally:
        client.close()
    end = time.monotonic() + 15
    while time.monotonic() < end and not members():
        time.sleep(0.2)
    ok, detail, evidence = judge(1)
    emit("keyboard-enable", ok, detail or f"「{name}」 reached by Tab and pressed; the clock is mounted in the top panel", evidence)
except (SystemExit, Exception) as error:  # a control Tab cannot reach fails the check
    emit("keyboard-enable", False, f"the plugin center step failed: {error}")
    if not members():
        propose([add(clock)])

# ② The other four in one ChangeSet: five side by side, in Profile order.
record = propose([add(manifest) for manifest in rest])
ok, detail, evidence = judge(5)
ok = ok and record.get("state") == "committed"
if os.environ.get("STATUS_ITEMS_SCREENSHOT"):
    subprocess.run(["grim", os.environ["STATUS_ITEMS_SCREENSHOT"]], check=False, timeout=10,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
emit("five-mounted", ok, detail or "one ChangeSet committed; five rows mounted and visible in Profile order, five items in the top panel",
     {"change": {key: record.get(key) for key in ("change_id", "state", "items")}, **evidence})

# ③ One turned off: the other four stay, in order.
cpu = next(entry for entry in members() if entry["package"].endswith("status_cpu"))
record = propose([{"op": "set_entry_disabled", "entry_id": cpu["entry_id"], "disabled": True}])
ok, detail, evidence = judge(4)
ok = ok and record.get("state") == "committed"
emit("one-disabled", ok, detail or "the CPU item is off; four remain mounted in order", {"change_state": record.get("state"), **evidence})

# ④ A candidate that does not load aborts; the mounted items are untouched.
before = shell_status()
broken = {"op": "add_entry", "entry": {"package": "ditto.fixture.status_broken", "version": "1.0.0", "host": "qml"}, "slot": AREA}
record = propose([broken])
ok, detail, evidence = judge(4)
after = shell_status()
same = [item["entry_id"] for item in after["items"]] == [item["entry_id"] for item in before["items"]]
ok = ok and record.get("state") == "aborted" and same
emit("broken-aborts", ok, detail or ("the broken item's change ended " + str(record.get("state")) + "; the four mounted items were not touched"),
     {"change": {key: record.get(key) for key in ("change_id", "state", "items", "failure_key")}, **evidence})

# ④b Without a panel to host them, the Shell's own strip shows them; with
# the panel back (undo), they return to it. The panel provider stays
# replaceable without knowing about status items.
document = call("desktop.profiles.get")["document"]
panel = document["slots"].get("ui.panel_top")
record = propose([{"op": "remove_entry", "entry_id": panel}]) if panel else {}
ok, detail, evidence = judge(4, "strip")
ok = ok and record.get("state") == "committed"
undo = gui.relay("desktop.changes.undo", {"change_id": record.get("change_id")}).get("result") or {}
back_ok, back_detail, back_evidence = judge(4, "panel")
ok = ok and back_ok and undo.get("state") == "committed"
emit("strip-fallback", ok, "; ".join(part for part in (detail, back_detail) if part)
     or "with no top panel the four items are in the Shell's strip, mounted and visible; after undo they are back in the panel",
     {"remove_state": record.get("state"), "undo_state": undo.get("state"), "without_panel": evidence, "panel_back": back_evidence})

# ⑤ All removed: nothing left in the area, in Core or on screen.
record = propose([{"op": "remove_entry", "entry_id": entry["entry_id"]}
                  for entry in call("desktop.profiles.get")["document"]["entries"] if entry.get("area") == AREA])
ok, detail, evidence = judge(0)
ok = ok and record.get("state") == "committed"
emit("all-removed", ok, detail or "every status item removed; no row and no item remain", {"change_state": record.get("state"), **evidence})
