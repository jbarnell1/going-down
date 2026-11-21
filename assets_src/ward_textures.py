"""Reduce the Hanging Ward's CC0 photo maps (Poly Haven) before putting them in the game (AW1).

Fetch each source's 1k colour map (an image file, nothing else) into an empty folder, for example
assets_src/inbox/ward/ (git-ignored):
    https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/<id>/<id>_diff_1k.jpg
then run with Python and Pillow:
    python -I assets_src/ward_textures.py assets_src/inbox/ward

Every source is CC0 (polyhaven.com/license); the list with its page is in godot/assets/ward/surfaces/SOURCES.md and
docs/ART-NOTES.md. Grey maps take their colour from the Ward's shader tints (client/ward/skin.gd), so one picture
serves several surfaces. Godot makes the mipmaps on import.
"""
from pathlib import Path
import sys

from PIL import Image, ImageOps

DESTINATION = Path(__file__).resolve().parents[1] / "godot/assets/ward/surfaces"
# (source id, game file, size, mode, (contrast floor, contrast range)): grey maps are levelled to floor + v * range.
MAPS = (
    ("red_brick_03", "brick.webp", 512, "RGB", None),
    ("white_plaster_rough_02", "plaster.webp", 512, "L", (120, 0.5)),
    ("weathered_planks", "planks.webp", 512, "L", (70, 0.75)),
    ("wood_floor_worn", "floorboards.webp", 512, "L", (80, 0.7)),
    ("roof_slates_02", "slates.webp", 512, "L", (60, 0.8)),
    ("rock_wall_10", "rock.webp", 512, "L", (50, 0.8)),
    ("rusty_metal_02", "iron.webp", 256, "RGB", None),
    ("wood_cabinet_worn_long", "doorwood.webp", 256, "RGB", None),
    ("decrepit_wallpaper", "paper.webp", 256, "L", (120, 0.55)),
)


def main(source_dir: Path) -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    total = 0
    for ident, name, size, mode, level in MAPS:
        with Image.open(source_dir / f"{ident}_diff_1k.jpg") as image:
            reduced = image.convert(mode).resize((size, size), Image.Resampling.LANCZOS)
        if level is not None:
            floor, span = level
            reduced = ImageOps.autocontrast(reduced, cutoff=1).point(lambda v, f=floor, s=span: int(f + v * s))
        elif ident == "rusty_metal_02":
            # Dark iron with its rust: the photograph is a pale sheet; the Ward's iron is near black.
            reduced = reduced.point(lambda v: int(25 + v * 0.55))
        target = DESTINATION / name
        reduced.save(target, quality=80, method=6)
        total += target.stat().st_size
        print(f"{name} {size}x{size} {mode} {target.stat().st_size:,} bytes")
    print(f"total {total:,} bytes")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
