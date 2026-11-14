"""Generates Rewind's app icons and launch images into Resources/.

Run: python3 tools/make_art.py   (needs Pillow)
"""
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources")
RED_TOP = (240, 52, 40)
RED_BOTTOM = (186, 18, 18)
DARK = (22, 22, 24)


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size), top)
    px = img.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(size):
            px[x, y] = c
    return img


def draw_rewind(draw, cx, cy, w, color):
    """Two left-pointing triangles (the rewind glyph) with a bar, centred on cx, cy."""
    h = w * 0.62
    tri = w * 0.42
    bar = w * 0.1
    left = cx - w / 2
    # bar
    draw.rounded_rectangle([left, cy - h / 2, left + bar, cy + h / 2], radius=bar * 0.3, fill=color)
    x0 = left + bar + w * 0.04
    for i in range(2):
        tip = x0 + i * tri
        draw.polygon([(tip, cy), (tip + tri, cy - h / 2), (tip + tri, cy + h / 2)], fill=color)


def icon(size):
    scale = 4
    big = size * scale
    img = gradient(big, RED_TOP, RED_BOTTOM)
    d = ImageDraw.Draw(img)
    # soft rounded "screen" like an old TV
    m = big * 0.18
    d.rounded_rectangle([m, big * 0.24, big - m, big * 0.76], radius=big * 0.09, fill=(255, 255, 255))
    draw_rewind(d, big / 2, big / 2, big * 0.38, RED_BOTTOM)
    return img.resize((size, size), Image.LANCZOS)


def launch(w, h):
    img = Image.new("RGB", (w, h), DARK)
    s = int(min(w, h) * 0.22)
    ic = icon(s)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * 0.22), fill=255)
    img.paste(ic, ((w - s) // 2, (h - s) // 2), mask)
    return img


def main():
    icons = {
        "AppIcon60x60@2x.png": 120, "AppIcon60x60@3x.png": 180,
        "AppIcon76x76~ipad.png": 76, "AppIcon76x76@2x~ipad.png": 152,
        "AppIcon83.5x83.5@2x~ipad.png": 167,
        "AppIcon40x40@2x.png": 80, "AppIcon40x40@3x.png": 120,
        "AppIcon40x40~ipad.png": 40, "AppIcon40x40@2x~ipad.png": 80,
        "AppIcon29x29@2x.png": 58, "AppIcon29x29@3x.png": 87,
        "AppIcon29x29~ipad.png": 29, "AppIcon29x29@2x~ipad.png": 58,
    }
    for name, size in icons.items():
        icon(size).save(os.path.join(OUT, name))
    icon(1024).save(os.path.join(ROOT, "icon-1024.png"))

    launches = {
        "Default-568h@2x.png": (640, 1136),
        "Default-667h@2x.png": (750, 1334),
        "Default-736h@3x.png": (1242, 2208),
        "Default-Portrait~ipad.png": (768, 1024),
        "Default-Portrait@2x~ipad.png": (1536, 2048),
        "Default-Landscape~ipad.png": (1024, 768),
        "Default-Landscape@2x~ipad.png": (2048, 1536),
    }
    for name, (w, h) in launches.items():
        launch(w, h).save(os.path.join(OUT, name), optimize=True)
    print("art written to", OUT)


if __name__ == "__main__":
    main()
