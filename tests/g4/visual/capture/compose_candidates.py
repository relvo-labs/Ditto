#!/usr/bin/env python3
"""#116: comparison sheets of the candidate captures (development evidence).

For every scene captured by tst_apps_candidates.qml: a 2×2 sheet (current,
J1, J2, J3) at half size, and a phone-portrait strip (the four stacked at
640 px wide), each tile labelled. Also writes candidates.json binding every
PNG (sha256) to the capture metadata in the log. Sheets are scaled down
copies; judge legibility from the 1280×800 originals.

    compose_candidates.py <candidates-dir> <capture.log>
"""
import hashlib
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

LABELS = {
    "current": "現行（未設定 DITTO_UI_STYLE）",
    "j1": "J1 果凍玻璃",
    "j2": "J2 軟糖",
    "j3": "J3 泡泡",
}
ORDER = ["current", "j1", "j2", "j3"]


def font(size):
    for path in ("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
                 "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def label(image, text):
    """A small tag in the bottom-left corner (wallpaper there, not a title)."""
    draw = ImageDraw.Draw(image)
    face = font(17)
    box = draw.textbbox((0, 0), text, font=face)
    top = image.height - (box[3] - box[1]) - 26
    draw.rounded_rectangle((6, top, box[2] + 22, image.height - 6), radius=9, fill=(35, 29, 59))
    draw.text((14, top + 4 - box[1]), text, font=face, fill=(255, 255, 255))
    return image


def main():
    directory, log = sys.argv[1:]
    rows = [json.loads(line.split("CANDIDATE_CAPTURE ", 1)[1]) for line in open(log, encoding="utf-8")
            if "CANDIDATE_CAPTURE " in line]
    by_scene = {}
    for row in rows:
        name = os.path.basename(row["file"])
        path = os.path.join(directory, name)
        row["file"] = name
        row["sha256"] = hashlib.sha256(open(path, "rb").read()).hexdigest()
        key = row["scene"] + ("" if row["mode"] == "normal" else "-" + row["mode"])
        by_scene.setdefault(key, {})[row["style"]] = path
    sheets = []
    for scene, files in sorted(by_scene.items()):
        tiles = []
        for style in ORDER:
            if style in files:
                tiles.append(label(Image.open(files[style]).convert("RGB").resize((640, 400), Image.LANCZOS), LABELS[style]))
            else:
                blank = Image.new("RGB", (640, 400), (70, 66, 90))
                tiles.append(label(blank, LABELS[style] + "：此場景不適用"))
        grid = Image.new("RGB", (1280, 800), (255, 255, 255))
        for index, tile in enumerate(tiles):
            grid.paste(tile, ((index % 2) * 640, (index // 2) * 400))
        grid_name = f"sheet-{scene}.png"
        grid.save(os.path.join(directory, grid_name))
        strip = Image.new("RGB", (640, 1600), (255, 255, 255))
        for index, tile in enumerate(tiles):
            strip.paste(tile, (0, index * 400))
        strip_name = f"phone-{scene}.png"
        strip.save(os.path.join(directory, strip_name))
        sheets += [grid_name, strip_name]
    manifest = {"captures": rows, "sheets": sheets,
                "note": "offscreen Qt software renderer with Quickshell stubs; fixtures labelled; development evidence"}
    json.dump(manifest, open(os.path.join(directory, "candidates.json"), "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(f"{len(rows)} captures, {len(sheets)} sheets in {directory}")


if __name__ == "__main__":
    main()
