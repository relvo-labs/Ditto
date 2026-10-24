#!/usr/bin/env python3
"""Launcher capture sizes and raster icon sharpness (#188).

    check_launcher_icons.py <evidence-dir> <capture-log> [<capture-log> ...]

Reads the LAUNCHER_META lines that capture/tst_launcher_grid_capture.qml
prints (once at scale 1, once with QT_SCALE_FACTOR=2) and checks, per capture:

1. The PNG in the evidence directory has the device size the scene reports
   (1280 x 800 at 1x, 2560 x 1600 at 2x).
2. The icon was requested at device pixels: sourceSize = ceil(display x ratio).
3. A load error shows the lettered fallback, not the image.
4. For the absolute-path raster PNG: the icon's device pixels, inside the
   opaque square of the fixture, against a Lanczos raster of the same file
   at the same device size. Mean channel error and edge energy (FIND_EDGES
   mean, capture / reference) are bounded.

The bounds sit between measured values. Measured before the fix at 2x
(sourceSize = display size, the PNG decoded at 48 or 24 px and stretched):
grid error 0.125 / edge ratio 0.52, search 0.111 / 0.30. Measured with
device-pixel decoding: grid 0.023 (1x) and 0.028 / 0.88 (2x), search 0.022
(1x) and 0.023 / 1.03 (2x). Offscreen software rendering: development
evidence, not a reference machine.

Writes <evidence-dir>/launcher-icons.json and exits 1 on any failure.
"""
import json
import math
import os
import sys

from PIL import Image, ImageChops, ImageFilter, ImageStat

MAX_MEAN_ERROR = 0.06
MIN_EDGE_RATIO = 0.75
MAX_EDGE_RATIO = 1.25
# Only the fixture's opaque square counts, never its rounded corners.
INSET = 0.18
IMAGE_ERROR = 3  # Image.Error


def metas(logs):
    rows = []
    for log in logs:
        with open(log, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if "LAUNCHER_META " in line:
                    rows.append(json.loads(line.split("LAUNCHER_META ", 1)[1]))
    return rows


def edge_energy(image):
    return ImageStat.Stat(image.convert("L").filter(ImageFilter.FIND_EDGES)).mean[0]


def raster_check(capture, meta):
    ratio = meta["device_pixel_ratio"]
    x, y, width, height = meta["icon_rect"]
    size = round(width * ratio)
    left, top = round(x * ratio), round(y * ratio)
    crop = capture.crop((left, top, left + size, top + round(height * ratio)))
    reference = Image.open(meta["icon_file"]).convert("RGBA").resize((size, size), Image.LANCZOS).convert("RGB")
    inset = round(size * INSET)
    box = (inset, inset, size - inset, size - inset)
    crop, reference = crop.crop(box), reference.crop(box)
    error = sum(ImageStat.Stat(ImageChops.difference(crop, reference)).mean) / 3 / 255
    edges = edge_energy(crop) / max(edge_energy(reference), 1e-9)
    return {"device_size": size, "mean_error": round(error, 4), "edge_ratio": round(edges, 3)}


def main():
    evidence, logs = sys.argv[1], sys.argv[2:]
    rows = metas(logs)
    results, failures = [], []
    ratios = sorted({row["device_pixel_ratio"] for row in rows})
    if ratios != [1, 2]:
        failures.append(f"expected captures at 1x and 2x, got {ratios}")
    for meta in rows:
        name = meta["capture"]
        result = {"capture": name, "provider": meta.get("provider"), "ratio": meta["device_pixel_ratio"]}
        path = os.path.join(evidence, name)
        if not os.path.isfile(path):
            failures.append(f"{name}: missing PNG")
            results.append(result)
            continue
        capture = Image.open(path).convert("RGB")
        result["png_size"] = list(capture.size)
        if list(capture.size) != meta["capture_size"]:
            failures.append(f"{name}: PNG is {capture.size}, scene reports {meta['capture_size']}")
        expected = math.ceil(meta["display_size"] * meta["device_pixel_ratio"])
        if meta["source_size"] != [expected, expected]:
            failures.append(f"{name}: sourceSize {meta['source_size']}, expected {[expected, expected]}")
        if "load-error" in name and not (meta["fallback"] and meta["icon_status"] == IMAGE_ERROR):
            failures.append(f"{name}: load error without the lettered fallback")
        if meta.get("icon_file"):
            result.update(raster_check(capture, meta))
            if result["mean_error"] > MAX_MEAN_ERROR:
                failures.append(f"{name}: raster icon mean error {result['mean_error']} > {MAX_MEAN_ERROR}")
            if not MIN_EDGE_RATIO <= result["edge_ratio"] <= MAX_EDGE_RATIO:
                failures.append(f"{name}: raster icon edge ratio {result['edge_ratio']} outside "
                                f"[{MIN_EDGE_RATIO}, {MAX_EDGE_RATIO}]")
        results.append(result)
    report = {"max_mean_error": MAX_MEAN_ERROR, "edge_ratio_bounds": [MIN_EDGE_RATIO, MAX_EDGE_RATIO],
              "captures": results, "failures": failures}
    with open(os.path.join(evidence, "launcher-icons.json"), "w", encoding="utf-8") as out:
        json.dump(report, out, indent=2)
        out.write("\n")
    for result in results:
        print(json.dumps(result))
    for failure in failures:
        print("FAIL " + failure)
    print(f"launcher captures: {len(results)}, failures: {len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
