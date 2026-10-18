"""Exercise real dbus-python decorated methods without opening any bus/socket."""
import unittest

from fake_secret_service import COLLECTION, SESSION, MemoryKeyring, interfaces


class WireTests(unittest.TestCase):
    def test_product_method_signatures_and_lifecycle(self):
        Service, Collection, Item = interfaces()
        state = MemoryKeyring(lambda _: None)
        service, collection, item = (object.__new__(cls) for cls in (Service, Collection, Item))
        for obj in (service, collection, item):
            obj.state = state
        collection.export_item = lambda path: setattr(item, 'item_path', path)
        methods = [(Service.OpenSession, 'sv', 'vo'), (Service.SearchItems, 'a{ss}', 'aoao'),
                   (Collection.Get, 'ss', 'v'), (Collection.GetAll, 's', 'a{sv}'),
                   (Collection.CreateItem, 'a{sv}(oayays)b', 'oo'),
                   (Item.GetSecret, 'o', '(oayays)'), (Item.Delete, '', 'o')]
        for method, args, result in methods:
            self.assertEqual(method._dbus_in_signature, args)
            self.assertEqual(method._dbus_out_signature, result)
        _, session = service.OpenSession('plain', '')
        self.assertEqual(session, SESSION)
        self.assertFalse(collection.Get('org.freedesktop.Secret.Collection', 'Locked'))
        self.assertEqual(collection.GetAll('org.freedesktop.Secret.Collection'), {'Locked': False})
        attributes = {'application': 'ditto', 'ditto_credential': 'cred-wire'}
        path, prompt = collection.CreateItem({'org.freedesktop.Secret.Item.Attributes': attributes},
                                            (session, b'', b'wire-private', 'text/plain'), True)
        self.assertEqual(prompt, '/')
        self.assertEqual(service.SearchItems(attributes), ([path], []))
        self.assertEqual(bytes(item.GetSecret(session)[2]), b'wire-private')
        self.assertEqual(item.Delete(), '/')
        self.assertEqual(service.SearchItems(attributes), ([], []))
        with self.assertRaises(ValueError):
            service.OpenSession('encrypted', '')
        with self.assertRaises(ValueError):
            collection.Get('wrong', 'Locked')
        with self.assertRaises(ValueError):
            collection.CreateItem({}, ('/wrong', b'', b'private', 'text/plain'), True)
        self.assertEqual(COLLECTION, '/org/freedesktop/secrets/aliases/default')


if __name__ == '__main__':
    unittest.main()
