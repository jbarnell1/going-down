# The Reactor's maps and models

| Game asset | Source | Size |
| --- | --- | --- |
| `wall_concrete.webp` | [Concrete Slab Wall, Poly Haven](https://polyhaven.com/a/concrete_slab_wall) | 512 x 512, RGB |
| `wall_paint.webp` | [Painted Concrete, Poly Haven](https://polyhaven.com/a/painted_concrete) | 512 x 512, RGB |
| `floor_concrete.webp` | [Concrete Floor Worn 001, Poly Haven](https://polyhaven.com/a/concrete_floor_worn_001) | 512 x 512, RGB |
| `ceiling_concrete.webp` | [Concrete Wall 006, Poly Haven](https://polyhaven.com/a/concrete_wall_006) | 512 x 512, RGB |
| `steel_plate.webp` | [Metal Plate 02, Poly Haven](https://polyhaven.com/a/metal_plate_02) | 512 x 512, RGB |
| `growth_c.glb` | Generated with Meshy on the owner's paid plan, 21 Nov 2026 | 7,500 triangles, 1024 px colour |
| `rotor_b.glb` | Generated with Meshy on the owner's paid plan, 21 Nov 2026 | 9,500 triangles, 1024 px colour |

The five maps are CC0. Download each map's 1k colour JPG
(`https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/<id>/<id>_diff_1k.jpg`) into one folder and run
`python assets_src/reactor_textures.py FOLDER` (Pillow and numpy) to rebuild them. The two models come from
`assets_src/meshy/reactor/` through `assets_src/blender/reactor/build_reactor_meshy.py` (Blender 5.3).