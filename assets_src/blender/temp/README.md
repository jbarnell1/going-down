# The Temp (Annex resident)

An office worker 1.79 m tall who does not look after himself (short-sleeved shirt with half its tail
out, coffee down the front, sweat under the arms, the tie pulled loose and the top button undone, a
lanyard and badge, trousers a little short over dark socks, a scuffed shoe) with an A4 sheet stapled and
tied over its face. Its one wrong thing: arms too long (the forearms 7 cm long). One mesh in a clean
T-pose for Mixamo: arms straight out, fingers straight and spread, thumbs forward and a little down, legs
straight, feet apart, facing -Y; the upper back is rounded from years at a desk. No armature. 4,712
triangles: the body (with the loose shirt tail) is one closed surface of 2,728; the collar, tie knot, blade
and loop, lanyard, clip, badge, pen, sheet, four staples, the string with its knot and loose ends and two
bits of tape are thin closed shells laid over it.

| file | what |
| --- | --- |
| `temp_tpose.glb` | the figure, mesh `Temp`, materials `temp_body` (512 px atlas, nearest) and `temp_face_sheet` |
| `temp_face_sheet.png` | a sample photocopy (480 x 680: `client/temp_view.gd`'s page made 4 times finer); the game swaps it. Linear filtering |
| `temp_stapler.glb` | the stapler, 180 triangles, warm grey on a black base, origin at the grip, nose toward -Y, top up (+Z); 16.8 cm long |
| `temp_notes.glb` | the pad of sticky notes, 108 triangles, 9 cm square, origin at its middle, sticky edge +Y, writing up |

Axes above are Blender's (Z up); in the glb files (Y up) -Y becomes +Z and +Z becomes +Y.

The sheet's front is its own material, `temp_face_sheet`, with 0..1 UVs: u left to right and the top
of the page at the top, so a picture drawn upright lands upright (the same page `TempView.photocopy`
makes). Its back and edges are plain paper on `temp_body`.

Rebuild everything, from the repo root (the build also writes the Mixamo upload,
`assets_src/mixamo/export/temp.fbx` and its front/side/back/top pictures, the way `mixamo_export.py`
does but from the welded mesh; `--no-mixamo` skips it):

```
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/temp/build_temp.py
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/temp/render_temp.py
```

The render script poses the
figure on a throwaway rig with automatic weights (never exported) and writes the judging pictures to
`assets_src/renders/temp/`. Notes: docs/ART-NOTES.md, "The Temp".

## After Mixamo

- Upload `assets_src/mixamo/export/temp.fbx`: welded (2,398 vertices, no seams for the rig to tear).
- The sheet, staples, string and tape should follow the Head bone only (the crewmate's mask was made
  rigid the same way): the bottom of the sheet is tucked under the jaw, and neck weights would bend it.
- Parent `temp_stapler.glb` to the right hand and `temp_notes.glb` to the left; the hands are open in
  the T-pose, so the grip comes from the animation (or a fixed finger curl).
