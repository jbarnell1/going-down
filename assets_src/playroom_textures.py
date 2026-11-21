"""Reduce the Playroom's licensed photo maps (Poly Haven and ambientCG, CC0) to the small maps the game ships.

Run with Python, Pillow and numpy:  python -I assets_src/playroom_textures.py DIRECTORY
DIRECTORY holds the 1k colour maps exactly as the libraries serve them, one folder each (see docs/ART-NOTES.md,
the Playroom's rows, and godot/assets/playroom/SOURCES.md):
    playroom-ceiling-tiles/OfficeCeiling001_1K-JPG_Color.jpg   (ambientCG OfficeCeiling001)
    playroom-wall-plaster/painted_plaster_wall_diff_1k.jpg     (Poly Haven painted_plaster_wall)
    playroom-grime/dirty_concrete_diff_1k.jpg                  (Poly Haven dirty_concrete)
Each map is cut to 512 px and its mean colour set. The ceiling is drawn as it is; the plaster and the grime are detail maps
the shader multiplies over a surface, so they are made grey with a mean of 0.5 (the shader doubles them).
"""
from pathlib import Path
import sys

import numpy as np
from PIL import Image

DESTINATION = Path(__file__).resolve().parents[1] / "godot/assets/playroom"
SIZE = 512

# (source file, game file, target mean colour in sRGB 0..1, contrast kept around the mean, saturation kept)
MAPS = (
    ("playroom-ceiling-tiles/OfficeCeiling001_1K-JPG_Color.jpg", "ceiling.webp", (0.80, 0.79, 0.76), 1.0, 0.3),
    ("playroom-wall-plaster/painted_plaster_wall_diff_1k.jpg", "plaster.webp", (0.5, 0.5, 0.5), 1.3, 0.0),
    ("playroom-grime/dirty_concrete_diff_1k.jpg", "grime.webp", (0.5, 0.49, 0.47), 1.4, 0.4),
)


def lum(a: np.ndarray) -> np.ndarray:
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722


def reduce(source: Path, target: tuple, contrast: float, saturation: float) -> Image.Image:
    with Image.open(source) as image:
        small = image.convert("RGB").resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    a = np.asarray(small, dtype=np.float64) / 255.0
    y = lum(a)[..., None]
    grey = np.repeat(y, 3, axis=2)
    a = grey + (a - grey) * saturation
    mean = a.reshape(-1, 3).mean(axis=0)
    a = mean + (a - mean) * contrast
    a = a * (np.array(target) / np.maximum(a.reshape(-1, 3).mean(axis=0), 1e-4))
    return Image.fromarray((np.clip(a, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8), "RGB")


def main(source_dir: Path) -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    total = 0
    for source, name, target, contrast, saturation in MAPS:
        out = reduce(source_dir / source, target, contrast, saturation)
        out.save(DESTINATION / name, quality=80, method=6)
        size = (DESTINATION / name).stat().st_size
        total += size
        print(f"{name} {SIZE}x{SIZE} {size:,} bytes")
    print(f"total {total:,} bytes")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
