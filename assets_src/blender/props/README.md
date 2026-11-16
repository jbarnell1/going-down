# Clinic props

Low-detail furniture and fittings for the Clinic floor. The game is drawn at 270 pixels tall
through a VHS filter, so every prop is cut down to a few hundred triangles and one material.

## Rebuild

From the repo root, with the path to a Blender 5.3 executable in `BLENDER`:

```
"$BLENDER" --background --factory-startup --python-exit-code 1 --python assets_src/blender/props/build_props.py
"$BLENDER" --background --factory-startup --python-exit-code 1 --python assets_src/blender/props/check_props.py
```

The first command empties `public/assets/props/` of glb files and rebuilds all of them plus
`manifest.json` (about 10 seconds). `--only name,name` rebuilds just those props and keeps the
other manifest entries. The second command re-imports every glb in a clean scene, fails on any
prop over budget, with more than 2 materials, with an image over 128 px (256 for the wheelchair),
with the wrong size (more than 5% off) or with its origin off its mount point, and then renders the
contact sheets into `assets_src/renders/props/`. Add `--verify-only` to skip the renders.

## Sources

The kits are not in git. The script expects them under `tools/props/` (or pass
`--sources DIR`), laid out as downloaded:

- `kenney-furniture-kit/x/Models/GLTF format/*.glb` (Kenney Furniture Kit)
- `quaternius-house-interior/FBX/*.fbx` (Quaternius Ultimate House Interior Pack)
- `polyhaven/<id>/<id>_1k.gltf` with its `.bin` and `textures/` (Poly Haven, 1k glTF downloads)

Only the model files are read. Nothing in `tools/props` is run.

## What the script does to each prop

`props.json` is the list. Per prop: import, keep the listed objects (`keep_objects`), join into one
mesh, optional non-uniform `stretch` and rotation, optional `post` step that adds parts, scale to
the target size (`height`, `length` = longest horizontal side, or `longest`), planar-dissolve and
then collapse-decimate to the triangle budget, scale again (decimation pulls edges in), recolour,
set normals, move the origin, export glb.

- Axes: Blender front is -Y; the glb is +Y up with the front facing +Z.
- Origins: `floor` at the centre of the footprint on the floor; `wall` at the centre of the back
  face (the face that goes against the wall); `ceiling` at the centre of the top face.
- Kenney and Quaternius pieces: each source material becomes a flat vertex colour from the Clinic
  palette (`palette` and `kit_colors` at the top of `props.json`, overridden per prop by `colors`),
  under one plain material. Faceted normals, no UVs, no images.
- Poly Haven pieces: the base colour of every source material is shrunk and stacked into one
  128x128 image (`atlas_weights` decides how much of it each material gets), embedded as JPEG.
  Normal, roughness and metal maps are dropped. `tex_adjust` can shift hue, gain and saturation
  toward the palette (the medical box is turned from first-aid green to the muted red). Smooth
  normals split at 35 degrees.
- All materials: roughness 0.9, metalness 0, so `MeshStandardMaterial` looks right without an
  environment map. Materials are exported double-sided.
- Some Kenney pieces (the wall lamp, the corner desk) are thin shells modelled twice, back to back.
  The cleanup step notices that and then skips vertex merging and normal recalculation, which
  would otherwise delete one side.

## Hand-built and modified props

- `wheelchair`: built from boxes, bars and rings in `build_wheelchair()`, proportions from the
  Poly Haven `wheelchair_01` scan. The scan decimated to 1,100 triangles came out torn (broken
  armrests, holes in the frame, ragged wheels): see
  `assets_src/renders/props/experiment_decimated_scans.png`. The rebuild is about 920 triangles
  and stays clean.
- `crutches`: the same test on `vintage_crutches_01` held up, so the scan is used, decimated to
  about 490 triangles. They are wooden, not Clinic-palette steel; saturation is lowered.
- `bed_hospital`: Kenney single bed recoloured, with two steel side rails added (`post_bed_rails`).
- `gurney`: mattress, sheet and pillow from the Kenney single bed, narrowed to trolley width and
  set on a steel frame with a lower shelf, four casters and a push bar built by `post_gurney`.
- `pipe_run`: one 2 m flanged straight from `modular_industrial_pipes_01`, laid horizontal and
  doubled into two parallel runs (`post_pipe_pair`). The scan file is a loose set of fittings,
  not an assembled run.
- `air_duct`: the 1.8 m straight section of `modular_airduct_rectangular_01`.
- `bin_metal`: the clean can of the two in `metal_trash_can`, without its lid (the lid in the scan
  leans against the can).
- `bench_waiting` and `chair_waiting` are stretched sideways: the Kenney originals are narrow.

## Renders

`assets_src/renders/props/sheet_N.png` shows each prop from a 3/4 view on a mid-grey floor next to
a 1.7 m figure. Wall and ceiling props are shown standing on the floor too. `sheet_N_game.png` is
the same sheet rendered at 480x270 and enlarged 3x with nearest-neighbour, to judge how the props
read at game resolution. Materials are rendered with backface culling so that inside-out faces
would show as holes.
