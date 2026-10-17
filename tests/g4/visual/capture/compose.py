#!/usr/bin/env python3
"""Side-by-side, overlay and per-element samples: reference vs native capture.

Needs Pillow (the system python3 here has it). Inputs: the reference image,
the PNGs from tst_capture.qml and its CAPTURE_META log lines. Outputs go to
the evidence directory given as the first argument; PNGs are evidence only
and are not committed.

The per-element numbers are mean colours of small patches at the same
coordinates in both images, a coarse check. The reference is a JPEG, so its
numbers are compression-affected samples, not the design's exact values.
"""
import json
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
REFERENCE = os.path.join(ROOT, "docs/design/default-desktop/reference/owner-desktop-reference.jpg")

# (element, x, y, w, h): patches at the same place in both images.
PATCHES = [
    ("canvas top-middle", 300, 40, 8, 8),
    ("canvas left-bottom", 16, 756, 8, 8),
    ("canvas bottom-middle", 300, 776, 8, 8),
    ("canvas top-right", 1000, 60, 8, 8),
    ("canvas right-middle", 1240, 420, 8, 8),
    ("back window/sample body", 400, 250, 8, 8),
    ("front window/sample body", 560, 640, 8, 8),
    ("dock capsule body", 455, 750, 6, 6),
]


def mean(image, x, y, w, h):
    pixels = [image.getpixel((i, j)) for i in range(x, x + w) for j in range(y, y + h)]
    return tuple(round(sum(p[k] for p in pixels) / len(pixels)) for k in range(3))


def hexed(rgb):
    return "#%02x%02x%02x" % rgb


def label(image, text, x=0):
    """A caption strip on the bottom edge, clear of the panel and the Dock centre."""
    draw = ImageDraw.Draw(image)
    y = image.size[1] - 18
    draw.rectangle((x, y, x + 8 + 7 * len(text), y + 18), fill=(255, 255, 255))
    draw.text((x + 4, y + 3), text, fill=(20, 20, 40))


def main():
    out = sys.argv[1]
    log = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    reference = Image.open(REFERENCE).convert("RGB")
    assert reference.size == (1280, 800), reference.size
    metas = [json.loads(line.split("CAPTURE_META ", 1)[1]) for line in open(log, encoding="utf-8")
             if "CAPTURE_META " in line]
    summary = {"reference": REFERENCE, "captures": []}
    for meta in metas:
        capture = Image.open(meta["file"]).convert("RGB")
        assert capture.size == (1280, 800), capture.size
        mode = meta["mode"]
        side = Image.new("RGB", (2560, 800))
        side.paste(reference, (0, 0))
        side.paste(capture, (1280, 0))
        label(side, "reference (owner image, not a Ditto screenshot)")
        label(side, f"native QML capture: {mode} (offscreen, {meta['renderer']})", x=1280)
        side.save(os.path.join(out, f"side-by-side-{mode}.png"))
        overlay = Image.blend(reference, capture, 0.5)
        label(overlay, f"overlay 50/50 reference + {mode}")
        # Outline the captured element boxes on the overlay.
        draw = ImageDraw.Draw(overlay)
        for name, box in meta["geometry"].items():
            draw.rectangle((box["x"], box["y"], box["x"] + box["width"] - 1, box["y"] + box["height"] - 1),
                           outline=(220, 40, 120))
            draw.text((box["x"] + 3, box["y"] + box["height"] - 12), name, fill=(220, 40, 120))
        overlay.save(os.path.join(out, f"overlay-{mode}.png"))
        capture.save(os.path.join(out, f"capture-{mode}.png"))
        samples = []
        for name, x, y, w, h in PATCHES:
            ref, cap = mean(reference, x, y, w, h), mean(capture, x, y, w, h)
            samples.append({"element": name, "patch": [x, y, w, h], "reference": hexed(ref), "capture": hexed(cap),
                            "max_channel_delta": max(abs(a - b) for a, b in zip(ref, cap))})
        summary["captures"].append({"mode": mode, "meta": meta, "samples": samples})
    with open(os.path.join(out, "comparison.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    for capture in summary["captures"]:
        print(f"## {capture['mode']}")
        for sample in capture["samples"]:
            print(f"  {sample['element']:26s} ref {sample['reference']} cap {sample['capture']} Δmax {sample['max_channel_delta']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
