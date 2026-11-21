"""RW1: the Rigger as the player sees him in the Hanging Ward, rendered from the poses the game's own view drew.

godot/tools/rigger_views.gd runs the Ward's rules and its view (client/ward/view.gd) and writes, per shot, the camera
(the player's eye and aim), every box and lamp near it, the figure's place, clip and time, the search hand and the
arm's tube. This script rebuilds each shot from those numbers with the real files (godot/assets/ward/rigger_v2.glb,
search-hand.glb) and renders it small and dark, as the game is played: the Ward's lamps, his helmet lamp and the
player's torch.

  tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 \
    --python assets_src/blender/rigger/render_rigger_views.py -- json=<views.json> out=<folder> [prefix=rw1-] [only=<name>]

The look is approximate: plain colours for the Ward's surfaces, no fog, no tape filter. Placement, pose and scale are
exact (the same numbers the game used).
"""
import bpy, json, math, sys
from pathlib import Path
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[3]
ARGS = dict(a.split("=", 1) for a in (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []) if "=" in a)
DATA = json.loads(Path(ARGS["json"]).read_text())
OUT = Path(ARGS["out"])
PREFIX = ARGS.get("prefix", "rw1-")
ONLY = ARGS.get("only", "")
OUT.mkdir(parents=True, exist_ok=True)
FPS = 30

# Godot (x, y up, z) to Blender (x, -z, y up).
C = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))


def vec(p):
    return Vector((p[0], -p[2], p[1]))


def xform(m):
    """A Godot Transform3D as written by rigger_views.gd ([x, y, z, origin] columns) in Blender space."""
    g = Matrix.Identity(4)
    for col in range(3):
        for row in range(3):
            g[row][col] = m[col][row]
    for row in range(3):
        g[row][3] = m[3][row]
    return C @ g @ C.inverted()


bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x, scene.render.resolution_y = 480, 270
scene.render.resolution_percentage = int(ARGS.get("percent", "100"))  # more only to inspect a detail
scene.render.fps = FPS
scene.view_settings.view_transform = "Standard"
scene.world = bpy.data.worlds.new("ward")
scene.world.use_nodes = True
bg = scene.world.node_tree.nodes["Background"]
# The Ward's background colour and a dim share of its blue ambient light.
bg.inputs["Color"].default_value = (0.26, 0.33, 0.42, 1)
bg.inputs["Strength"].default_value = 0.08


def imported(path, name):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    new = [o for o in bpy.data.objects if o not in before]
    holder = bpy.data.objects.new(name, None)
    scene.collection.objects.link(holder)
    for o in new:
        if o.parent is None:
            o.parent = holder
    return holder, new


rigger, rigger_parts = imported(ROOT / "godot" / "assets" / "ward" / "rigger_v2.glb", "Rigger")
rig = next(o for o in rigger_parts if o.type == "ARMATURE")
hand, _ = imported(ROOT / "godot" / "assets" / "ward" / "search-hand.glb", "SearchHand")
for o in rigger_parts:
    if o.type == "LIGHT":
        o.hide_render = True

cube = bpy.data.meshes.new("unit box")
cube.from_pydata([(x, y, z) for x in (-.5, .5) for y in (-.5, .5) for z in (-.5, .5)], [],
                 [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)])
cube.materials.append(None)
materials = {}


def material(c, glow=False):
    key = (round(c[0], 3), round(c[1], 3), round(c[2], 3), round(c[3], 3), glow)
    if key in materials:
        return materials[key]
    m = bpy.data.materials.new("c%d" % len(materials))
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (c[0] ** 2.2, c[1] ** 2.2, c[2] ** 2.2, 1)
    p.inputs["Roughness"].default_value = 0.85
    if c[3] < 0.99:
        p.inputs["Alpha"].default_value = c[3]
    if glow:
        p.inputs["Emission Color"].default_value = (c[0] ** 2.2, c[1] ** 2.2, c[2] ** 2.2, 1)
        p.inputs["Emission Strength"].default_value = 1.5
    materials[key] = m
    return m


shot_objects = []


def clear_shot():
    for o in shot_objects:
        bpy.data.objects.remove(o, do_unlink=True)
    shot_objects.clear()


def add(o):
    scene.collection.objects.link(o)
    shot_objects.append(o)
    return o


def point_light(at, colour, watts, reach, shadow=False):
    data = bpy.data.lights.new("lamp", "POINT")
    data.color = colour
    data.energy = watts
    data.shadow_soft_size = 0.05
    data.use_shadow = shadow
    data.use_custom_distance = True
    data.cutoff_distance = reach
    o = add(bpy.data.objects.new("lamp", data))
    o.location = at
    return o


cam = bpy.data.objects.new("eye", bpy.data.cameras.new("eye"))
scene.collection.objects.link(cam)
scene.camera = cam
cam.data.sensor_fit = "VERTICAL"
cam.data.clip_start = 0.05
cam.data.clip_end = 200

