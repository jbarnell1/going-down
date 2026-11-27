"""Make the Hanging Ward homes' eight Meshy pieces small enough to ship (WH3, 27 Nov 2026).

Sources (generated with Meshy on the owner's paid plan, 21 Nov 2026; kept out of git under assets_src/inbox/meshy/):
    ward-range    an iron kitchen range with oven doors and a flue
    ward-table    a scrubbed kitchen table on turned legs
    ward-dresser  a kitchen dresser, plates on its shelves, cupboards below
    ward-bed      an iron bedstead with a striped mattress and a sheet
    ward-bath     a claw-foot bath, hollow
    ward-clock    a long-case clock
    ward-copper   a wash copper on its brick base beside a mangle: cut in two at the gap between them
    ward-pram     a hooded pram
Out (godot/assets/ward/homes/): range, table, dresser, bed, bath, clock, copper, mangle and pram .glb, each joined,
decimated (collapse) to its budget, centred over the origin with its lowest point at 0, at the source's own scale
(the game fits each to the box its rules give the piece), its colour cut to 1024 px WebP. Nothing random.
Run from the checkout root (Blender 5.3):

  tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 \
      --python assets_src/blender/ward/build_ward_meshy.py

It prints each piece's triangle count before and after, its size (Blender Z up; glTF swaps Y and Z) and its bytes.
The source's front (the side its picture was made from) is Blender -Y, which is glTF and Godot +Z.
"""
import os

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SRC = "assets_src/inbox/meshy/ward-%s/ward-%s-model-glb.glb"
# The inbox is not in git: a worktree reads it from the main checkout named here (default: this checkout).
SRC_ROOT = os.environ.get("MESHY_INBOX_ROOT", ROOT)
OUT = "godot/assets/ward/homes/%s.glb"
TEX = 1024
# Where the copper's brick base ends and the mangle's legs begin, Blender x (measured on the source).
COPPER_CUT = -0.07
# (source, out, triangle budget, keep: None, or ("below"|"above", x) to keep one side of a cut).
PIECES = (
    ("range", "range", 5000, None),
    ("table", "table", 4000, None),
    ("dresser", "dresser", 6000, None),
    ("bed", "bed", 6000, None),
    ("bath", "bath", 5000, None),
    ("clock", "clock", 4000, None),
    ("copper", "copper", 5000, ("below", COPPER_CUT)),
    ("copper", "mangle", 5000, ("above", COPPER_CUT)),
    ("pram", "pram", 5000, None),
)


def tris(obj):
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def cut(obj, keep):
    side, x = keep
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(x, 0, 0), plane_no=(1, 0, 0),
                           clear_outer=(side == "below"), clear_inner=(side == "above"))
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()


def build(name, out_name, budget, keep):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC_ROOT, SRC % (name, name)))
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for o in list(bpy.context.scene.objects):
        if o != obj:
            bpy.data.objects.remove(o, do_unlink=True)
    if keep is not None:
        cut(obj, keep)
    before = tris(obj)
    if before > budget:
        mod = obj.modifiers.new("decimate", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = budget / before
        bpy.ops.object.modifier_apply(modifier=mod.name)
    after = tris(obj)
    v = np.array([vv.co[:] for vv in obj.data.vertices])
    lo = v.min(axis=0)
    hi = v.max(axis=0)
    c = Vector(((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, lo[2]))
    obj.data.transform(Matrix.Translation(-c))
    v = np.array([vv.co[:] for vv in obj.data.vertices])
    out = OUT % out_name
    print(f"{out}: triangles {before} -> {after}; size {np.round(v.max(axis=0) - v.min(axis=0), 3)}")
    while len(obj.data.materials) > 1:
        obj.data.materials.pop(index=len(obj.data.materials) - 1)
    for img in bpy.data.images:
        if img.size[0] > TEX:
            img.scale(TEX, TEX)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    os.makedirs(os.path.dirname(os.path.join(ROOT, out)), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(ROOT, out), export_format="GLB", use_selection=True,
                              export_image_format="WEBP", export_animations=False, export_skins=False,
                              export_morph=False, export_yup=True)
    print(f"wrote {out} {os.path.getsize(os.path.join(ROOT, out)):,} bytes")


for piece in PIECES:
    build(*piece)
