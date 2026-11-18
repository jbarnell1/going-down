"""Reduce the four licensed Arboretum maps before putting them in the game.

Run with Python and Pillow: python assets_src/arboretum_textures.py DIRECTORY_OF_ZIPS
"""
from io import BytesIO
from pathlib import Path
import sys
from zipfile import ZipFile

from PIL import Image, ImageOps

DESTINATION = Path(__file__).resolve().parents[1] / "godot/assets/arboretum"
MAPS = (
    ("bark_willow_02_4k.blend.zip", "textures/bark_willow_02_diff_4k.jpg", "willow_bark.png", 256, "bark"),
    ("forest_leaves_04_4k.blend.zip", "textures/forest_leaves_04_diff_4k.jpg", "leaf_litter.png", 512, "litter"),
    ("green_metal_rust_4k.blend.zip", "textures/green_metal_rust_diff_4k.jpg", "painted_iron.webp", 256, "paint"),
    ("SurfaceImperfections001_1K-PNG.zip", "SurfaceImperfections001_1K-PNG_Opacity.png", "glass_grime.png", 256, "grime"),
)


def main(archive_dir: Path) -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for archive, member, name, size, role in MAPS:
        with ZipFile(archive_dir / archive) as package:
            with package.open(member) as source:
                with Image.open(BytesIO(source.read())) as image:
                    mode = "RGB" if role == "paint" else "L"
                    reduced = image.convert(mode).resize((size, size), Image.Resampling.LANCZOS)

        if role in ("bark", "litter"):
            # Keep the photographed detail while the game supplies its approved copper and bark hues.
            detail = ImageOps.autocontrast(reduced, cutoff=1)
            reduced = detail.point(lambda value: 102 + value * 0.52)
        elif role == "paint":
            # Retain the green paint and red oxide under a very dark park lamp.
            reduced = reduced.point(lambda value: 65 + value * 0.73)
        if name.endswith(".webp"):
            reduced.save(DESTINATION / name, quality=83, method=6)
        else:
            reduced.save(DESTINATION / name, optimize=True)
        print(f"{name} {size}x{size} {(DESTINATION / name).stat().st_size:,} bytes")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
