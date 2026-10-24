#!/usr/bin/env python3
"""Regenerate raster-icon-256.png, the absolute-path raster icon fixture (#188).

    make-raster-icon.py <output.png>

A 256 x 256 RGBA PNG with thin light and dark lines and a ring, drawn at
1024 px and reduced with Lanczos. The fine lines make a blurred upscale
measurable: capture/check_launcher_icons.py compares the launcher's rendered
icon with a direct raster of this file at the device size. The committed PNG
is the test input; this script records how it was made.
"""
import sys

from PIL import Image, ImageDraw


def main():
    big = 1024
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((64, 64, 960, 960), radius=200, fill=(38, 110, 214, 255))
    for offset in range(160, 880, 48):
        draw.line((160, offset, 864, offset), fill=(250, 250, 255, 255), width=10)
    for offset in range(160, 880, 96):
        draw.line((offset, 160, offset, 864), fill=(20, 24, 40, 255), width=10)
    draw.ellipse((400, 400, 624, 624), outline=(255, 200, 40, 255), width=24)
    image.resize((256, 256), Image.LANCZOS).save(sys.argv[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
