"""Make the Reactor's two Meshy pieces small enough to ship (AR1, 21 Nov 2026).

Sources (generated with Meshy on the owner's paid plan, 21 Nov 2026, from the concept pictures beside them):
    assets_src/meshy/reactor/reactor_growth_c_meshy.glb   a growth round a flanged pipe section, strands hanging
    assets_src/meshy/reactor/reactor_rotor_b_meshy.glb    a turbine rotor in the lower half of an open casing
Out:
    godot/assets/reactor/growth_c.glb   about 7,500 triangles, 1024 px WebP colour, the pipe along +X (glTF),
                                        centred on the pipe's axis, the pipe 1 m long
    godot/assets/reactor/rotor_b.glb    about 9,500 triangles, 1024 px WebP colour, the shaft along +X,
                                        centred over the origin, its lowest point at 0

Each mesh is joined, decimated (collapse) to its budget, re-centred and scaled as above; the texture is cut to
1024 px. Nothing random. Run from the checkout root (Blender 5.3):

  tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 \
      --python assets_src/blender/reactor/build_reactor_meshy.py

It prints each piece's triangle count before and after, its size, and (the growth) the bare pipe's radius at
its open end, which client/station_dress.gd's GROWTH_PIPE_R holds.
"""
import math
import os

import bpy
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TEX = 1024
PIECES = (
    ("assets_src/meshy/reactor/reactor_growth_c_meshy.glb", "godot/assets/reactor/growth_c.glb", 7500, "growth"),
    ("assets_src/meshy/reactor/reactor_rotor_b_meshy.glb", "godot/assets/reactor/rotor_b.glb", 9500, "rotor"),
)


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def tris(obj):
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def build(src, out, budget, kind):
    clear()
    bpy.ops.import_scene.gltf(filepath=os.path.join(ROOT, src))
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    # Bake parents and transforms into the mesh.
    bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for o in list(bpy.context.scene.objects):
        if o != obj:
            bpy.data.objects.remove(o, do_unlink=True)
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
    size = hi - lo
    # The long axis (the pipe, the shaft) goes to X.
    axis = int(np.argmax(size[:2]))
    if axis == 1:
        obj.data.transform(__import__("mathutils").Matrix.Rotation(math.pi / 2, 4, "Z"))
        v = np.array([vv.co[:] for vv in obj.data.vertices])
        lo = v.min(axis=0)
        hi = v.max(axis=0)
        size = hi - lo
    from mathutils import Matrix, Vector
    if kind == "growth":
        # The pipe's axis: the middle of the flange rings at both ends (Blender Z up).
        length = size[0]
        ends = []
        for x_end in (lo[0], hi[0]):
            ring = v[np.abs(v[:, 0] - x_end) < length * 0.04]
            ends.append(((ring[:, 1].max() + ring[:, 1].min()) / 2, (ring[:, 2].max() + ring[:, 2].min()) / 2))
        cy = (ends[0][0] + ends[1][0]) / 2
        cz = (ends[0][1] + ends[1][1]) / 2
        cx = (lo[0] + hi[0]) / 2
        s = 1.0 / length
        obj.data.transform(Matrix.Scale(s, 4) @ Matrix.Translation(Vector((-cx, -cy, -cz))))
        v = np.array([vv.co[:] for vv in obj.data.vertices])
        # The bare pipe near the -X end (past the flange): its radius.
        band = v[(v[:, 0] > -0.5 + 0.17) & (v[:, 0] < -0.5 + 0.22)]
        r = np.sqrt(band[:, 1] ** 2 + band[:, 2] ** 2)
        print(f"PIPE_RADIUS median {np.median(r):.4f} p20 {np.percentile(r, 20):.4f} min {r.min():.4f}")
        ring = v[v[:, 0] < -0.5 + 0.03]
        print(f"FLANGE_RADIUS {np.sqrt(ring[:, 1] ** 2 + ring[:, 2] ** 2).max():.4f}")
    else:
        cx = (lo[0] + hi[0]) / 2
        cy = (lo[1] + hi[1]) / 2
        obj.data.transform(Matrix.Translation(Vector((-cx, -cy, -lo[2]))))
    v = np.array([vv.co[:] for vv in obj.data.vertices])
    print(f"{kind}: triangles {before} -> {after}; size {np.round(v.max(axis=0) - v.min(axis=0), 4)}; min {np.round(v.min(axis=0), 4)} max {np.round(v.max(axis=0), 4)}")
    for img in bpy.data.images:
        if img.size[0] > TEX:
            img.scale(TEX, TEX)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(ROOT, out), export_format="GLB", use_selection=True,
                              export_image_format="WEBP", export_animations=False, export_skins=False,
                              export_morph=False, export_yup=True)
    print(f"wrote {out} {os.path.getsize(os.path.join(ROOT, out)):,} bytes")


for piece in PIECES:
    build(*piece)
