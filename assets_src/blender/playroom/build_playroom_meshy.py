"""Make the Playroom's two Meshy pieces small enough to ship (PR1, 21 Nov 2026).

Sources (generated with Meshy on the owner's paid plan, 21 Nov 2026, from Fable's concept pictures; kept out of git
under assets_src/inbox/meshy/):
    assets_src/inbox/meshy/playroom-slide/playroom-slide-model-glb.glb      a red, yellow and blue tube slide with a
                                                                            steel stair
    assets_src/inbox/meshy/playroom-frame-b/playroom-frame-b-model-glb.glb  a soft-play tower: padded posts, panels
                                                                            with holes, a deck and steps
Out:
    godot/assets/playroom/slide.glb   about 9,000 triangles, 1024 px WebP colour, standing on 0, centred, 2.0 m tall
    godot/assets/playroom/frame.glb   about 14,000 triangles, 1024 px WebP colour, standing on 0, centred, 2.3 m tall

Each mesh is joined, decimated (collapse) to its budget, centred over the origin with its lowest point at 0,
scaled to its height, and its texture cut to 1024 px. Nothing random. Run from the checkout root (Blender 5.3):

  tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 \
      --python assets_src/blender/playroom/build_playroom_meshy.py

It prints each piece's triangle count before and after and its size (Blender Z up; glTF swaps Y and Z).
"""
import os

import bpy
import numpy as np
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TEX = 1024
PIECES = (
    ("assets_src/inbox/meshy/playroom-slide/playroom-slide-model-glb.glb", "godot/assets/playroom/slide.glb", 9000, 2.0),
    ("assets_src/inbox/meshy/playroom-frame-b/playroom-frame-b-model-glb.glb", "godot/assets/playroom/frame.glb", 14000, 2.3),
)


def tris(obj):
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def build(src, out, budget, height):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(ROOT, src))
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
    s = height / (hi[2] - lo[2])
    c = Vector(((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, lo[2]))
    obj.data.transform(Matrix.Scale(s, 4) @ Matrix.Translation(-c))
    v = np.array([vv.co[:] for vv in obj.data.vertices])
    print(f"{out}: triangles {before} -> {after}; size {np.round(v.max(axis=0) - v.min(axis=0), 3)}")
    # One material.
    while len(obj.data.materials) > 1:
        obj.data.materials.pop(index=len(obj.data.materials) - 1)
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
