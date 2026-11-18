# Arboretum photographic maps

| Game asset | Source | Import size |
| --- | --- | --- |
| `willow_bark.png` | [Bark Willow 02, Poly Haven](https://polyhaven.com/a/bark_willow_02) | 256 × 256, grayscale |
| `leaf_litter.png` | [Forest Leaves 04, Poly Haven](https://polyhaven.com/a/forest_leaves_04) | 512 × 512, grayscale |
| `painted_iron.webp` | [Green Metal Rust, Poly Haven](https://polyhaven.com/a/green_metal_rust) | 256 × 256, RGB |
| `glass_grime.png` | [Surface Imperfections 001, ambientCG](https://ambientcg.com/view?id=SurfaceImperfections001) | 256 × 256, grayscale |

All four originals are CC0. Run `python assets_src/arboretum_textures.py DIRECTORY_OF_ZIPS`
with Pillow to reproduce the reduced game assets. Godot generates mipmaps on import.
The grayscale bark and leaf maps take their color from the garden's existing vertex tints.


Fern clumps use a 128 × 256 color and alpha atlas cropped from three fronds in `fern_02_diff_1k.jpg` and `fern_02_alpha_1k.png` from [Fern 02, Poly Haven](https://polyhaven.com/a/fern_02), CC0. The shared mesh is built in Godot.
