#!/usr/bin/env python3
"""Builds Assets/icon.png (1024x1024 macOS app icon) from Assets/icon-source.png.

The source artwork is a rounded square on a dark backdrop. This finds the square's
edges, cuts it out with transparent corners, and places it on Apple's macOS icon grid
(824 px body inside a 1024 px canvas). Requires Pillow and NumPy.

Usage:  python3 tools/make_icon.py [--radius 0.2] [--source path.png]
"""
import argparse, os
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_body(img, threshold=140):
    """Bounding box of the bright rim along the middle row and column."""
    lum = np.asarray(img.convert("RGB")).astype(int).sum(2)
    h, w = lum.shape
    row, col = lum[h // 2], lum[:, w // 2]
    x0 = int(np.argmax(row > threshold)); x1 = w - int(np.argmax(row[::-1] > threshold))
    y0 = int(np.argmax(col > threshold)); y1 = h - int(np.argmax(col[::-1] > threshold))
    side = max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    return (int(cx - side / 2), int(cy - side / 2), int(cx + side / 2), int(cy + side / 2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=os.path.join(ROOT, "Assets", "icon-source.png"))
    ap.add_argument("--radius", type=float, default=0.245, help="corner radius as a fraction of the side")
    a = ap.parse_args()

    src = Image.open(a.source).convert("RGBA")
    box = find_body(src)
    body = src.crop(box)
    side = body.size[0]

    ss = 4
    mask = Image.new("L", (side * ss, side * ss), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, side * ss - 1, side * ss - 1), radius=int(a.radius * side * ss), fill=255)
    body.putalpha(mask.resize((side, side), Image.LANCZOS))

    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    body = body.resize((824, 824), Image.LANCZOS)
    canvas.alpha_composite(body, (100, 94))
    out = os.path.join(ROOT, "Assets", "icon.png")
    canvas.save(out)
    print(f"cropped {box} from {src.size}, wrote {out}")


if __name__ == "__main__":
    main()
