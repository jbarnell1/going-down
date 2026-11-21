# Hanging Ward photographic maps (AW1)

Every map is a 1k colour photograph from Poly Haven, CC0 1.0 (confirmed on each asset's own page, 21 Nov 2026),
reduced by `python -I assets_src/ward_textures.py <folder of the downloaded jpgs>`. Grey maps take their colour from
the Ward's shaders (`client/ward/skin.gd`, `ward_house.gdshader`). Godot imports them lossy (0.8) with mipmaps.

| Game file | Source | Size | Laid at |
| --- | --- | --- | --- |
| `brick.webp` | [Red Brick 03](https://polyhaven.com/a/red_brick_03) | 512, colour | 1.0 m |
| `plaster.webp` | [White Plaster Rough 02](https://polyhaven.com/a/white_plaster_rough_02) | 512, grey | 1.0 m |
| `planks.webp` | [Weathered Planks](https://polyhaven.com/a/weathered_planks) | 512, grey | 2.0 m (decks), 1.5 m (ceilings) |
| `floorboards.webp` | [Wood Floor Worn](https://polyhaven.com/a/wood_floor_worn) | 512, grey | 2.0 m |
| `slates.webp` | [Roof Slates 02](https://polyhaven.com/a/roof_slates_02) | 512, grey | 3.0 m |
| `rock.webp` | [Rock Wall 10](https://polyhaven.com/a/rock_wall_10) | 512, grey | 11 m |
| `iron.webp` | [Rusty Metal 02](https://polyhaven.com/a/rusty_metal_02) | 256, colour, darkened | 1.0 m |
| `doorwood.webp` | [Wood Cabinet Worn Long](https://polyhaven.com/a/wood_cabinet_worn_long) | 256, colour | 1.0 m |
| `paper.webp` | [Decrepit Wallpaper](https://polyhaven.com/a/decrepit_wallpaper) | 256, grey | 1.25 m |

Fetched from `https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/<id>/<id>_diff_1k.jpg` (image files only).
