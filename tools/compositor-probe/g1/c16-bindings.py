#!/usr/bin/env python3
"""C-16: add and remove a global key binding while the session runs, trigger
it with synthetic input (stipc), and confirm it no longer fires once removed.
Two paths: the command plugin's IPC methods, and its `command/bindings`
option set through `wayfire/set-config-options`."""

import json
import os
import sys
import time

import common
import wfipc

RUNTIME = os.environ["XDG_RUNTIME_DIR"]


def marker(name: str) -> str:
    return os.path.join(RUNTIME, f"c16-{name}")


def fired(name: str, wait: float = 1.5) -> bool:
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if os.path.exists(marker(name)):
            return True
        time.sleep(0.05)
    return False


def main() -> int:
    c = wfipc.Client()
    steps = []
    ok = True
    try:
        # A focused ordinary window, so a binding that did not fire would have
        # delivered the keys to a client instead of vanishing.
        common.open_window(c, "probe-focus")

        # 1. IPC binding with a command: persists beyond the registering client.
        reply = c.call("command/register-binding",
                       {"binding": "<super> KEY_F9", "command": f"touch {marker('ipc')}"})
        wfipc.press(c, "KEY_LEFTMETA", "KEY_F9")
        steps.append({"step": "ipc_register_and_trigger", "reply": reply, "fired": fired("ipc")})
        binding_id = reply.get("binding-id")

        # Persistent: a new connection triggers it after the first one closed.
        c.close()
        c = wfipc.Client()
        os.unlink(marker("ipc")) if os.path.exists(marker("ipc")) else None
        wfipc.press(c, "KEY_LEFTMETA", "KEY_F9")
        steps.append({"step": "ipc_trigger_after_registering_client_closed", "fired": fired("ipc")})

        os.unlink(marker("ipc")) if os.path.exists(marker("ipc")) else None
        reply = c.call("command/unregister-binding", {"binding-id": binding_id})
        wfipc.press(c, "KEY_LEFTMETA", "KEY_F9")
        steps.append({"step": "ipc_unregister_and_trigger", "reply": reply, "fired": fired("ipc")})

        # 2. Temporary binding (no command): the compositor sends an event to
        # the registering connection instead of running anything.
        listener = wfipc.Client()
        reply = listener.call("command/register-binding", {"binding": "<super> KEY_F8"})
        wfipc.press(c, "KEY_LEFTMETA", "KEY_F8")
        events = listener.events(1.0)
        steps.append({"step": "temporary_binding_event", "reply": reply, "events": events})
        listener.close()
        time.sleep(0.3)
        # Removal on disconnect (command.cpp on_client_disconnect) is read from
        # the source, not observed: with no list method and no listener left,
        # this probe has nothing to read it back from.

        # 3. Two IPC bindings on the same combination: does Wayfire keep a
        # single owner, or run both?
        r1 = c.call("command/register-binding",
                    {"binding": "<super> KEY_F7", "command": f"touch {marker('dup1')}"})
        r2 = c.call("command/register-binding",
                    {"binding": "<super> KEY_F7", "command": f"touch {marker('dup2')}"})
        wfipc.press(c, "KEY_LEFTMETA", "KEY_F7")
        steps.append({"step": "duplicate_combination", "replies": [r1, r2],
                      "fired_first": fired("dup1"), "fired_second": fired("dup2")})
        c.call("command/unregister-binding", {"binding-id": r1.get("binding-id")})
        c.call("command/unregister-binding", {"binding-id": r2.get("binding-id")})

        # 4. Config path: command/bindings through set-config-options.
        reply = c.call("wayfire/set-config-options", {"command/bindings": {
            "ditto_probe": {"command": f"touch {marker('config')}", "binding": "<super> KEY_F10"}}})
        time.sleep(0.3)
        readback = c.call("wayfire/get-config-option", {"option": "command/bindings"})
        wfipc.press(c, "KEY_LEFTMETA", "KEY_F10")
        steps.append({"step": "config_add_and_trigger", "reply": reply, "readback": readback,
                      "fired": fired("config")})

        os.unlink(marker("config")) if os.path.exists(marker("config")) else None
        reply = c.call("wayfire/set-config-options", {"command/bindings": {}})
        time.sleep(0.3)
        readback = c.call("wayfire/get-config-option", {"option": "command/bindings"})
        wfipc.press(c, "KEY_LEFTMETA", "KEY_F10")
        steps.append({"step": "config_remove_and_trigger", "reply": reply, "readback": readback,
                      "fired": fired("config")})

        # 5. Is there any way to list IPC-registered bindings?
        steps.append({"step": "list_method_probe",
                      "command/list-bindings": c.call("command/list-bindings", {})})
    except Exception as error:
        steps.append({"step": "exception", "error": repr(error)})
        ok = False
    finally:
        common.stop_children()

    json.dump({"row": "C-16", "probe": "global key binding add/remove", "steps": steps,
               "completed": ok}, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
