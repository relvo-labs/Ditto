#!/usr/bin/env python3
"""Build-time hit mask for the avatar layer.

The avatar is mostly transparent. Without a mask its window would swallow
clicks meant for the application underneath, so the opaque area is turned into
a small set of rectangles here, once, instead of being computed per frame.
The output is normalised to 0..1 so the shell can scale it to any avatar size.
"""

import argparse
import json
import struct
import zlib
from pathlib import Path


def read_rgba(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path} is not a PNG")
    offset = 8
    header = None
    pixels = bytearray()
    while offset < len(data):
        (length,) = struct.unpack(">I", data[offset : offset + 4])
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            pixels += payload
        elif kind == b"IEND":
            break
    if header is None:
        raise SystemExit("PNG has no header chunk")
    width, height, depth, colour, compression, filtering, interlace = header
    if (depth, colour, interlace) != (8, 6, 0):
        raise SystemExit("only 8-bit RGBA PNGs without interlacing are supported")
    raw = zlib.decompress(bytes(pixels))
    stride = width * 4
    out = bytearray(height * stride)
    previous = bytearray(stride)
    position = 0
    for row in range(height):
        method = raw[position]
        position += 1
        line = bytearray(raw[position : position + stride])
        position += stride
        for index in range(stride):
            left = line[index - 4] if index >= 4 else 0
            up = previous[index]
            up_left = previous[index - 4] if index >= 4 else 0
            if method == 1:
                line[index] = (line[index] + left) & 0xFF
            elif method == 2:
                line[index] = (line[index] + up) & 0xFF
            elif method == 3:
                line[index] = (line[index] + (left + up) // 2) & 0xFF
            elif method == 4:
                estimate = left + up - up_left
                distances = (
                    abs(estimate - left),
                    abs(estimate - up),
                    abs(estimate - up_left),
                )
                nearest = (left, up, up_left)[distances.index(min(distances))]
                line[index] = (line[index] + nearest) & 0xFF
            elif method != 0:
                raise SystemExit(f"unsupported PNG filter {method}")
        out[row * stride : (row + 1) * stride] = line
        previous = line
    return width, height, bytes(out)


def mask(width: int, height: int, pixels: bytes, cells: int, threshold: float) -> list[dict]:
    cell_w = width / cells
    cell_h = height / cells
    rectangles: list[dict] = []
    for row in range(cells):
        run_start = None
        for column in range(cells + 1):
            opaque = False
            if column < cells:
                total = 0
                samples = 0
                for y in range(int(row * cell_h), int((row + 1) * cell_h), 4):
                    for x in range(int(column * cell_w), int((column + 1) * cell_w), 4):
                        total += pixels[(y * width + x) * 4 + 3]
                        samples += 1
                opaque = samples > 0 and (total / samples) / 255 >= threshold
            if opaque and run_start is None:
                run_start = column
            elif not opaque and run_start is not None:
                rectangles.append(
                    {
                        "x": round(run_start / cells, 4),
                        "y": round(row / cells, 4),
                        "width": round((column - run_start) / cells, 4),
                        "height": round(1 / cells, 4),
                    }
                )
                run_start = None
    return rectangles


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cells", type=int, default=32)
    parser.add_argument("--threshold", type=float, default=0.25)
    parser.add_argument("--check", action="store_true", help="fail if the output is stale")
    arguments = parser.parse_args()

    width, height, pixels = read_rgba(arguments.source)
    rectangles = mask(width, height, pixels, arguments.cells, arguments.threshold)
    record = {
        "source": str(arguments.source).split("/")[-1],
        "source_size": {"width": width, "height": height},
        "cells": arguments.cells,
        "alpha_threshold": arguments.threshold,
        "note": "Normalised rectangles covering the opaque area; a coarse cover, "
                "so a few transparent pixels near the edge stay clickable by the avatar.",
        "rectangles": rectangles,
    }
    contents = json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if arguments.check:
        current = arguments.output.read_text(encoding="utf-8") if arguments.output.exists() else ""
        if current != contents:
            print(f"stale hit mask: {arguments.output}")
            return 1
        return 0
    arguments.output.write_text(contents, encoding="utf-8")
    print(f"{len(rectangles)} rectangles -> {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
