import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from fake_secret_service import MemoryKeyring, private_address
from private_bus import PrivateBus


class FakeKeyringTests(unittest.TestCase):
    def test_memory_create_lookup_replace_delete_without_persisting_values(self):
        reports = []
        state = MemoryKeyring(reports.append)
        attributes = {'application': 'ditto', 'ditto_credential': 'cred-test'}
        path = state.create(attributes, b'private-first', True)
        self.assertEqual(state.search(attributes), [path])
        from fake_secret_service import SESSION
        self.assertEqual(state.get(path, SESSION), b'private-first')
        self.assertEqual(state.create(attributes, b'private-second', True), path)
        self.assertEqual(state.get(path, SESSION), b'private-second')
        with self.assertRaises(ValueError):
            state.get(path, '/wrong')
        state.delete(path)
        self.assertEqual(state.search(attributes), [])
        with self.assertRaises(ValueError):
            state.create({'application': 'other'}, b'private', True)
        self.assertNotIn('private', json.dumps(reports))
        self.assertEqual(state.counts['GetSecret'], 2)

    def test_bus_isolation_rejects_real_bus_and_multi_address_fallbacks(self):
        with tempfile.TemporaryDirectory() as scratch:
            expected = 'unix:path=' + scratch + '/bus'
            self.assertEqual(private_address(scratch, expected), expected)
            for address in (None, '', 'unix:path=/run/user/1000/bus', expected + ';unix:path=/run/user/1000/bus', expected + ',guid=abc'):
                with self.subTest(address=address), self.assertRaises(ValueError):
                    private_address(scratch, address)
            with patch.dict(os.environ, {'DBUS_SESSION_BUS_ADDRESS': 'user-bus', 'DBUS_STARTER_ADDRESS': 'user-bus'}):
                bus = PrivateBus(scratch, Path(scratch) / 'report', None)
            self.assertEqual(bus.env['DBUS_SESSION_BUS_ADDRESS'], expected)
            self.assertEqual(bus.env['DBUS_STARTER_ADDRESS'], expected)

    def test_actual_dbus_decorators_and_plain_secret_wire_shapes_without_socket(self):
        # Use installed distro dbus-python/GLib, never install into the runner Python.
        result = subprocess.run(['/usr/bin/python3', str(Path(__file__).with_name('keyring_wire_test.py'))],
                                capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
