# Put the Orderly's arms straight out (a T-pose) with the fingers fanned apart and the thumb forward,
# bake that into the mesh, and save a glb for mixamo_export.py.
# Run: blender --background --python tpose.py -- <orderly.glb> <out.glb>
import bpy, sys, math, mathutils

src, out = sys.argv[sys.argv.index("--") + 1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
arm = [o for o in bpy.data.objects if o.type == 'ARMATURE'][0]
arm.data.pose_position = 'POSE'
for pb in arm.pose.bones:
    pb.matrix_basis = mathutils.Matrix.Identity(4)
bpy.context.view_layer.update()
inv = arm.matrix_world.inverted().to_3x3()


def aim(bone, point_of, sign, front=0.0, down=0.0):
    # Turn the bone about its head so point_of() lies along the arm (sign = +1 left, -1 right), fanned
    # 'front' degrees toward the figure's front (-Y) and 'down' degrees below horizontal.
    pb = arm.pose.bones[bone]
    pivot = pb.head.copy()
    cur = (point_of() - pivot).normalized()
    a = math.radians(front)
    d = math.radians(down)
    world = mathutils.Vector((sign * math.cos(a) * math.cos(d), -math.sin(a) * math.cos(d), -math.sin(d)))
    q = cur.rotation_difference((inv @ world).normalized())
    R = mathutils.Matrix.Translation(pivot) @ q.to_matrix().to_4x4() @ mathutils.Matrix.Translation(-pivot)
    pb.matrix = R @ pb.matrix
    bpy.context.view_layer.update()


FAN = {"index": 25.0, "middle": 0.0, "ring": -25.0}
P = arm.pose.bones
for side, sign in (("L", 1), ("R", -1)):
    aim("upperarm." + side, lambda: P["forearm." + side].head.copy(), sign)
    aim("forearm." + side, lambda: P["hand." + side].head.copy(), sign)
    aim("hand." + side, lambda: P["middle1." + side].head.copy(), sign)
    for f, ang in FAN.items():
        for i in (1, 2, 3):
            n = f"{f}{i}.{side}"
            if n in P:
                aim(n, (lambda n=n: P[n].tail.copy()), sign, front=ang)
    if "thumb." + side in P:
        aim("thumb." + side, lambda: P["thumb." + side].tail.copy(), sign, front=60.0, down=20.0)

for o in bpy.data.objects:
    if o.type == 'MESH' and not o.name.startswith("Icosphere"):
        bpy.context.view_layer.objects.active = o
        for m in list(o.modifiers):
            if m.type == 'ARMATURE':
                bpy.ops.object.modifier_apply(modifier=m.name)
for o in list(bpy.data.objects):
    if o.type != 'MESH' or o.name.startswith("Icosphere"):
        bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.export_scene.gltf(filepath=out, export_format='GLB')
print("WROTE", out)
