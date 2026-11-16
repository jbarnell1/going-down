# The Convict (crewmate figure)

One closed, symmetric T-pose mesh (2,216 triangles, 1.78 m to the top of the harness) in a
jumpsuit, gauntlet work gloves and boots, wearing a screen mask: a small CRT housing 12.6 cm deep,
sealed to the face by a gasket, its sides reaching back to just in front of the ears, held by a rigid
harness (a band round the back of the skull and one over the crown, bolted to the housing) with a
ribbed cable down to the collar. No rig: Mixamo rigs it (use the "No Fingers" skeleton).

Four material slots:

| slot | what | texture |
| --- | --- | --- |
| `convict_suit` | the jumpsuit; the game multiplies the player's colour over it | `convict_suit.png` 256 px, light grey cloth with folds and wear |
| `convict_skin` | neck, ears, shaved scalp, gloves, boots, mask body, straps, cable | `convict_skin_1..4.png` 128 px, same UVs, four skin tones (1 is the default) |
| `number_patch` | chest 16 x 10 cm and back 26 x 16 cm, flat, 0..1 UVs | drawn by the game |
| `face_screen` | the mask's screen, 16.6 x 16.7 cm, flat, upright, 0..1 UVs | the player's drawn face, drawn and lit by the game |

Headwear is separate and needs no rig: `headwear_knit.glb`, `headwear_hair.glb` and
`headwear_none.glb` (an empty node). Each has its origin at the head joint, which is
`JOINTS["head"]` in `build_convict.py` (0, 0.005, 1.548 m in Blender, Z up; in glTF Y up that is
(0, 1.548, -0.005)). Attach it to the rigged Head bone with that offset. Each piece sits over the
harness and behind the housing without touching either.

Rebuild everything (mesh, UVs, textures, headwear, FBX and zip for Mixamo, glb), from the repo root:

```
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/convict/build_convict.py
```

Check the exports, then render the review images (`assets_src/renders/convict/`):

```
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/convict/render_convict.py -- --verify-only
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/convict/render_convict.py
```

Mixamo: upload `assets_src/inbox/convict-for-mixamo.fbx`. The FBX is in centimetres (UnitScaleFactor 1),
176 units tall, Y up, with no transform on the object, and the suit texture and skin texture 1 are
embedded. The fallback is `convict-for-mixamo.zip`, which holds the OBJ, the MTL and both textures.
The render script's test rig (automatic weights, Mixamo-like joints) is only there to prove the joint
loops and to pose the review renders; it is never exported.

## The animated crewmate

`build_crewmate.py` bakes the figure Mixamo rigged, with 13 clips, into the game's one model
`godot/assets/entities/crewmate.glb` (and copies the four skin textures beside it as
`crewmate_skin_1..4.png`). It reads the Mixamo downloads from `assets_src/inbox/mixamo/` (kept out of
git), takes the mesh, materials and UVs from `convict_tpose.glb` and only the weights and skeleton from
Mixamo, and parents `headwear_knit` and `headwear_hair` to the `Head` bone:

```
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/convict/build_crewmate.py
```

It prints each clip's length, the stride speed of the moving clips and its checks. Godot draws it
with `godot/client/crew_view.gd`; `godot/client/crew_demo.tscn` takes the review pictures
(`assets_src/renders/crewmate/`). Notes: docs/ART-NOTES.md, "The crewmate moves".
