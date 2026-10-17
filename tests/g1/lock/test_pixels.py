import unittest
from pixels import fraction


class PixelTests(unittest.TestCase):
    def test_one_exposed_pixel_is_detected(self):
        self.assertEqual(fraction(b"P6\n2 1\n255\n\0\xff\0\0\0\0"), .5)
        self.assertEqual(fraction(b"P6\n1 1\n255\n\0\0\0"), 0)

    def test_denied_and_truncated_captures_are_unknown(self):
        for data in (b"", b"P6\n1 1\n255\n", b"P6\n2 1\n255\n\0\xff\0"):
            with self.assertRaises(ValueError):
                fraction(data)


if __name__ == "__main__":
    unittest.main()
