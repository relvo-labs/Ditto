#!/usr/bin/env python3
"""The observer side of tests/g1/cordis-independent (EX1-07).

Everything read from Core goes through the relay Core launched
(tests/g1/lib/relay.mjs, DITTO_G1_RELAY); what the QML tasks panel holds is
read from the Shell's `tasks` control line; notifications are sent on the
fixture's own session bus to the org.freedesktop.Notifications server that
Core's ditto-system owns there. It never kills anything; run.sh does.

  session.py setup <work>              tasks source = <work>/todo.txt (granted),
                                       notification rules = focus mode, empty
                                       allow-list; waits until the panel shows
                                       the file's first line
  session.py tasks-to-panel <todo> <marker>
                                       append <marker> to the file, then poll
                                       the panel and desktop.tasks.list
  session.py append <todo> <marker>    append only
  session.py notify <app> <low|normal|critical> <summary>
                                       send one notification, read back Core's
                                       record of it and the policy's decision
  session.py panel                     the Shell's `tasks` report
  session.py shell-absent              is the Shell gone (socket refuses, and
                                       Core reports no Shell connection)?
Each prints one JSON object.
"""

import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from gui import line_request, relay, runtime_dir  # noqa: E402

URGENCY = {"low": 0, "normal": 1, "critical": 2}


def must(method, params=None):
    answer = relay(method, params or {})
    if "error" in answer and answer["error"]:
        raise SystemExit(json.dumps({"ok": False, "error": f"{method}: {answer['error']}"}, ensure_ascii=False))
    return answer["result"]


def panel():
    try:
        return json.loads(line_request(os.path.join(runtime_dir(), "shell.sock"), "tasks", 2.0))
    except (OSError, ValueError) as error:
        return {"reachable": False, "error": str(error)}


def panel_shows(text):
    report = panel()
    return any(text in item for item in report.get("open") or []), report


def listed(text):
    result = relay("desktop.tasks.list", {})
    return text in json.dumps(result.get("result") or {}, ensure_ascii=False)


def setup(work):
    profile = must("desktop.profiles.get")
    slots = profile["document"]["slots"]
    tasks_entry, policy_entry = slots.get("svc.tasks"), slots.get("svc.notification_policy")
    if not tasks_entry or not policy_entry:
        raise SystemExit(json.dumps({"ok": False, "error": f"the profile binds svc.tasks={tasks_entry} svc.notification_policy={policy_entry}"}))
    todo = os.path.join(work, "todo.txt")
    with open(todo, "w", encoding="utf-8") as handle:
        handle.write("(A) 既有的一項\n")
    grant = must("desktop.permissions.grant", {
        "subject": f"host:{tasks_entry}", "scope": "files:todo", "resource": todo,
        "idempotency_key": f"g1-todo-{os.getpid()}"})
    entries = {entry["entry_id"]: entry for entry in profile["document"]["entries"]}
    changes = []
    for entry_id, after in (
        (tasks_entry, {**(entries[tasks_entry].get("config") or {}),
                       "source": {"kind": "todo_txt", "path_grant": grant["grant_id"]}}),
        (policy_entry, {**(entries[policy_entry].get("config") or {}),
                        "rules": {"focus": {"enabled": True, "allow": []}}}),
    ):
        head = must("desktop.profiles.get")["profile"]["head_revision"]
        change = must("desktop.changes.propose", {"base_revision": head, "ops": [{
            "op": "set_entry_config", "entry_id": entry_id,
            "before": entries[entry_id].get("config"), "after": after}]})
        changes.append(change["change_id"])
        if change["state"] != "committed":
            raise SystemExit(json.dumps({"ok": False, "error": f"configuring {entry_id} ended {change['state']} ({change.get('failure_key')})"}))
    # The rule as the running policy instance applies it.
    rules = must("desktop.notifications.policy.get").get("rules") or {}
    if not (rules.get("focus") or {}).get("enabled"):
        raise SystemExit(json.dumps({"ok": False, "error": "the policy does not apply focus mode after the change", "rules": rules}, ensure_ascii=False))
    until = time.monotonic() + 15
    shown, report = False, {}
    while time.monotonic() < until:
        shown, report = panel_shows("既有的一項")
        if shown and listed("既有的一項"):
            break
        time.sleep(0.1)
    if not shown:
        raise SystemExit(json.dumps({"ok": False, "error": "the tasks panel never showed the granted todo.txt", "panel": report}, ensure_ascii=False))
    return {"ok": True, "todo": todo, "tasks_entry": tasks_entry, "policy_entry": policy_entry,
            "grant_id": grant["grant_id"], "changes": changes, "policy_focus": rules.get("focus")}


