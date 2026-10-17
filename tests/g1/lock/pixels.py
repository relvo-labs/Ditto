#!/usr/bin/env python3
"""Fail closed on missing/truncated P6 captures; inspect every pixel."""
import re
import sys


def fraction(data, colour="00ff00"):
    header = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255(?:\r\n|\n| )", data)
    if not header:
        raise ValueError("not a supported P6 capture")
    width, height = int(header[1]), int(header[2])
    pixels = data[header.end():]
    if not width or not height or len(pixels) != width * height * 3:
        raise ValueError("incomplete P6 capture")
    target = bytes.fromhex(colour)
    return sum(pixels[i:i + 3] == target for i in range(0, len(pixels), 3)) / (width * height)


if __name__ == "__main__":
    try:
        print(fraction(sys.stdin.buffer.read()))
    except ValueError as error:
        print(f"capture unavailable: {error}", file=sys.stderr)
        raise SystemExit(3)
