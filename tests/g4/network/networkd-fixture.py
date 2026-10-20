#!/usr/bin/env python3
"""Private test-bus networkd. Never changes a real interface or route."""
import pathlib
import socket
import subprocess
import sys
import os
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

from gi.repository import Gio, GLib

ROOT = "/org/freedesktop/network1"
LINK = ROOT + "/link/_2"
XML = """<node>
<interface name="org.freedesktop.network1.Manager">
  <method name="ListLinks"><arg type="a(iso)" direction="out"/></method>
</interface>
<interface name="org.freedesktop.network1.Link">
  <property name="AdministrativeState" type="s" access="read"/>
  <property name="OperationalState" type="s" access="read"/>
  <property name="AddressState" type="s" access="read"/>
</interface>
</node>"""

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
info = Gio.DBusNodeInfo.new_for_xml(XML)
# The helper uses Qt's interface type lookup, so use an existing Ethernet
# index. Only the synthetic networkd properties claim that it is configured.
index = next(i for i, name in socket.if_nameindex()
             if pathlib.Path("/sys/class/net", name, "type").read_text().strip() == "1")
state = {"AdministrativeState": "configured", "OperationalState": "routable", "AddressState": "routable"}
failed = False
pending = []
readbacks = 0


def method(connection, sender, path, interface, name, params, invocation):
    if name == "ListLinks":
        if failed == "timeout":
            pending.append(invocation)  # Deliberately no response; exercise Qt's deadline.
        elif failed:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.AccessDenied", "Synthetic read refusal")
        else:
            invocation.return_value(GLib.Variant("(a(iso))", ([(index, "enp0s1", LINK)],)))


def prop(connection, sender, path, interface, name):
    global readbacks
    if name == "AddressState":
        readbacks += 1
    return GLib.Variant("s", state[name])


loop = GLib.MainLoop()
exit_code = 1
started = False


def finished(pid, status):
    global exit_code
    exit_code = os.waitstatus_to_exitcode(status)
    loop.quit()


def acquired(*args):
    global started
    if not started:
        started = True
        child = subprocess.Popen(sys.argv[1:])
        GLib.child_watch_add(child.pid, finished)


def action(name):
    global failed, owner
    failed = "timeout" if name == "timeout" else name == "fail"
    state.update(AdministrativeState="configured", OperationalState="routable", AddressState="routable")
    if name == "offline":
        state.update(OperationalState="no-carrier", AddressState="off")
    elif name == "unknown":
        state.update(OperationalState="unknown", AddressState="unknown")
    elif name == "unmanaged":
        state.update(AdministrativeState="unmanaged")
    elif name == "link-local":
        state.update(AddressState="degraded")
    elif name == "service-down":
        Gio.bus_unown_name(owner)
        owner = None
    elif owner is None:
        owner = Gio.bus_own_name_on_connection(bus, "org.freedesktop.network1",
                                               Gio.BusNameOwnerFlags.NONE, acquired, None)
    bus.emit_signal(None, LINK, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    GLib.Variant("(sa{sv}as)", ("org.freedesktop.network1.Link", {}, list(state))))
    return GLib.SOURCE_REMOVE


class Control(BaseHTTPRequestHandler):
    # Ephemeral loopback test control; no provider payloads or request logging.
    def log_message(self, *args):
        pass

    def do_GET(self):
        name = self.path.removeprefix("/")
        if name == "readbacks":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(str(readbacks).encode())
            return
        if name not in {"refresh", "reset", "offline", "unknown", "unmanaged", "link-local", "fail", "timeout", "service-down"}:
            self.send_error(404)
            return
        GLib.idle_add(action, name)
        self.send_response(200)
        self.end_headers()


control = HTTPServer(("127.0.0.1", 0), Control)
endpoint = "http://127.0.0.1:" + str(control.server_port)
pathlib.Path(__file__).parent.joinpath("../visual/.staged/network-fixture.js").write_text(
    ".pragma library\nvar endpoint = " + json.dumps(endpoint) + ";\n")
threading.Thread(target=control.serve_forever, daemon=True).start()


bus.register_object(ROOT, info.interfaces[0], method, None, None)
bus.register_object(LINK, info.interfaces[1], None, prop, None)
owner = Gio.bus_own_name_on_connection(bus, "org.freedesktop.network1", Gio.BusNameOwnerFlags.NONE,
                                      acquired, None)
loop.run()
control.shutdown()
sys.exit(exit_code)
