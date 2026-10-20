#!/usr/bin/env python3
"""#116: WCAG contrast of the candidate text colours on their real backdrops.

Reads the `UI_TOKENS` lines that unit/tst_ui_style.qml prints (the actual
token values per candidate and mode), composites each translucent layer stack
(window canvas → sidebar / card / track / tonal button) over every pixel of
the light recipe's wallpaper, and also over black (any window behind a
translucent window), and reports the minimum ratio per text colour. Fails when
a body-text pair is under 4.5:1 or the focus ring under 3:1.

    ui_contrast.py <unit-tests.log> <wallpaper.jpg> <out.json>
"""
import json
import sys

from PIL import Image


def parse(colour):
    """QML colour text: #rrggbb or #aarrggbb."""
    value = colour.lstrip("#")
    if len(value) == 8:
        a, r, g, b = (int(value[i:i + 2], 16) for i in (0, 2, 4, 6))
        return (r, g, b), a / 255
    r, g, b = (int(value[i:i + 2], 16) for i in (0, 2, 4))
    return (r, g, b), 1.0


def channel(v):
    v /= 255
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def luminance(c):
    return 0.2126 * channel(c[0]) + 0.7152 * channel(c[1]) + 0.0722 * channel(c[2])


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def over(top, alpha, bottom):
    return tuple(top[i] * alpha + bottom[i] * (1 - alpha) for i in range(3))


def main():
    log, wallpaper, out = sys.argv[1:]
    rows = [json.loads(line.split("UI_TOKENS ", 1)[1]) for line in open(log, encoding="utf-8") if "UI_TOKENS " in line]
    if not rows:
        raise SystemExit("no UI_TOKENS lines in " + log)
    image = Image.open(wallpaper).convert("RGB").resize((320, 200))
    backdrops = list(image.get_flattened_data()) + [(0, 0, 0)]
    stacks = {
        "canvas": ["canvas"],
        "sidebar": ["canvas", "sidebar"],
        "card": ["canvas", "card"],
        "track": ["canvas", "card", "track"],
        "tonal-on-canvas": ["canvas", "tonal"],
    }
    texts = {
        "canvas": ["ink", "muted", "accentInk", "warning", "danger"],
        "sidebar": ["ink", "muted"],
        "card": ["ink", "muted", "accentInk", "warning", "danger", "success"],
        "track": ["ink", "muted"],
        "tonal-on-canvas": ["ink", "accentInk"],
    }
    report, failures = [], []
    for row in rows:
        for stack, layers in stacks.items():
            composed = []
            for pixel in backdrops:
                colour = pixel
                for layer in layers:
                    rgb, alpha = parse(row[layer])
                    colour = over(rgb, alpha, colour)
                composed.append(colour)
            for text in texts[stack] + ["focus"]:
                rgb, _ = parse(row[text])
                worst = min(ratio(rgb, c) for c in composed)
                floor = 3.0 if text == "focus" else 4.5
                entry = {"style": row["style"], "mode": row["mode"], "surface": stack, "text": text,
                         "min_ratio": round(worst, 2), "floor": floor}
                report.append(entry)
                if worst < floor:
                    failures.append(entry)
    json.dump({"wallpaper": wallpaper, "backdrops": "every pixel of the 320×200-sampled wallpaper, plus black",
               "rows": report, "failures": failures}, open(out, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    lowest = min(report, key=lambda entry: entry["min_ratio"] / entry["floor"])
    print(f"ui contrast: {len(report)} pairs, {len(failures)} under the floor; lowest {lowest}")
    if failures:
        for entry in failures:
            print("FAIL", json.dumps(entry, ensure_ascii=False))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
