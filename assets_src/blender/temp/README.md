# The Temp (Annex resident)

An office worker 1.80 m tall (short-sleeved shirt, tie, lanyard and badge, trousers a little short over
dark socks, office shoes) with an A4 sheet stapled over its face. One mesh in a clean T-pose for Mixamo:
arms straight out, fingers straight and spread, thumbs forward and a little down, legs straight, feet
apart, facing -Y. No armature. 3,812 triangles: the body is one closed surface of 2,428; the collar,
tie, lanyard, clip, badge, pen, sheet and four staples are thin closed shells laid over it.

| file | what |
| --- | --- |
| `temp_tpose.glb` | the figure, mesh `Temp`, materials `temp_body` (512 px atlas, nearest) and `temp_face_sheet` |
| `temp_face_sheet.png` | a sample photocopy (120 x 170, made the way `client/temp_view.gd` makes them); the game swaps it |
| `temp_stapler.glb` | the stapler, 168 triangles, origin at the grip, nose toward -Y, top up (+Z); 16.8 cm long |
| `temp_notes.glb` | the pad of sticky notes, 108 triangles, 7.6 cm square, origin at its middle, sticky edge +Y, writing up |

Axes above are Blender's (Z up); in the glb files (Y up) -Y becomes +Z and +Z becomes +Y.

The sheet's front is its own material, `temp_face_sheet`, with 0..1 UVs: u left to right and the top
of the page at the top, so a picture drawn upright lands upright (the same page `TempView.photocopy`
makes). Its back and edges are plain paper on `temp_body`.

Rebuild everything, from the repo root:

```
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/temp/build_temp.py
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python assets_src/mixamo/mixamo_export.py -- assets_src/blender/temp/temp_tpose.glb assets_src/mixamo/export/temp.fbx assets_src/mixamo/export/temp
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/temp/render_temp.py
```

(Give `mixamo_export.py` absolute paths if the pictures do not appear.) The render script poses the
figure on a throwaway rig with automatic weights (never exported) and writes the judging pictures to
`assets_src/renders/temp/`. Notes: docs/ART-NOTES.md, "The Temp".

## After Mixamo

- Upload `assets_src/mixamo/export/temp.fbx`. It carries the glb's split vertices (3,606 against 1,932
  welded), as the Orderly's did.
- The sheet and staples should follow the Head bone only (the crewmate's mask was made rigid the same
  way): the bottom of the sheet hangs in front of the neck, and neck weights would bend it.
- Parent `temp_stapler.glb` to the right hand and `temp_notes.glb` to the left; the hands are open in
  the T-pose, so the grip comes from the animation (or a fixed finger curl).
