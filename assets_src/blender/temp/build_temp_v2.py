"""Build the second Temp (godot/assets/entities/temp_v2.glb) from the Meshy model.

The figure is the owner's Meshy model (assets_src/meshy/temp/temp_meshy_rigged.glb: textured, rigged on a
28-bone Mixamo-named skeleton in an A-pose). Its motion is today's Temp's: the six clips baked into
godot/assets/entities/temp.glb are retargeted onto it by bone name, so no raw Mixamo file is needed.

What the script does, in order:
  1. Scales the Meshy figure to today's height (1.791 m, feet at 0), facing -Y as today's does.
  2. Cleans the texture: 1024 px, the shirt's dirt reduced so the white shirt and red tie read.
  3. Adds the A4 sheet over the face (material temp_face_sheet: the game draws the photocopy on it),
     bound rigidly to the Head bone, in the same mesh as the body (one mesh, one skin).
  4. Retargets walk, chase, idle, look, reach and bend frame for frame (same frame counts, travel already
     baked out in today's clips), turning the arms from today's T-pose rest to Meshy's A-pose rest.
  5. Puts today's stapler in the right hand and the notes in the left (bone-parented, as today).
  6. Exports one GLB.

From the repository root (Blender 5.3):
  tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 \
      --python assets_src/blender/temp/build_temp_v2.py
  ... --python assets_src/blender/temp/build_temp_v2.py -- --render <folder>   (pictures of the built file)

Nothing is random, so two builds give the same file.
"""
import math
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector
from mathutils.bvhtree import BVHTree

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = ROOT / "assets_src/meshy/temp/temp_meshy_rigged.glb"
TODAY = ROOT / "godot/assets/entities/temp.glb"
OUTPUT = ROOT / "godot/assets/entities/temp_v2.glb"
P = "mixamorig:"
FPS = 30
HEIGHT = 1.791          # today's figure's height (feet to the top of its sheet); here feet to the crown
CLIPS = ["walk", "chase", "idle", "look", "reach", "bend"]
# Target bone <- source bone. Meshy has no finger joints: its one finger bone takes the middle finger's base,
# which today's bake curls 40 degrees into a grip.
MAP = {P + n: P + n for n in [
    "Hips", "Spine", "Spine1", "Spine2", "Neck", "Head",
    "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
    "RightShoulder", "RightArm", "RightForeArm", "RightHand",
    "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase",
    "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]}
MAP[P + "LeftHandMiddle4"] = P + "LeftHandMiddle1"
MAP[P + "RightHandMiddle4"] = P + "RightHandMiddle1"
# Bones whose rest direction differs between the rests (T-pose against A-pose): swung onto today's first.
ARM_WORDS = ("Shoulder", "Arm", "Hand")
# Extra outward swing of the upper arms (radians), so the long fingers clear the thighs.
ABDUCT = math.radians(15.0)
# The sheet over the face: A4's shape, metres.
SHEET_W = 0.165
SHEET_H = 0.233
SHEET_GAP = 0.007
TEX = 1024


def imported_gltf(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    return set(bpy.data.objects) - before


def select_only(objs, active):
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objs:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = active


def load_today():
    objs = imported_gltf(TODAY)
    arm, = [o for o in objs if o.type == "ARMATURE"]
    props = {}
    bpy.context.view_layer.update()
    for o in objs:
        if o.name.startswith("temp_stapler") or o.name.startswith("temp_notes"):
            # The importer leaves the rig posed: carry the prop to the hand's rest through the posed hand.
            hand = arm.pose.bones[o.parent_bone]
            rel = (arm.matrix_world @ hand.matrix).inverted() @ o.matrix_world
            props[o.name.split(".")[0]] = (arm.matrix_world @ hand.bone.matrix_local @ rel, o.parent_bone)
    for o in objs:
        if o is not arm:
            bpy.data.objects.remove(o, do_unlink=True)
    arm.name = "TodayRig"
    return arm, props


def load_meshy():
    objs = imported_gltf(SOURCE)
    arm, = [o for o in objs if o.type == "ARMATURE"]
    body, = [o for o in objs if o.type == "MESH" and len(o.data.vertices) > 1000]
    for o in objs:
        if o not in (arm, body):
            bpy.data.objects.remove(o, do_unlink=True)
    ws = [body.matrix_world @ v.co for v in body.data.vertices]
    top = max(w.z for w in ws)
    low = min(w.z for w in ws)
    s = HEIGHT / (top - low)
    arm.scale = (s, s, s)
    arm.location.z = -low * s
    bpy.context.view_layer.update()
    select_only([arm, body], arm)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    ws = [body.matrix_world @ v.co for v in body.data.vertices]
    print(f"[TempV2] Meshy scaled by {s:.4f}: feet {min(w.z for w in ws):.4f}, top {max(w.z for w in ws):.4f}, "
          f"front {min(w.y for w in ws):.3f} back {max(w.y for w in ws):.3f}", flush=True)
    arm.name = "TempRig"
    body.name = "TempBody"
    return arm, body


# --- the texture ------------------------------------------------------------------------------------------


def clean_texture(body):
    mat = body.data.materials[0]
    mat.name = "temp_body_v2"
    node, = [n for n in mat.node_tree.nodes if n.type == "TEX_IMAGE"]
    img = node.image
    w, h = img.size
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
    # Where the shirt is: rasterize the UVs of the faces on the torso and sleeves into a mask.
    mask = np.zeros((h, w), dtype=bool)
    uv = body.data.uv_layers.active.data
    hips_z = HEIGHT * 0.535
    neck_z = HEIGHT * 0.79
    for poly in body.data.polygons:
        c = poly.center
        if not (hips_z < c.z < neck_z):
            continue
        if abs(c.x) > 0.21 and c.z < HEIGHT * 0.69:
            continue   # the bare forearms
        us = [uv[i].uv for i in poly.loop_indices]
        x0 = int(min(u.x for u in us) * w) - 1
        x1 = int(max(u.x for u in us) * w) + 2
        y0 = int(min(u.y for u in us) * h) - 1
        y1 = int(max(u.y for u in us) * h) + 2
        if x1 - x0 > w // 8 or y1 - y0 > h // 8:
            continue
        mask[max(0, y0):min(h, y1), max(0, x0):min(w, x1)] = True
    rgb = px[..., :3]
    mx = rgb.max(axis=2)
    mn = rgb.min(axis=2)
    sat = np.where(mx > 1e-4, (mx - mn) / np.maximum(mx, 1e-4), 0.0)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    # Dirt: a yellow-brown, not too saturated (the red tie and blue lanyard stay as they are).
    dirt = mask & (r >= g) & (g >= b) & (sat < 0.55) & (mx > 0.12) & ((g - b) > 0.25 * (r - b))
    grey = rgb.mean(axis=2, keepdims=True)
    clean = np.clip(grey * 0.35 + 0.62, 0.0, 0.92) * np.array([1.0, 0.99, 0.965], dtype=np.float32)
    k = np.where(dirt, 0.6, 0.0)[..., None]
    rgb[:] = rgb * (1.0 - k) + clean * k
    px[..., :3] = rgb
    print(f"[TempV2] shirt mask {mask.mean() * 100:.1f}% of the atlas, dirt cleaned on {dirt.mean() * 100:.1f}%",
          flush=True)
    out = bpy.data.images.new("temp_v2_body", w, h, alpha=False)
    out.pixels[:] = px.ravel()
    out.scale(TEX, TEX)
    out.pack()
    node.image = out
    node.interpolation = "Linear"
    # Only the colour reaches the game.
    bsdf = [n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"][0]
    for name in ("Metallic", "Roughness", "Normal"):
        for link in list(bsdf.inputs[name].links):
            mat.node_tree.links.remove(link)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.9


# --- the sheet over the face ---------------------------------------------------------------------------


def add_sheet(arm, body):
    deps = bpy.context.evaluated_depsgraph_get()
    tree = BVHTree.FromObject(body, deps)
    head = arm.data.bones[P + "Head"]
    top = arm.data.bones[P + "HeadTop_End"].head_local.z
    zc = (head.head_local.z + top) * 0.5 + 0.01
    nx, nz = 8, 11
    radius = 0.085
    verts = []
    uvs = []
    # The middle column's depth first: where the face's front is at each height.
    centre = []
    for j in range(nz):
        z = zc - SHEET_H / 2 + SHEET_H * j / (nz - 1)
        hit = tree.ray_cast(Vector((0, -1.0, z)), Vector((0, 1, 0)))
        centre.append(hit[0].y if hit[0] is not None else None)
    known = [c for c in centre if c is not None]
    front = min(known)
    # Paper laid on the face: each point just in front of the head, or curving back round it where the
    # head is narrower than the sheet; then smoothed (a sheet does not follow the nose), never into the head.
    depth = [[0.0] * nx for _ in range(nz)]
    limit = [[None] * nx for _ in range(nz)]
    for j in range(nz):
        z = zc - SHEET_H / 2 + SHEET_H * j / (nz - 1)
        mid = centre[j] if centre[j] is not None else front
        for i in range(nx):
            x = -SHEET_W / 2 + SHEET_W * i / (nx - 1)
            y = mid - SHEET_GAP + radius - math.sqrt(max(0.0, radius * radius - x * x))
            hit = tree.ray_cast(Vector((x, -1.0, z)), Vector((0, 1, 0)))
            if hit[0] is not None:
                limit[j][i] = hit[0].y - SHEET_GAP
                y = limit[j][i]
            depth[j][i] = y
    for _ in range(3):
        new = [row[:] for row in depth]
        for j in range(nz):
            for i in range(nx):
                ns = [depth[jj][ii] for jj, ii in ((j - 1, i), (j + 1, i), (j, i - 1), (j, i + 1))
                      if 0 <= jj < nz and 0 <= ii < nx]
                y = 0.5 * depth[j][i] + 0.5 * sum(ns) / len(ns)
                if limit[j][i] is not None:
                    y = min(y, limit[j][i])
                new[j][i] = y
        depth = new
    for j in range(nz):
        z = zc - SHEET_H / 2 + SHEET_H * j / (nz - 1)
        for i in range(nx):
            x = -SHEET_W / 2 + SHEET_W * i / (nx - 1)
            verts.append((x, depth[j][i], z))
            uvs.append((i / (nx - 1), j / (nz - 1)))
    faces = []
    for j in range(nz - 1):
        for i in range(nx - 1):
            a = j * nx + i
            # Front faces toward -Y (wound so the normal points at the viewer).
            faces.append((a, a + nx, a + nx + 1, a + 1))
    me = bpy.data.meshes.new("TempSheet")
    me.from_pydata(verts, [], faces)
    me.update()
    uvl = me.uv_layers.new(name=body.data.uv_layers.active.name)
    for poly in me.polygons:
        for li in poly.loop_indices:
            uvl.data[li].uv = uvs[me.loops[li].vertex_index]
    for poly in me.polygons:
        if poly.normal.y > 0:
            poly.flip()
    me.update()
    ob = bpy.data.objects.new("TempSheet", me)
    bpy.context.scene.collection.objects.link(ob)
    mat = bpy.data.materials.new("temp_face_sheet")
    mat.use_nodes = True
    bsdf = [n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"][0]
    tex = mat.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(str(HERE / "temp_face_sheet.png"))
    tex.image.pack()
    tex.interpolation = "Linear"
    mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.9
    me.materials.append(mat)
    for g in body.vertex_groups:
        ob.vertex_groups.new(name=g.name)
    ob.vertex_groups[P + "Head"].add(list(range(len(verts))), 1.0, "REPLACE")
    select_only([body, ob], body)
    bpy.ops.object.join()
    print(f"[TempV2] sheet over the face: centre z {zc:.3f}, front y {front:.3f}", flush=True)


# --- the motion ----------------------------------------------------------------------------------------


def rest_rot(arm, name):
    return arm.data.bones[name].matrix_local.to_quaternion()


def bone_dir(arm, name):
    b = arm.data.bones[name]
    return (b.tail_local - b.head_local).normalized()


def offsets(src, tgt):
    """Per target bone, the constant O with target pose = source pose @ O (armature space)."""
    out = {}
    for t, s in MAP.items():
        swing = Quaternion()
        if any(w in t for w in ARM_WORDS):
            swing = bone_dir(tgt, t).rotation_difference(bone_dir(src, s))
        out[t] = rest_rot(src, s).inverted() @ swing @ rest_rot(tgt, t)
    return out


def set_action(arm, action):
    arm.animation_data.action = action
    if action.slots:
        arm.animation_data.action_slot = action.slots[0]


def sample_clip(src, action):
    set_action(src, action)
    scene = bpy.context.scene
    first, last = (int(round(f)) for f in action.frame_range)
    frames = []
    for f in range(first, last + 1):
        scene.frame_set(f)
        rots = {s: src.pose.bones[s].matrix.to_quaternion() for s in set(MAP.values())}
        hips = src.pose.bones[P + "Hips"].head.copy()
        frames.append((hips, rots))
    return first, last, frames


def hierarchy(arm):
    order = []

    def walk(b):
        order.append(b.name)
        for c in b.children:
            walk(c)
    for b in arm.data.bones:
        if b.parent is None:
            walk(b)
    return order


def key_clip(tgt, src, name, frames, off):
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    tgt.animation_data.action = action
    tgt.animation_data.action_slot = action.slots.new('OBJECT', tgt.name)
    scene = bpy.context.scene
    src_hips_rest = src.data.bones[P + "Hips"].head_local
    tgt_hips = tgt.data.bones[P + "Hips"]
    k = tgt_hips.head_local.z / src_hips_rest.z
    order = [b for b in hierarchy(tgt) if b in MAP]
    prior = {}
    for frame, (hips, rots) in enumerate(frames, 1):
        world = {}
        for t in order:
            q = rots[MAP[t]] @ off[t]
            if t.endswith("LeftArm") or t.endswith("RightArm"):
                sign = 1.0 if "Left" in t else -1.0
                q = Quaternion((0, 1, 0), sign * ABDUCT) @ q
            world[t] = q
        for t in order:
            b = tgt.data.bones[t]
            if b.parent is not None and b.parent.name in world:
                parent_pose = world[b.parent.name]
                parent_rest = b.parent.matrix_local.to_quaternion()
            else:
                parent_pose = parent_rest = Quaternion()
            rel_rest = parent_rest.inverted() @ b.matrix_local.to_quaternion()
            basis = rel_rest.inverted() @ parent_pose.inverted() @ world[t]
            if b.parent is not None and b.parent.name not in world:
                # Only possible for bones under unmapped parents; none in this rig.
                raise RuntimeError(t)
            if t in prior:
                basis.make_compatible(prior[t])
            prior[t] = basis
            pb = tgt.pose.bones[t]
            pb.rotation_mode = "QUATERNION"
            pb.rotation_quaternion = basis
            pb.keyframe_insert("rotation_quaternion", frame=frame, group=t)
        pb = tgt.pose.bones[P + "Hips"]
        loc = rest_rot(tgt, P + "Hips").inverted() @ ((hips - src_hips_rest) * k)
        pb.location = loc
        pb.keyframe_insert("location", frame=frame, group=pb.name)
    print(f"[TempV2] {name}: {len(frames)} frames", flush=True)
    return action


def clearance(tgt, actions):
    """Closest the finger bone of either hand comes to its own thigh over idle and walk (metres, bone axes)."""
    scene = bpy.context.scene
    worst = 9.0
    for name in ("idle", "walk", "look"):
        set_action(tgt, actions[name])
        first, last = (int(round(f)) for f in actions[name].frame_range)
        for f in range(first, last + 1, 3):
            scene.frame_set(f)
            for side in ("Left", "Right"):
                fin = tgt.pose.bones[P + side + "HandMiddle4"]
                leg = tgt.pose.bones[P + side + "UpLeg"]
                for t in (0.0, 0.5, 1.0):
                    p = fin.head.lerp(fin.tail, t)
                    a, b = leg.head, leg.tail
                    ab = b - a
                    u = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
                    worst = min(worst, (a + ab * u - p).length)
    return worst


# --- the props -----------------------------------------------------------------------------------------


def place_props(src, tgt, today_props, off):
    placed = []
    for name, side in (("temp_stapler", "Right"), ("temp_notes", "Left")):
        world_src, _bone = today_props[name]
        hand = P + side + "Hand"
        sb = src.data.bones[hand]
        tb = tgt.data.bones[hand]
        # The prop's turn and grip, carried from today's hand (T-pose) to Meshy's (A-pose) by the arm's swing.
        swing = bone_dir(src, hand).rotation_difference(bone_dir(tgt, hand))
        rel = world_src.to_translation() - sb.head_local
        along = bone_dir(src, hand)
        a = rel.dot(along)
        perp = rel - along * a
        # Meshy's hands are long: the palm's middle is further from the wrist than today's.
        a_new = 0.085
        grip = tb.head_local + swing @ (along * a_new + perp * 1.6)
        rot = swing @ world_src.to_quaternion()
        objs = imported_gltf(HERE / f"{name}.glb")
        item, = objs
        item.name = name
        item.data.name = name
        item.parent = tgt
        item.parent_type = "BONE"
        item.parent_bone = hand
        bpy.context.view_layer.update()
        item.matrix_world = Matrix.Translation(grip) @ rot.to_matrix().to_4x4()
        placed.append(item)
        print(f"[TempV2] {name} in the {side.lower()} hand at {tuple(round(x, 3) for x in grip)}", flush=True)
    return placed


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = FPS
    src, today_props = load_today()
    tgt, body = load_meshy()
    clean_texture(body)
    add_sheet(tgt, body)
    print("[TempV2] bone map (Meshy <- today):", flush=True)
    for t, s in MAP.items():
        print(f"    {t} <- {s}", flush=True)
    skipped = sorted(b.name for b in src.data.bones if b.name not in MAP.values())
    print(f"[TempV2] today's bones not carried ({len(skipped)}): {', '.join(n.replace(P, '') for n in skipped)}",
          flush=True)
    print(f"[TempV2] Meshy bones left at rest: "
          f"{', '.join(b.name for b in tgt.data.bones if b.name not in MAP)}", flush=True)
    off = offsets(src, tgt)
    samples = {}
    for name in CLIPS:
        action = bpy.data.actions[name]
        first, last, frames = sample_clip(src, action)
        samples[name] = frames
        print(f"[TempV2] today's {name}: frames {first}-{last}", flush=True)
    src.animation_data.action = None
    if tgt.animation_data is None:
        tgt.animation_data_create()
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)
    actions = {name: key_clip(tgt, src, name, samples[name], off) for name in CLIPS}
    print(f"[TempV2] closest finger to thigh over idle, look and walk: {clearance(tgt, actions) * 100:.1f} cm "
          f"(bone axes)", flush=True)
    tgt.animation_data.action = None
    for pb in tgt.pose.bones:
        pb.matrix_basis = Matrix.Identity(4)
    scene.frame_set(1)
    props = place_props(src, tgt, today_props, off)
    bpy.data.objects.remove(src, do_unlink=True)
    select_only([tgt, body] + props, tgt)
    scene.frame_end = max(len(f) for f in samples.values())
    bpy.ops.export_scene.gltf(
        filepath=str(OUTPUT), export_format="GLB", use_selection=True,
        export_animation_mode="ACTIONS", export_force_sampling=True,
        export_optimize_animation_size=True, export_def_bones=False, export_all_influences=False,
        export_image_format="WEBP", export_image_quality=90,
    )
    print(f"[TempV2] wrote {OUTPUT} ({OUTPUT.stat().st_size // 1024} KB)", flush=True)


# --- pictures of the built file ------------------------------------------------------------------------


def render(folder):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = FPS
    objs = imported_gltf(OUTPUT)
    arm, = [o for o in objs if o.type == "ARMATURE"]
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "TEXTURE"
    scene.render.resolution_x = 640
    scene.render.resolution_y = 900
    world = bpy.data.worlds.new("grey")
    scene.world = world
    world.color = (0.45, 0.45, 0.45)
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.45, 0.45, 0.45, 1.0)
    # Rendered with a clear background, then laid on plain grey.
    scene.render.film_transparent = True

    def shoot(path):
        scene.render.filepath = str(path)
        bpy.ops.render.render(write_still=True)
        img = bpy.data.images.load(str(path))
        px = np.array(img.pixels[:], dtype=np.float32).reshape(-1, 4)
        a = px[:, 3:4]
        px[:, :3] = px[:, :3] * a + 0.45 * (1.0 - a)
        px[:, 3] = 1.0
        img.pixels[:] = px.ravel()
        img.filepath_raw = str(path)
        img.file_format = "PNG"
        img.save()
        bpy.data.images.remove(img)
        print(f"[TempV2] rendered {path}", flush=True)
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2.1
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    views = {"front": (Vector((0, -4, 0.95)), (math.pi / 2, 0, 0)),
             "side": (Vector((4, 0, 0.95)), (math.pi / 2, 0, math.pi / 2))}
    shots = {"walk": 0.5, "reach": 1.0, "idle": 0.0}
    for clip, at in shots.items():
        action = bpy.data.actions[clip]
        set_action(arm, action)
        first, last = action.frame_range
        scene.frame_set(int(round(first + (last - first) * at)))
        for view, (loc, rot) in views.items():
            cam.location = loc
            cam.rotation_euler = rot
            shoot(folder / f"temp-{clip}-{view}.png")
    # Close up: the face (front and side) at rest, and the stapler hand at the top of the reach.
    scene.render.resolution_x = 600
    scene.render.resolution_y = 600
    cam_data.ortho_scale = 0.45
    set_action(arm, bpy.data.actions["idle"])
    scene.frame_set(1)
    for view, (loc, rot) in views.items():
        cam.location = Vector((loc.x, loc.y, 1.62))
        cam.rotation_euler = rot
        shoot(folder / f"temp-face-{view}.png")
    action = bpy.data.actions["reach"]
    set_action(arm, action)
    scene.frame_set(int(round(action.frame_range[1])))
    stapler = [o for o in bpy.data.objects if o.name.startswith("temp_stapler")][0]
    at = stapler.matrix_world.to_translation()
    for view, (loc, rot) in views.items():
        cam.location = at + Vector((loc.x, loc.y, 0.0)).normalized() * 3.0
        cam.rotation_euler = rot
        shoot(folder / f"temp-hand-reach-{view}.png")


if __name__ == "__main__":
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if args[:1] == ["--render"]:
        render(args[1])
    else:
        main()
