#!/usr/bin/env python3
"""#116 static check of the Wayfire decoration and foot styles.

packaging/reference-image/session/styles/<j1|j2|j3>/ hold each style's
[decoration] section and foot.ini; the installed session uses J1 (owner
2026-10-20: three selectable styles, J1 by default). This checks, without a
session:

- session/wayfire.ini's [decoration] equals styles/j1's, and
  session/xdg/foot/foot.ini is styles/j1/foot.ini;
- every decoration uses only options of the frozen Wayfire 0.11 `decoration`
  plugin, and its one font colour is >=4.5:1 on the active and the inactive
  title bar, composited over white and over black (the bars may be
  translucent);
- every foot.ini asks for Wayfire's title bar only ([csd] preferred=server:
  no second, client-drawn title bar), its foreground, 16 colours and URLs are
  >=4.5:1 on its background, selected text >=4.5:1 on the selection, the
  cursor >=3:1;
- the three styles differ (foot background, title bar colour).

    check-styles.py [--json <out>]

Exit 0 when everything holds; 1 with the failures listed otherwise.
Development check: it does not show what a real Wayfire or foot draws.
"""
import configparser
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SESSION = os.path.join(ROOT, "packaging", "reference-image", "session")
STYLES = ["j1", "j2", "j3"]
# decoration.xml of the frozen Wayfire 0.11 prefix.
DECORATION_OPTIONS = {"font", "font_color", "font_scale", "title_height", "border_size", "button_order",
                      "button_scale", "button_padding", "active_color", "inactive_color",
                      "ignore_views", "forced_views"}


def read_ini(path):
    parser = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=None, strict=False)
    parser.optionxform = str
    with open(path, encoding="utf-8") as handle:
        parser.read_file(handle)
    return parser


def rgba(text):
    """#rrggbb[aa] (Wayfire) or rrggbb / aarrggbb (foot) to ((r, g, b), a)."""
    value = text.strip().lstrip("#")
    if len(value) == 6:
        return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4)), 1.0
    raise ValueError(text)


def wayfire_rgba(text):
    value = text.strip().lstrip("#")
    if len(value) == 8:
        return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4)), int(value[6:8], 16) / 255
    return rgba(value)


def over(colour, alpha, backdrop):
    return tuple(round(c * alpha + b * (1 - alpha)) for c, b in zip(colour, backdrop))


def channel(v):
    v /= 255
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def luminance(c):
    return 0.2126 * channel(c[0]) + 0.7152 * channel(c[1]) + 0.0722 * channel(c[2])


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def main():
    failures, report = [], {"styles": {}}

    def need(condition, message):
        if not condition:
            failures.append(message)

    session_ini = read_ini(os.path.join(SESSION, "wayfire.ini"))
    j1_deco = read_ini(os.path.join(SESSION, "styles", "j1", "wayfire-decoration.ini"))
    need(session_ini.has_section("decoration"), "session wayfire.ini has no [decoration]")
    if session_ini.has_section("decoration"):
        need(dict(session_ini["decoration"]) == dict(j1_deco["decoration"]),
             "session wayfire.ini [decoration] differs from styles/j1")
    session_foot = os.path.join(SESSION, "xdg", "foot", "foot.ini")
    need(os.path.realpath(session_foot) == os.path.realpath(os.path.join(SESSION, "styles", "j1", "foot.ini")),
         "session/xdg/foot/foot.ini is not styles/j1/foot.ini")

    backgrounds, bars = set(), set()
    for style in STYLES:
        entry = {}
        deco = read_ini(os.path.join(SESSION, "styles", style, "wayfire-decoration.ini"))["decoration"]
        unknown = set(deco) - DECORATION_OPTIONS
        need(not unknown, f"{style}: decoration options Wayfire 0.11 does not have: {sorted(unknown)}")
        font, _ = wayfire_rgba(deco["font_color"])
        worst = None
        for bar in ("active_color", "inactive_color"):
            colour, alpha = wayfire_rgba(deco[bar])
            for backdrop in ((255, 255, 255), (0, 0, 0)):
                value = ratio(font, over(colour, alpha, backdrop))
                worst = value if worst is None else min(worst, value)
        entry["title_text_min_ratio"] = round(worst, 2)
        need(worst >= 4.5, f"{style}: title text {worst:.2f}:1 (<4.5)")
        bars.add(deco["active_color"].lower())

        foot = read_ini(os.path.join(SESSION, "styles", style, "foot.ini"))
        need(foot.get("csd", "preferred", fallback="") == "server",
             f"{style}: foot.ini must ask for Wayfire's title bar only ([csd] preferred=server)")
        colors = foot["colors"]
        background, _ = rgba(colors["background"])
        backgrounds.add(colors["background"].lower())
        names = ["foreground", "urls"] + [f"regular{i}" for i in range(8)] + [f"bright{i}" for i in range(8)]
        lowest = min((ratio(rgba(colors[name])[0], background), name) for name in names)
        entry["text_min_ratio"] = [round(lowest[0], 2), lowest[1]]
        need(lowest[0] >= 4.5, f"{style}: foot {lowest[1]} {lowest[0]:.2f}:1 on the background (<4.5)")
        selection = ratio(rgba(colors["selection-foreground"])[0], rgba(colors["selection-background"])[0])
        entry["selection_ratio"] = round(selection, 2)
        need(selection >= 4.5, f"{style}: selected text {selection:.2f}:1 (<4.5)")
        cursor = foot["cursor"]["color"].split()
        cursor_ratio = ratio(rgba(cursor[1])[0], background)
        entry["cursor_ratio"] = round(cursor_ratio, 2)
        need(cursor_ratio >= 3, f"{style}: cursor {cursor_ratio:.2f}:1 (<3)")
        report["styles"][style] = entry

    need(len(backgrounds) == len(STYLES), "the three foot backgrounds are not distinct")
    need(len(bars) == len(STYLES), "the three title bar colours are not distinct")
    report["failures"] = failures
    if "--json" in sys.argv:
        with open(sys.argv[sys.argv.index("--json") + 1], "w", encoding="utf-8") as out:
            json.dump(report, out, indent=2, ensure_ascii=False)
    for line in failures:
        print("FAIL: " + line)
    print(json.dumps(report["styles"], ensure_ascii=False))
    print("PASS: styles" if not failures else f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
