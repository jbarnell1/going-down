"""Reduce the Reactor's licensed photo maps (Poly Haven, CC0) to the small maps the game ships.

Run with Python, Pillow and numpy:  python assets_src/reactor_textures.py DIRECTORY_OF_JPGS
The directory holds the 1k colour maps exactly as Poly Haven serves them (see docs/ART-NOTES.md, the
Reactor's rows, and godot/assets/reactor/SOURCES.md):
    https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/<id>/<id>_diff_1k.jpg
Each map is cut to 512 px, its mean brightness set to the station's old painted greys (so the lit hall keeps
the brightness tests/test_station_look.gd holds it to), its contrast and colour tamed, and saved as WebP.
"""
from pathlib import Path
import sys

import numpy as np
from PIL import Image

DESTINATION = Path(__file__).resolve().parents[1] / "godot/assets/reactor"
SIZE = 512

# (source id, game file, target mean colour in sRGB 0..1, contrast kept around the mean, saturation kept)
MAPS = (
    # Board-marked poured concrete for every wall above the paint.
    ("concrete_slab_wall", "wall_concrete.webp", (0.645, 0.635, 0.605), 0.9, 0.5),
    # Old green paint worn through to the concrete: the dado. Chips kept but quietened (the judge: the old
    # drawn chips "read as bright pixel camouflage").
    ("painted_concrete", "wall_paint.webp", (0.31, 0.47, 0.36), 0.5, 0.75),
    # Worn indoor concrete floor slab.
    ("concrete_floor_worn_001", "floor_concrete.webp", (0.60, 0.59, 0.56), 1.15, 0.4),
    # Stained concrete soffit for the ceiling between the beams.
    ("concrete_wall_006", "ceiling_concrete.webp", (0.53, 0.52, 0.50), 0.9, 0.35),
    # Steel plate: the rotor, its casing, the door frames and the beams.
    ("metal_plate_02", "steel_plate.webp", (0.46, 0.43, 0.40), 1.0, 0.7),
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
    for source_id, name, target, contrast, saturation in MAPS:
        out = reduce(source_dir / f"{source_id}_diff_1k.jpg", target, contrast, saturation)
        out.save(DESTINATION / name, quality=80, method=6)
        size = (DESTINATION / name).stat().st_size
        total += size
        print(f"{name} {SIZE}x{SIZE} {size:,} bytes")
    print(f"total {total:,} bytes")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
