#!/usr/bin/python3
"""In-memory Secret Service for a dedicated test bus. Never use a user bus."""
import argparse
import json
import os
from pathlib import Path

SERVICE = '/org/freedesktop/secrets'
COLLECTION = SERVICE + '/aliases/default'
SESSION = SERVICE + '/session/qa04'


def private_address(scratch, address):
    expected = 'unix:path=' + str(Path(scratch).resolve() / 'bus')
    if address != expected:
        raise ValueError('DBUS_SESSION_BUS_ADDRESS must point only to the scratch bus')
    return expected


class MemoryKeyring:
    """Only Ditto attributes, opaque paths and counters may leave this object."""
    def __init__(self, report):
        self.items = {}
        self.counts = {'OpenSession': 0, 'CreateItem': 0, 'SearchItems': 0, 'GetSecret': 0, 'Delete': 0}
        self.report = report

    def record(self, method):
        self.counts[method] += 1
        self.report({'calls': self.counts, 'items': len(self.items)})

    def create(self, attributes, secret, replace):
        if attributes.get('application') != 'ditto' or not attributes.get('ditto_credential', '').startswith('cred-'):
            raise ValueError('only Ditto credential attributes are accepted')
        found = [path for path, item in self.items.items() if item[0] == attributes]
        path = found[0] if replace and found else SERVICE + '/item/' + str(len(self.items) + self.counts['CreateItem'] + 1)
        self.items[path] = (dict(attributes), bytes(secret))
        self.record('CreateItem')
        return path

    def search(self, attributes):
        self.record('SearchItems')
        return [path for path, item in self.items.items() if all(item[0].get(k) == v for k, v in attributes.items())]

    def get(self, path, session):
        if session != SESSION:
            raise ValueError('unknown session')
        value = self.items[path][1]
        self.record('GetSecret')
        return value

    def delete(self, path):
        self.items.pop(path, None)
        self.record('Delete')


def interfaces():
    # System packages already installed on the development/runner host.
    import dbus
    import dbus.service

    class Service(dbus.service.Object):
        @dbus.service.method('org.freedesktop.Secret.Service', in_signature='sv', out_signature='vo')
        def OpenSession(self, algorithm, value):
            if algorithm != 'plain':
                raise ValueError('fixture supports plain sessions only')
            self.state.record('OpenSession')
            return dbus.String('', variant_level=1), dbus.ObjectPath(SESSION)

        @dbus.service.method('org.freedesktop.Secret.Service', in_signature='a{ss}', out_signature='aoao')
        def SearchItems(self, attributes):
            return self.state.search(attributes), []

    class Collection(dbus.service.Object):
        @dbus.service.method('org.freedesktop.DBus.Properties', in_signature='ss', out_signature='v')
        def Get(self, interface, prop):
            if interface != 'org.freedesktop.Secret.Collection' or prop != 'Locked':
                raise ValueError('unknown property')
            return dbus.Boolean(False, variant_level=1)

        @dbus.service.method('org.freedesktop.DBus.Properties', in_signature='s', out_signature='a{sv}')
        def GetAll(self, interface):
            return {'Locked': self.Get(interface, 'Locked')}

        @dbus.service.method('org.freedesktop.Secret.Collection', in_signature='a{sv}(oayays)b', out_signature='oo')
        def CreateItem(self, properties, secret, replace):
            session, parameters, value, content_type = secret
            if session != SESSION or parameters or content_type != 'text/plain':
                raise ValueError('invalid plain secret')
            path = self.state.create(properties['org.freedesktop.Secret.Item.Attributes'], value, replace)
            self.export_item(path)
            return dbus.ObjectPath(path), dbus.ObjectPath('/')

    class Item(dbus.service.Object):
        @dbus.service.method('org.freedesktop.Secret.Item', in_signature='o', out_signature='(oayays)')
        def GetSecret(self, session):
            return (dbus.ObjectPath(session), dbus.ByteArray(b''), dbus.ByteArray(self.state.get(self.item_path, session)), 'text/plain')

        @dbus.service.method('org.freedesktop.Secret.Item', in_signature='', out_signature='o')
        def Delete(self):
            self.state.delete(self.item_path)
            return dbus.ObjectPath('/')

    return Service, Collection, Item


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    address = private_address(args.scratch, os.environ.get('DBUS_SESSION_BUS_ADDRESS'))
    import dbus
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib
    DBusGMainLoop(set_as_default=True)
    bus = dbus.bus.BusConnection(address)
    name = dbus.service.BusName('org.freedesktop.secrets', bus=bus, do_not_queue=True)
    def write_report(value):
        temporary = args.report.with_suffix('.tmp')
        temporary.write_text(json.dumps(value))
        temporary.replace(args.report)

    state = MemoryKeyring(write_report)
    Service, Collection, Item = interfaces()
    service = Service(bus, SERVICE)
    service.state = state
    collection = Collection(bus, COLLECTION)
    collection.state = state
    exported = {}

    def export_item(path):
        if path not in exported:
            item = Item(bus, path)
            item.state, item.item_path = state, path
            exported[path] = item

    collection.export_item = export_item
    # Never include values, labels, attributes, nonce or environment in reports.
    write_report({'ready': True, 'bus_is_private': True})
    GLib.MainLoop().run()


if __name__ == '__main__':
    main()
