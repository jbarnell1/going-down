"""Paint the Playroom's four wall murals (PR1, 21 Nov 2026): original, simple nursery pictures in the floor's
faded primaries, worn through in places, drawn above the padding on the white walls.

Run with Python, Pillow and numpy:  python -I assets_src/playroom_murals.py
Writes godot/assets/playroom/murals.png: 1024 x 512, four murals of 512 x 256 (sun and hills, balloons, the sea,
night houses). Transparent where the wall shows. Nothing random beyond a fixed seed. No characters.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parents[1] / "godot/assets/playroom/murals.png"
W, H = 512, 256
RED = (209, 92, 82)
YELLOW = (235, 199, 92)
BLUE = (92, 140, 204)
GREEN = (115, 184, 115)
WHITE = (240, 238, 228)
DARK = (60, 62, 78)


def panel(i: int) -> Image.Image:
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if i == 0:  # a sun with rays over rolling hills, a rainbow
        for k, c in enumerate((RED, YELLOW, GREEN, BLUE)):
            r = 200 - k * 18
            d.arc((300 - r, 230 - r, 300 + r, 230 + r), 180, 360, fill=c + (255,), width=17)
        d.ellipse((40, 30, 120, 110), fill=YELLOW + (255,))
        for a in range(0, 360, 30):
            t = np.radians(a)
            d.line((80 + 50 * np.cos(t), 70 + 50 * np.sin(t), 80 + 68 * np.cos(t), 70 + 68 * np.sin(t)), fill=YELLOW + (255,), width=6)
        d.ellipse((-80, 170, 260, 380), fill=GREEN + (255,))
        d.ellipse((180, 190, 600, 420), fill=(95, 160, 100, 255))
    elif i == 1:  # hot-air balloons and clouds
        for (x, y, c, s) in ((90, 60, RED, 1.0), (260, 100, BLUE, 0.8), (410, 50, YELLOW, 1.1)):
            r = 42 * s
            d.ellipse((x - r, y - r, x + r, y + r * 1.15), fill=c + (255,))
            d.line((x - r * 0.6, y + r * 1.05, x - r * 0.25, y + r * 1.9), fill=DARK + (255,), width=2)
            d.line((x + r * 0.6, y + r * 1.05, x + r * 0.25, y + r * 1.9), fill=DARK + (255,), width=2)
            d.rectangle((x - r * 0.28, y + r * 1.9, x + r * 0.28, y + r * 2.3), fill=(150, 100, 60, 255))
        for (x, y) in ((40, 200), (200, 210), (350, 190), (470, 215)):
            for dx, dy, rr in ((0, 0, 26), (24, -10, 30), (50, 0, 24)):
                d.ellipse((x + dx - rr, y + dy - rr, x + dx + rr, y + dy + rr), fill=(196, 208, 226, 255))
    elif i == 2:  # the sea: waves, fish, a little boat
        for row in range(3):
            y = 150 + row * 34
            pts = [(x, y + 10 * np.sin(x / 26 + row)) for x in range(0, W + 8, 8)] + [(W, H), (0, H)]
            d.polygon(pts, fill=(BLUE[0] - row * 12, BLUE[1] - row * 12, BLUE[2] - row * 8, 255))
        for (x, y, c) in ((90, 200, YELLOW), (250, 225, RED), (400, 195, GREEN)):
            d.ellipse((x - 26, y - 13, x + 18, y + 13), fill=c + (255,))
            d.polygon(((x + 14, y), (x + 34, y - 14), (x + 34, y + 14)), fill=c + (255,))
            d.ellipse((x - 16, y - 5, x - 10, y + 1), fill=DARK + (255,))
        d.polygon(((300, 140), (400, 140), (380, 165), (320, 165)), fill=RED + (255,))
        d.line((350, 140, 350, 70), fill=DARK + (255,), width=4)
        d.polygon(((354, 74), (354, 134), (398, 134)), fill=YELLOW + (255,))
    else:  # night: a moon, stars, little houses with lit windows
        d.ellipse((60, 30, 130, 100), fill=YELLOW + (255,))
        d.ellipse((85, 22, 150, 90), fill=(0, 0, 0, 0))
        rng = np.random.default_rng(7)
        for _ in range(22):
            x, y = rng.integers(160, 500), rng.integers(15, 130)
            r = int(rng.integers(3, 7))
            d.polygon([(x, y - r * 2), (x + r, y), (x, y + r * 2), (x - r, y)], fill=YELLOW + (255,))
        for k, (x, c) in enumerate(((30, RED), (150, BLUE), (270, GREEN), (390, RED))):
            top = 160 + (k % 2) * 12
            d.rectangle((x, top, x + 90, 256), fill=c + (255,))
            d.polygon(((x - 10, top), (x + 45, top - 40), (x + 100, top)), fill=DARK + (255,))
            d.rectangle((x + 18, top + 22, x + 40, top + 44), fill=YELLOW + (255,))
            d.rectangle((x + 54, top + 22, x + 76, top + 44), fill=YELLOW + (255,))
    return im


def wear(im: Image.Image, seed: int) -> Image.Image:
    """Faded toward the wall's off-white, and worn through: soft holes where the paint has gone."""
    a = np.asarray(im, dtype=np.float64)
    rgb = a[..., :3]
    grey = rgb.mean(axis=2, keepdims=True)
    rgb = grey + (rgb - grey) * 0.65
    rgb = rgb * 0.75 + np.array(WHITE) * 0.25
    rng = np.random.default_rng(seed)
    noise = Image.fromarray((rng.random((H // 24, W // 24)) * 255).astype(np.uint8)).resize((W, H), Image.Resampling.BICUBIC)
    noise = noise.filter(ImageFilter.GaussianBlur(3))
    n = np.asarray(noise, dtype=np.float64) / 255.0
    fine = rng.random((H, W))
    alpha = a[..., 3] * np.clip((n - 0.22) * 5.0, 0.0, 1.0) * np.where(fine < 0.015, 0.0, 1.0) * 0.9
    out = np.dstack([np.clip(rgb, 0, 255), alpha]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def main() -> None:
    sheet = Image.new("RGBA", (W * 2, H * 2), (0, 0, 0, 0))
    for i in range(4):
        sheet.paste(wear(panel(i), 100 + i), ((i % 2) * W, (i // 2) * H))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(OUT, optimize=True)
    print(f"{OUT.name} {sheet.size[0]}x{sheet.size[1]} {OUT.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