def append(todo, marker):
    with open(todo, "a", encoding="utf-8") as handle:
        handle.write(marker + "\n")


def tasks_to_panel(todo, marker, limit=5.0):
    """Client monotonic clock: the write, then the first poll (every 20 ms) in
    which each observer shows the new line. There is no Core stamp for what a
    QML panel shows; the poll interval bounds the resolution."""
    written = time.monotonic()
    append(todo, marker)
    panel_ms = service_ms = None
    report = {}
    while time.monotonic() - written < limit and (panel_ms is None or service_ms is None):
        now = time.monotonic()
        if panel_ms is None:
            shown, report = panel_shows(marker)
            if shown:
                panel_ms = round((now - written) * 1000, 1)
        if service_ms is None and listed(marker):
            service_ms = round((now - written) * 1000, 1)
        time.sleep(0.02)
    return {"ok": True, "marker": marker, "panel_ms": panel_ms, "service_listed_ms": service_ms,
            "poll_interval_ms": 20, "clock": "client monotonic (write to first poll that shows it)", "panel": report}


def notify(app, urgency, summary):
    sent = subprocess.run(
        ["gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
         "--object-path", "/org/freedesktop/Notifications", "--method", "org.freedesktop.Notifications.Notify",
         app, "0", "", summary, "EX1-07", "[]", "{'urgency': <byte %d>}" % URGENCY[urgency], "5000"],
        capture_output=True, text=True, timeout=10)
    if sent.returncode != 0:
        return {"ok": False, "error": f"gdbus: {sent.stderr.strip()}"}
    notification_id = int(sent.stdout.strip().strip("(),").split()[-1])
    items = must("desktop.notifications.list", {"limit": 200})
    item = next((entry for entry in items["notifications"] if entry["id"] == notification_id), None)
    status = must("desktop.notifications.policy_status")
    decided = [entry for entry in status.get("recent") or [] if entry.get("app_name") == app]
    return {"ok": True, "id": notification_id, "app_name": app, "urgency": urgency,
            "server_owned": items["server_owned"], "item": item,
            "policy": {"available": status.get("available"), "provider_entry": status.get("provider_entry"),
                       "fallback_shown": status.get("fallback_shown"), "counters": status.get("counters"),
                       "recent_for_app": decided[-1] if decided else None}}


def shell_absent():
    refused = False
    try:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(1.0)
            connection.connect(os.path.join(runtime_dir(), "shell.sock"))
            connection.sendall(b"ping 1\n")
            refused = not connection.recv(64)
    except OSError:
        refused = True
    panels = relay("desktop.panels.list", {}).get("result") or {}
    return {"ok": True, "socket_refused": refused, "core_shell_connected": panels.get("shell_connected"),
            "absent": refused and panels.get("shell_connected") is False}


def main(argv):
    command, rest = argv[0], argv[1:]
    if command == "setup":
        result = setup(rest[0])
    elif command == "tasks-to-panel":
        result = tasks_to_panel(rest[0], rest[1])
    elif command == "append":
        append(rest[0], rest[1])
        result = {"ok": True}
    elif command == "notify":
        result = notify(rest[0], rest[1], rest[2])
    elif command == "panel":
        result = panel()
    elif command == "shell-absent":
        result = shell_absent()
    else:
        raise SystemExit(f"unknown command {command}")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1:])