for shot in DATA["shots"]:
    if ONLY and shot["name"] != ONLY:
        continue
    clear_shot()
    for b in shot["boxes"]:
        if ARGS.get("overhead") == "1" and b["m"][3][1] > shot["eye"][1] + 0.6:
            continue  # the ceilings and roofs, for the check from above
        # One shared unit box; each object carries its own colour in an object-linked slot.
        o = add(bpy.data.objects.new("box", cube))
        size = b["size"]
        o.matrix_world = xform(b["m"]) @ (C @ Matrix.Diagonal((size[0], size[1], size[2], 1)) @ C.inverted())
        o.material_slots[0].link = "OBJECT"
        o.material_slots[0].material = material(b["c"], b["glow"])
    for l in shot["lights"]:
        # Godot's lamps cast no shadows (client/ward/view.gd _lamp, the helmet lamp): neither do these.
        point_light(vec(l["at"]), l["c"], l["energy"] * 60.0, l["range"])
    r = shot["rigger"]
    rigger.hide_render = not r["drawn"]
    for o in rigger_parts:
        o.hide_render = not r["drawn"] or o.type == "LIGHT"
    rigger.matrix_world = xform(r["m"])
    if r["clip"]:
        action = next((a for a in bpy.data.actions if a.name == r["clip"] or a.name.startswith(r["clip"] + "_")), None)
        rig.animation_data.action = action
        if rig.animation_data.action_slot is None and action is not None and len(action.slots):
            rig.animation_data.action_slot = action.slots[0]
        frame = r["time"] * FPS
        scene.frame_set(int(math.floor(frame)), subframe=frame - math.floor(frame))
    # RR1 stage 2: legs the game solved onto the surfaces (client/ward/rigger_feet.gd): each femur aimed at its knee,
    # tibia at its ankle and tarsus at its foot, as the game's two-bone IK did.
    if r.get("legs"):
        bpy.context.view_layer.update()
        to_arm = rig.matrix_world.inverted()
        for leg, points in r["legs"].items():
            for part, target in zip(("femur", "tibia", "tarsus"), points):
                pb = rig.pose.bones.get("leg_%s_%s" % (leg, part))
                if pb is None:
                    continue
                m = pb.matrix.copy()
                head = m.translation.copy()
                want = (to_arm @ vec(target)) - head
                if want.length < 1e-5:
                    continue
                turn = m.col[1].xyz.normalized().rotation_difference(want.normalized())
                pb.matrix = Matrix.Translation(head) @ turn.to_matrix().to_4x4() @ m.to_3x3().to_4x4()
                bpy.context.view_layer.update()
    h = shot["hand"]
    hand.matrix_world = xform(h["m"])
    for o in [hand] + list(hand.children_recursive):
        o.hide_render = not h["drawn"]
    if shot["tube"]:
        verts = [vec(p) for p in shot["tube"]]
        me = bpy.data.meshes.new("arm")
        me.from_pydata(verts, [], [(i, i + 1, i + 2) for i in range(0, len(verts) - 2, 3)])
        me.materials.append(material([0.506, 0.4, 0.361, 1.0]))
        add(bpy.data.objects.new("arm", me))
    eye, target = vec(shot["eye"]), vec(shot["target"])
    if ARGS.get("overhead") == "1":
        # A check of the layout: from above the eye and the aim, both marked.
        for p, c in ((eye, (0.2, 1, 0.2, 1)), (target, (1, 0.2, 0.2, 1))):
            mark = add(bpy.data.objects.new("mark", cube))
            mark.matrix_world = Matrix.Translation(p) @ Matrix.Diagonal((0.3, 0.3, 3.0, 1))
            mark.material_slots[0].link = "OBJECT"
            mark.material_slots[0].material = material(c, True)
        middle = (eye + target) * 0.5
        eye, target = middle + Vector((0, -0.01, 16)), middle
        bg.inputs["Strength"].default_value = 1.0
    cam.location = eye
    cam.rotation_euler = (target - eye).to_track_quat("-Z", "Y").to_euler()
    cam.data.angle_y = math.radians(shot["fov"])
    # The player's torch: the main game's beam (client/lamp_view.gd: 24 degree half angle, energy 4, warm white).
    torch = bpy.data.lights.new("torch", "SPOT")
    torch.color = (1.0, 0.90, 0.71)
    torch.energy = 4.0 * 12.0
    torch.spot_size = math.radians(48)
    torch.spot_blend = 0.35
    torch.shadow_soft_size = 0.03
    torch.use_custom_distance = True
    torch.cutoff_distance = 12.0
    t = add(bpy.data.objects.new("torch", torch))
    t.location = eye + Vector((0.18, 0, -0.25))
    t.rotation_euler = cam.rotation_euler
    scene.render.filepath = str(OUT / ("%s%s.png" % (PREFIX, shot["name"])))
    bpy.ops.render.render(write_still=True)
    print("RW1 render", scene.render.filepath, "clip", r["clip"], "t %.2f" % r["time"], flush=True)
print("RW1 done", flush=True)
