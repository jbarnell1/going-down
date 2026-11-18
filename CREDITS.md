# Credits

Third-party art used in Going Down. All of it is CC0 1.0 (public domain dedication) except the
crewmates' motion capture (below); credit is given here because the authors ask for it and because
it is right to.

## 3D props (`public/assets/props/`)

The props were reduced, recoloured and re-exported for the game by
`assets_src/blender/props/build_props.py`. `public/assets/props/manifest.json` lists which source
each prop came from.

- **Kenney**, Furniture Kit 2.0, CC0 1.0. https://www.kenney.nl
- **Quaternius**, Ultimate House Interior Pack, CC0 1.0. https://quaternius.com
- **Poly Haven**, CC0 1.0. https://polyhaven.com. Models used:
  - `metal_office_desk`
  - `metal_trash_can`
  - `vintage_crutches_01`
  - `medical_box`
  - `korean_fire_extinguisher_01`
  - `WetFloorSign_01`
  - `security_camera_01`
  - `modular_airduct_rectangular_01`
  - `modular_industrial_pipes_01`
  - `wheelchair_01` (used only as a size and proportion reference; the game's wheelchair was built
    from simple shapes by the script)

## Indoor surfaces (`godot/assets/textures/`)

- **ambientCG**, CC0 1.0. Carpet 001 adds grain to the Annex's mustard carpet. Leather 010 adds
  grain to the Playroom's wall padding and welded mats. [Carpet 001](https://ambientcg.com/view?id=Carpet001) · [Leather 010](https://ambientcg.com/view?id=Leather010)
- **Poly Haven**, CC0 1.0. Old Linoleum Flooring 01 adds wear to the Clinic's tiled floor.
  Concrete Floor supplies grain for the painted Prison floor. Metal Plate textures the lift
  doorway sill. [Old Linoleum Flooring 01](https://polyhaven.com/a/old_linoleum_flooring_01) · [Concrete Floor](https://polyhaven.com/a/concrete_floor) · [Metal Plate](https://polyhaven.com/a/metal_plate)

## Crewmate movement (`godot/assets/entities/crewmate.glb`)

- **Adobe Mixamo**, motion capture and auto-rigging. https://www.mixamo.com. The crewmate figure
  (built by script, `assets_src/blender/convict/`) was rigged by Mixamo and moves with these Mixamo
  clips: Standing Idle, Walking, Jog Forward, Sneaking Forward, Crouching Idle, Looking Behind,
  Button Pushing, Standing Death Backward 01, Crawling, Praying, Northern Soul Spin Combo, Snake Hip
  Hop Dance, Waving. Mixamo's terms allow its animations in games, but not handing on the raw files
  by themselves: those stay on the owner's machine (`assets_src/inbox/`, ignored by git), and only the
  baked game model, made by `assets_src/blender/convict/build_crewmate.py`, is published.
