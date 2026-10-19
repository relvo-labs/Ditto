#!/usr/bin/env python3
"""Compare the recoloured status glyphs with a direct raster (#105 C3).

    check_hidpi.py <evidence-dir> <capture-log> [<capture-log> ...]

Reads the HIDPI_META lines that capture/tst_hidpi_capture.qml prints (once at
scale 1, once with QT_SCALE_FACTOR=2), opens the device-pixel PNGs in
.staged/out/, and for every glyph compares coverage (how much ink each device
pixel holds) between the panel capture and a plain Qt Image raster of the same
SVG at the same device size. Coverage is normalised to each crop's own ink and
background, so tint and the minimum-alpha rule do not count as differences;
softness, a lower-resolution source or a misplaced quarter do.

Writes <evidence-dir>/hidpi.json, copies the PNGs, exits 1 on any failure.
Offscreen software rendering: development evidence, not a reference machine.
"""
import json
import os
import shutil
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", ".staged", "out")
# A sharp device raster matches the direct raster almost exactly; an 18 px
# glyph stretched to 2x or resampled from the 16 px drawing does not.
MAX_MEAN_ERROR = 0.03
MIN_CORE_RATIO = 0.9


def flatten(path):
    image = Image.open(path).convert("RGBA")
    white = Image.new("RGBA", image.size, (255, 255, 255, 255))
    return Image.alpha_composite(white, image).convert("RGB")


def crop(image, glyph, ratio):
    x, y = round(glyph["x"] * ratio), round(glyph["y"] * ratio)
    size = round(glyph["width"] * ratio), round(glyph["height"] * ratio)
    background = image.getpixel((max(0, x - round(3 * ratio)), y + size[1] // 2))
    pixels = [image.getpixel((x + i, y + j)) for j in range(size[1]) for i in range(size[0])]
    return pixels, background


def coverage(pixels, background):
    def lum(p):
        return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]
    base = lum(background)
    darkest = min(lum(p) for p in pixels)
    span = base - darkest
    if span <= 1:
        return [0.0] * len(pixels)
    return [max(0.0, min(1.0, (base - lum(p)) / span)) for p in pixels]


def main():
    evidence, logs = sys.argv[1], sys.argv[2:]
    metas = []
    for log in logs:
        for line in open(log, encoding="utf-8"):
            if "HIDPI_META " in line:
                metas.append(json.loads(line.split("HIDPI_META ", 1)[1]))
    results, failures = [], []
    if not any(meta["device_pixel_ratio"] == 2 for meta in metas):
        failures.append("no 2x capture")
    for meta in metas:
        ratio = meta["device_pixel_ratio"]
        capture = flatten(os.path.join(OUT, meta["capture"]))
        reference = flatten(os.path.join(OUT, meta["reference"]))
        expected = (round(meta["capsule"]["width"] * ratio), round(meta["capsule"]["height"] * ratio))
        size_ok = capture.size == expected
        if not size_ok:
            failures.append(f"{meta['capture']}: {capture.size} != {expected} device pixels")
        for icon in meta["icons"]:
            got, got_bg = crop(capture, icon["glyph"], ratio)
            want, want_bg = crop(reference, icon["reference_glyph"], ratio)
            a, b = coverage(got, got_bg), coverage(want, want_bg)
            ink = [i for i in range(len(b)) if a[i] > 0.02 or b[i] > 0.02]
            error = sum(abs(a[i] - b[i]) for i in ink) / max(1, len(ink))
            core_got, core_want = sum(x > 0.9 for x in a), sum(x > 0.9 for x in b)
            core_ratio = min(core_got, core_want) / max(1, max(core_got, core_want))
            row = {"scene": meta["scene"], "device_pixel_ratio": ratio, "icon": icon["name"], "source": icon["source"],
                   "device_pixels": len(a), "ink_pixels": len(ink), "mean_coverage_error": round(error, 4),
                   "core_pixels_capture": core_got, "core_pixels_reference": core_want, "core_ratio": round(core_ratio, 3),
                   "raised": icon.get("raised"), "capture_size_ok": size_ok}
            results.append(row)
            if error > MAX_MEAN_ERROR or core_ratio < MIN_CORE_RATIO:
                failures.append(f"{meta['capture']} {icon['name']}: error {error:.3f} (max {MAX_MEAN_ERROR}), "
                                f"core {core_got}/{core_want}")
        for name in (meta["capture"], meta["reference"]):
            shutil.copy(os.path.join(OUT, name), os.path.join(evidence, name))
    with open(os.path.join(evidence, "hidpi.json"), "w", encoding="utf-8") as out:
        json.dump({"max_mean_coverage_error": MAX_MEAN_ERROR, "min_core_ratio": MIN_CORE_RATIO,
                   "renderer": "Qt offscreen software; QT_SCALE_FACTOR for 2x",
                   "results": results, "failures": failures}, out, ensure_ascii=False, indent=2)
        out.write("\n")
    for row in results:
        print(f"{row['scene']:14s} {row['device_pixel_ratio']}x {row['icon']:44s} error {row['mean_coverage_error']:.4f} "
              f"core {row['core_pixels_capture']}/{row['core_pixels_reference']}")
    for failure in failures:
        print("FAIL " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
