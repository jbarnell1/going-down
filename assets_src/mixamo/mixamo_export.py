# Export a rigged glb as a plain mesh in its rest pose, as an FBX with embedded textures, for Mixamo's auto-rigger,
# and render a front and side picture of it. Args after --: <in.glb> <out.fbx> <out_prefix_png>
import bpy, sys, math, mathutils
args = sys.argv[sys.argv.index("--") + 1:]
src, out, png = args
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
for ob in list(bpy.data.objects):
    if ob.type == 'ARMATURE':
        ob.data.pose_position = 'REST'
bpy.context.view_layer.update()
for o in list(bpy.data.objects):
    if o.type == "MESH" and (o.name.startswith("Icosphere") or o.name.startswith("headwear")):
        bpy.data.objects.remove(o, do_unlink=True)
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
for o in meshes:
    for m in list(o.modifiers):
        if m.type == 'ARMATURE':
            o.modifiers.remove(m)
    mw = o.matrix_world.copy()
    o.parent = None
    o.matrix_world = mw
    o.vertex_groups.clear()
    if o.data.shape_keys:
        o.shape_key_clear()
for ob in list(bpy.data.objects):
    if ob.type not in ('MESH',):
        bpy.data.objects.remove(ob, do_unlink=True)
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
# bounds
mn = mathutils.Vector((1e9,)*3); mx = mathutils.Vector((-1e9,)*3)
tris = 0
for o in meshes:
    for v in o.data.vertices:
        w = o.matrix_world @ v.co
        mn = mathutils.Vector(map(min, mn, w)); mx = mathutils.Vector(map(max, mx, w))
    tris += sum(len(p.vertices) - 2 for p in o.data.polygons)
print("BOUNDS", tuple(round(c,3) for c in mn), tuple(round(c,3) for c in mx), "MESHES", len(meshes), "TRIS", tris)
bpy.ops.export_scene.fbx(filepath=out, use_selection=False, object_types={'MESH'}, path_mode='COPY', embed_textures=True, apply_scale_options='FBX_SCALE_ALL', add_leaf_bones=False)
print("WROTE", out)
# pictures
scn = bpy.context.scene
scn.render.engine = 'BLENDER_WORKBENCH'
scn.display.shading.color_type = 'TEXTURE'
scn.render.resolution_x = 600; scn.render.resolution_y = 800
c = (mn + mx) / 2; h = max(mx.z - mn.z, mx.x - mn.x, mx.y - mn.y)
cam_d = bpy.data.cameras.new("cam"); cam_d.type = 'ORTHO'; cam_d.ortho_scale = h * 1.15
cam = bpy.data.objects.new("cam", cam_d); scn.collection.objects.link(cam); scn.camera = cam
w = bpy.data.worlds.new("w"); scn.world = w; w.color = (0.6, 0.6, 0.6)
for name, d in (("front", mathutils.Vector((0, -1, 0))), ("side", mathutils.Vector((1, 0, 0))), ("back", mathutils.Vector((0, 1, 0))), ("top", mathutils.Vector((0, 0, 1)))):
    cam.location = c + d * (h * 3)
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y" if abs(d.z) < 0.5 else "Y").to_euler()
    scn.render.filepath = png + "_" + name + ".png"
    bpy.ops.render.render(write_still=True)
