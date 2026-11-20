"""Build the Orderly's second model (godot/assets/entities/orderly_v2.glb) from the Meshy figure.

The mesh, its texture and its skeleton come from Meshy (assets_src/meshy/orderly/orderly_meshy_rigged.glb,
made from orderly_concept.jpg and rigged by Meshy on a Mixamo-style skeleton). This script:

  * renames the skeleton's bones to the names the game's view drives (orderly_view.gd: hips, spine,
    spine1, spine2, neck, head, clavicle/upperarm/forearm/hand/thigh/shin/foot .L/.R), and sets the
    spine chain's roll like today's rig, so "a turn about the bone's own x folds it forward" still holds;
  * lengthens the upper and lower arms so the hanging hands reach below the knee (the judge's note) and
    the arms are as long for the height as today's Orderly's (the owner: "long arms and gaunt");
  * scales it so it stands exactly as tall as today's orderly.glb in the idle pose the view plays, the
    lowest point on the floor, ankles where today's are, facing the same way (+Z in glTF);
  * adds the four skirt bones the view folds at a door (skirt.F/B.L/R) and moves the gown below the
    crotch off the leg bones onto them, so a stride does not drag the strips with the shins (the judge's note);
  * bakes every clip today's model has, under the same names and with the same number of frames:
      idle, walk, reach, duck, still        today's hand-made clips, transferred from orderly.glb
      mixamo_idle, mixamo_walk, mixamo_reach  today's approved blends of those with the owner's Mixamo
                                            takes, transferred the same way (see bake_all for why)
      mixamo_roar, bellydance               the Mixamo takes themselves, retargeted by bone name
                                            (Meshy's skeleton uses Mixamo's names) as retarget_mixamo.py does
    The transfer is by bone name: each bone takes the source bone's turn away from its rest, in world
    space, after first lining its rest up with the source bone's rest direction (arms, spine, legs), so
    the stoop and the long hanging arms of today's figure carry over. The hips' height is corrected each
    frame so the figure's lowest point is as high as in today's clip on that frame (no sinking, no floating).
  * shrinks the texture to 1024 px (WebP), nearest filtering like the other residents.

Nothing random. Run from the checkout root (Blender 5.3):

  tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 \
      --python assets_src/blender/orderly/build_orderly_v2.py -- \
      --out godot/assets/entities/orderly_v2.glb --mixamo-dir .local/orderly-mixamo-2026-11-18 [--render DIR]

The raw Mixamo takes are never copied into the repository: only the baked clips ship in the glb.
"""
import argparse
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Quaternion, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
FPS = 24
TEX = 1024

# --- names -----------------------------------------------------------------------------------------
NAMES = {"Hips": "hips", "Spine": "spine", "Spine1": "spine1", "Spine2": "spine2", "Neck": "neck",
         "Head": "head", "HeadTop_End": "head_end", "headfront": "head_front"}
for _s, _w in (("L", "Left"), ("R", "Right")):
    for _game, _mix in (("clavicle", "Shoulder"), ("upperarm", "Arm"), ("forearm", "ForeArm"), ("hand", "Hand"),
                        ("fingers", "HandMiddle4"), ("middle1", "HandMiddle1"), ("thigh", "UpLeg"),
                        ("shin", "Leg"), ("foot", "Foot"), ("toe", "ToeBase"), ("toe_end", "Toe_End")):
        NAMES[_w + _mix] = f"{_game}.{_s}"


def game_name(name):
    return NAMES.get(name.split(":")[-1])


# The bones whose rest direction is lined up with the source's before the turn is copied. The others
# take their parent's line-up (hands, fingers, toes) or none (hips, feet: they stay as the mesh stands).
AIM_CHILD = {"spine": "spine1", "spine1": "spine2", "spine2": "neck", "neck": "head", "head": "head_end"}
for _s in (".L", ".R"):
    AIM_CHILD.update({"clavicle" + _s: "upperarm" + _s, "upperarm" + _s: "forearm" + _s,
                      "forearm" + _s: "hand" + _s, "thigh" + _s: "shin" + _s, "shin" + _s: "foot" + _s})
NO_ALIGN = {"hips", "foot.L", "foot.R"}
# The bones retarget_mixamo.py blends (its BONES table).
MIX_BONES = {"hips", "spine", "spine1", "spine2", "neck", "head"}
for _s in (".L", ".R"):
    MIX_BONES.update(b + _s for b in ("clavicle", "upperarm", "forearm", "hand", "thigh", "shin", "foot"))
ARMS = ("clavicle.", "upperarm.", "forearm.", "hand.")
LEGS = ("thigh.", "shin.", "foot.")
SKIRT = ("skirt.F.L", "skirt.F.R", "skirt.B.L", "skirt.B.R")

SOURCES = {"idle": "Zombie Idle.fbx", "walk": "Scary Clown Walk.fbx", "fast_walk": "Scary Clown Walk (1).fbx",
           "push": "Push.fbx", "reach": "Zombie Attack (1).fbx", "roar": "Yelling Out.fbx",
           "bellydance": "Bellydancing.fbx"}


def log(*a):
    print("[v2]", *a, flush=True)


def rot3(m):
    return m.to_3x3().normalized()


def wq(obj, m):
    """World rotation of an armature-space matrix."""
    return (rot3(obj.matrix_world) @ rot3(m)).to_quaternion()


def wp(obj, v):
    return obj.matrix_world @ v


# --- import ----------------------------------------------------------------------------------------
def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = set(bpy.data.objects) - before
    arm = next(o for o in new if o.type == "ARMATURE")
    mesh = next(o for o in new if o.type == "MESH" and o.find_armature() is arm)
    for o in new:
        if o not in (arm, mesh) and o.type == "MESH" and o.parent is None and not o.users_collection == ():
            if o.find_armature() is None and len(o.data.vertices) < 100:  # the importer's bone shape
                bpy.data.objects.remove(o, do_unlink=True)
    return arm, mesh


def edit(arm):
    bpy.ops.object.mode_set(mode="OBJECT")
    for o in bpy.context.selected_objects:
        o.select_set(False)
    bpy.context.view_layer.objects.active = arm
    arm.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")


def apply_transform(objs, **kw):
    bpy.ops.object.mode_set(mode="OBJECT") if bpy.context.object and bpy.context.object.mode != "OBJECT" else None
    for o in bpy.context.selected_objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(**kw)
    for o in objs:
        o.select_set(False)


def rest_head(arm, name):
    return wp(arm, arm.data.bones[name].head_local)


def mesh_top(mesh):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = mesh.evaluated_get(dg)
    me = ev.to_mesh()
    co = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    mw = np.array(ev.matrix_world)
    z = co @ mw[2, :3] + mw[2, 3]
    ev.to_mesh_clear()
    return float(z.max()), float(z.min())


def reset_pose(arm):
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
        pb.scale = (1, 1, 1)


def set_action(arm, act):
    ad = arm.animation_data or arm.animation_data_create()
    for t in ad.nla_tracks:
        t.mute = True
    ad.action = act
    if act is not None and act.slots and getattr(ad, "action_slot", None) is None:
        ad.action_slot = act.slots[0]


# --- the Meshy figure: names, roll, size, arms, origin, skirt -------------------------------------------
def prepare(arm, mesh):
    arm.name, arm.data.name = "Orderly_Rig", "Orderly_Rig"
    world = mesh.matrix_world.copy()
    mesh.parent = None  # moved and scaled on its own beside the rig (the armature modifier does the skinning)
    mesh.matrix_world = world
    mesh.name, mesh.data.name = "Orderly", "Orderly"
    mapping = []
    for b in list(arm.data.bones):
        g = game_name(b.name)
        if g is None:
            raise ValueError(f"no game name for Meshy bone {b.name}")
        mapping.append((b.name, g))
        b.name = g
    for a, g in mapping:
        log(f"bone {a:28s} -> {g}")
    vgs = {v.name for v in mesh.vertex_groups}
    missing = {g for _, g in mapping} - vgs
    if any(not n.startswith(("head_", "toe_end", "fingers")) for n in missing):
        raise ValueError(f"vertex groups not renamed: {missing}")
    edit(arm)
    for name in ("hips", "spine", "spine1", "spine2", "neck", "head"):
        arm.data.edit_bones[name].align_roll(Vector((0, -1, 0)))  # local x = the figure's left, like today's rig
    bpy.ops.object.mode_set(mode="OBJECT")


def lengthen_arms(arm, mesh, arm_share, height):
    """Stretch the upper and lower arm (not the hand) so a hanging hand's fingertips end below the knee."""
    co = np.empty(len(mesh.data.vertices) * 3)
    mesh.data.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    scales = {}
    for s in (".L", ".R"):
        gi = {mesh.vertex_groups[n].index for n in ("hand" + s, "fingers" + s) if n in mesh.vertex_groups}
        wrist = rest_head(arm, "hand" + s)
        along = (wp(arm, arm.data.bones["hand" + s].tail_local) - wrist).normalized()
        dist = [(Vector(co[v.index]) - wrist).dot(along) for v in mesh.data.vertices
                if sum(g.weight for g in v.groups if g.group in gi) > 0.5]
        # The fingertips: how far the hand's own skin runs on past the wrist, along the hand.
        tip = float(np.percentile(dist, 99.5))
        log(f"hand{s}: {len(dist)} vertices, fingertips {tip:.3f} past the wrist")
        sh, el = rest_head(arm, "upperarm" + s), rest_head(arm, "forearm" + s)
        upper, fore = (el - sh).length, (wrist - el).length
        knee = rest_head(arm, "shin" + s).z
        target = knee - 0.12
        below_knee = (sh.z - target - tip) / (upper + fore)
        # and at least as long, for its height, as today's Orderly's upper and lower arm ("long arms and gaunt")
        like_today = arm_share * height / (upper + fore)
        scales[s] = min(1.25, max(1.0, below_knee, like_today))
        log(f"arm{s}: shoulder {sh.z:.3f} upper {upper:.3f} fore {fore:.3f} hand {tip:.3f} knee {knee:.3f}: "
            f"hanging tip {sh.z - upper - fore - tip:.3f}; below the knee needs x{below_knee:.3f}, today's "
            f"share of the height x{like_today:.3f} -> stretch {scales[s]:.3f}")
    s = 0.5 * (scales[".L"] + scales[".R"])  # one stretch for both arms: they stay a pair
    reset_pose(arm)
    for side in (".L", ".R"):
        for name in ("forearm" + side, "hand" + side):
            arm.data.bones[name].inherit_scale = "NONE"
        arm.pose.bones["upperarm" + side].scale = (1, s, 1)
        arm.pose.bones["forearm" + side].scale = (1, s, 1)
    bpy.context.view_layer.update()
    bpy.context.view_layer.objects.active = mesh
    mod = next(m for m in mesh.modifiers if m.type == "ARMATURE")
    bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="POSE")
    bpy.ops.pose.select_all(action="SELECT")
    bpy.ops.pose.armature_apply(selected=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    for side in (".L", ".R"):
        for name in ("forearm" + side, "hand" + side):
            arm.data.bones[name].inherit_scale = "FULL"
    reset_pose(arm)
    m = mesh.modifiers.new("Armature", "ARMATURE")
    m.object = arm
    log(f"arms stretched x{s:.3f}")
    return s


def place(arm, mesh, scale, ankle_y):
    """Uniform scale, then feet on the floor, ankles centred left-right and at today's depth."""
    for o in (arm, mesh):
        o.scale = (scale, scale, scale)
    bpy.context.view_layer.update()
    apply_transform([arm, mesh], location=False, rotation=False, scale=True)
    bpy.context.view_layer.update()
    _, low = mesh_top(mesh)
    al, ar = rest_head(arm, "foot.L"), rest_head(arm, "foot.R")
    shift = Vector((-(al.x + ar.x) / 2, ankle_y - (al.y + ar.y) / 2, -low))
    for o in (arm, mesh):
        o.location = shift
    bpy.context.view_layer.update()
    apply_transform([arm, mesh], location=True, rotation=False, scale=False)


def add_skirt(arm, mesh, img):
    """Four bones inside the skirt, as today's rig has, and the torn hem moved off the legs onto them."""
    hips = rest_head(arm, "hips")
    hip_z = 0.5 * (rest_head(arm, "thigh.L").z + rest_head(arm, "thigh.R").z)
    knee_z = 0.5 * (rest_head(arm, "shin.L").z + rest_head(arm, "shin.R").z)
    half = 0.5 * abs(rest_head(arm, "thigh.L").x - rest_head(arm, "thigh.R").x)
    edit(arm)
    eb = arm.data.edit_bones
    for name in SKIRT:
        x = half * (1 if name.endswith(".L") else -1)
        y = hips.y + (-0.09 if ".F." in name else 0.10)
        b = eb.new(name)
        b.head = Vector((x, y, hip_z - 0.12))
        b.tail = Vector((x * 1.3, y + (y - hips.y) * 0.3, knee_z))
        b.roll = 0.0
        b.parent = eb["hips"]
    bpy.ops.object.mode_set(mode="OBJECT")
    for name in SKIRT:
        mesh.vertex_groups.new(name=name)
    # Meshy weighted most of the gown to the thighs (and some to the shins), so a stride dragged the cloth into a
    # bag at the knees. Gown or leg is decided per UV island (Meshy's mesh is split along its UV seams, so every
    # island is one piece of the texture): skin islands are warm (red over green), cloth islands are the gown's
    # grey-green. Below the crotch, gown vertices then follow the hips through the skirt bones, with at most
    # 0.3 from the thigh on their own side and nothing from the shins or feet; leg vertices follow their own
    # leg only. The change fades in over 15 cm below the crotch so the gown does not tear there.
    me = mesh.data
    n = len(me.vertices)
    co = np.empty(n * 3)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    pairs = np.empty(len(me.edges) * 2, dtype=np.int64)
    me.edges.foreach_get("vertices", pairs)
    pairs = pairs.reshape(-1, 2)
    root = np.arange(n)

    def find(a):
        while root[a] != a:
            root[a] = root[root[a]]
            a = root[a]
        return a
    for a, b in pairs:
        ra, rb = find(a), find(b)
        if ra != rb:
            root[ra] = rb
    island = np.array([find(i) for i in range(n)])
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    px = px.reshape(h, w, 4)
    uv = np.zeros((n, 2))
    data = me.uv_layers.active.data
    for loop in me.loops:
        uv[loop.vertex_index] = data[loop.index].uv
    rgb = px[np.clip((uv[:, 1] * h).astype(int), 0, h - 1), np.clip((uv[:, 0] * w).astype(int), 0, w - 1), :3]
    warm = rgb[:, 0] - rgb[:, 1]
    total = np.zeros(n)
    count = np.zeros(n)
    np.add.at(total, island, warm)
    np.add.at(count, island, 1)
    # A warm island far from the leg bones is a dirty strip of gown, not leg: the legs are thin.
    gap = np.full(n, 1.0)
    for s in (".L", ".R"):
        for a, b in (("thigh", "shin"), ("shin", "foot"), ("foot", "toe")):
            a, b = np.array(rest_head(arm, a + s)), np.array(rest_head(arm, b + s))
            ab = b - a
            t = np.clip(((co - a) @ ab) / (ab @ ab), 0.0, 1.0)
            gap = np.minimum(gap, np.linalg.norm(co - (a + t[:, None] * ab), axis=1))
    # (Islands can run from the back down a leg, so the distance is the vertex's own.)
    # The feet are skin whatever their colour: the gown ends far above them.
    skin = (((total / np.maximum(count, 1))[island] > 0.03) & (gap < 0.16)) | (co[:, 2] < 0.25)

    def smooth(e0, e1, x):
        t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
        return t * t * (3 - 2 * t)

    top = hip_z - 0.05
    k = smooth(0.0, 0.15, top - co[:, 2])
    left = smooth(-0.05, 0.05, co[:, 0] - hips.x)
    front = smooth(0.05, -0.05, co[:, 1] - hips.y)
    share = {"skirt.F.L": front * left, "skirt.F.R": front * (1 - left),
             "skirt.B.L": (1 - front) * left, "skirt.B.R": (1 - front) * (1 - left)}
    vg = mesh.vertex_groups
    side_of = {}
    for s in (".L", ".R"):
        for g in ("thigh", "shin", "foot", "toe", "toe_end"):
            if g + s in vg:
                side_of[vg[g + s].index] = (g, s)
    cloth_moved = legs_cleaned = 0
    for v in me.vertices:
        i = v.index
        if k[i] <= 0.0:
            continue
        leg = [(g.group, g.weight) for g in v.groups if g.group in side_of]
        wl = sum(wt for _, wt in leg)
        if wl <= 0.0:
            continue
        if skin[i]:
            own = ".L" if co[i, 0] > hips.x else ".R"
            for gi, wt in leg:
                bone, s = side_of[gi]
                if s != own:  # the other leg's share goes to the same bone of its own leg
                    vg[gi].add([i], 0.0, "REPLACE")
                    vg[bone + own].add([i], wt, "ADD")
                    legs_cleaned += 1
            continue
        thigh = min(0.3, wl)
        for gi, wt in leg:
            vg[gi].add([i], wt * (1.0 - k[i]), "REPLACE")
        vg["thigh.L"].add([i], k[i] * thigh * left[i], "ADD")
        vg["thigh.R"].add([i], k[i] * thigh * (1 - left[i]), "ADD")
        for g, sh in share.items():
            if sh[i] > 0.0:
                vg[g].add([i], k[i] * (wl - thigh) * float(sh[i]), "ADD")
        cloth_moved += 1
    below = co[:, 2] < top
    log(f"below the crotch: {int((below & skin).sum())} skin vertices, {int((below & ~skin).sum())} cloth vertices "
        f"in {len(set(island[below]))} islands; {cloth_moved} cloth vertices moved to the hips and skirt, "
        f"{legs_cleaned} leg weights moved to their own leg")
    moved = cloth_moved
    log(f"skirt bones added; {moved} hem vertices moved off the legs")


# --- sampling the sources ----------------------------------------------------------------------------
class Rig:
    """One armature's rest, in world space, keyed by game bone name."""

    def __init__(self, obj, names=None, mesh=None):
        self.obj = obj
        self.mesh = mesh  # its skinned mesh, for where the figure touches the floor
        self.names = names or {b.name: b.name for b in obj.data.bones}  # bone -> game name
        self.bone = {g: obj.data.bones[b] for b, g in self.names.items()}
        self.pose = {g: obj.pose.bones[b] for b, g in self.names.items()}
        self.rest = {g: wq(obj, b.matrix_local) for g, b in self.bone.items()}

    def head(self, g):
        return wp(self.obj, self.bone[g].head_local)

    def aim(self, g):
        c = AIM_CHILD.get(g)
        if c is not None and c in self.bone:
            d = self.head(c) - self.head(g)  # today's neck runs on through neck1 to the head: the same line
        else:
            d = wp(self.obj, self.bone[g].tail_local) - self.head(g)
        return d.normalized() if d is not None and d.length > 1e-6 else None

    def sample(self):
        """Each bone's turn from rest (world) and the hips' world position, at the current frame."""
        motion = {g: wq(self.obj, pb.matrix) @ self.rest[g].inverted() for g, pb in self.pose.items()}
        hips = wp(self.obj, self.pose["hips"].head)
        return motion, hips


def alignment(target, source):
    al = {}
    for b in target.obj.data.bones:  # parents first
        g = b.name
        if g in NO_ALIGN or g in SKIRT or b.parent is None:
            al[g] = Quaternion()
        elif g in AIM_CHILD and g in source.bone:
            al[g] = target.aim(g).rotation_difference(source.aim(g))
        else:
            al[g] = al[b.parent.name]
    return al


def transfer(target, al, motion, only=None):
    """Local rotations for every target bone from the source's world turns (retarget_mixamo.py's formula)."""
    deform, local = {}, {}
    for b in target.obj.data.bones:
        g = b.name
        parent = deform[b.parent.name] if b.parent else Quaternion()
        if g in motion and (only is None or g in only):
            deform[g] = motion[g] @ al[g]
        else:
            deform[g] = parent
        rest = target.rest[g]
        local[g] = (parent @ rest).inverted() @ deform[g] @ rest
    return local


def read_old(old, name, frames):
    act = bpy.data.actions[name]
    set_action(old.obj, act)
    out = []
    for f in range(frames):
        bpy.context.scene.frame_set(f)
        motion, hips = old.sample()
        out.append((motion, hips, mesh_top(old.mesh)[1]))  # the lowest point of the figure: a foot
    set_action(old.obj, None)
    return out


def read_mixamo(path, frames, portion=1.0):
    """retarget_mixamo.read_source, sampling world turns by game bone name."""
    scene = bpy.context.scene
    scene.render.fps = 30  # the downloads are at 30 fps
    previous, actions = set(bpy.data.objects), set(bpy.data.actions)
    bpy.ops.import_scene.fbx(filepath=str(path))
    objects = set(bpy.data.objects) - previous
    src, = [o for o in objects if o.type == "ARMATURE"]
    if len(src.data.bones) != 25 or not any(o.type == "MESH" and o.name.startswith("Orderly")
                                            and len(o.data.vertices) == 14458 for o in objects):
        raise ValueError(f"{path} is not from the Orderly's Mixamo rig")
    names = {}
    for b in src.data.bones:
        g = game_name(b.name)
        if g is not None:
            names[b.name] = g
    rig = Rig(src, names)
    action = src.animation_data.action
    start, end = action.frame_range
    span = (end - start) * portion
    if frames is None:
        frames = min(round(span * FPS / 30), 9 * FPS) + 1
        span = (frames - 1) * 30 / FPS
    out = []
    for i in range(frames):
        fr = start + span * i / (frames - 1)
        scene.frame_set(math.floor(fr), subframe=fr % 1)
        out.append(rig.sample())
    for o in objects:
        if o is not src:
            bpy.data.objects.remove(o, do_unlink=True)
    scene.render.fps = FPS
    return out, rig, src, set(bpy.data.actions) - actions


# --- baking -------------------------------------------------------------------------------------------
class Baker:
    def __init__(self, target, old):
        self.t = target
        self.old = old
        self.hip_ratio = (target.head("thigh.L").z) / (old.head("thigh.L").z)
        reset_pose(target.obj)
        bpy.context.view_layer.update()
        self.rest_low = mesh_top(target.mesh)[1]
        self.hips_rest = target.head("hips")
        self.hips_axes = target.rest["hips"].inverted()

    def apply(self, local, hips_loc):
        for g, pb in self.t.pose.items():
            pb.rotation_mode = "QUATERNION"
            pb.rotation_quaternion = local[g]
            pb.location = (0, 0, 0)
            pb.scale = (1, 1, 1)
        self.t.pose["hips"].location = hips_loc

    def plant(self, local, hips_world_delta, lift):
        """Set the pose and raise or lower the hips so the lowest point is `lift` above where it is at rest,
        as in today's clip on the same frame (feet on the floor, never sunk into it)."""
        loc = self.hips_axes @ hips_world_delta
        self.apply(local, loc)
        bpy.context.view_layer.update()
        low = mesh_top(self.t.mesh)[1]
        dz = (self.rest_low + lift) - low
        loc = self.hips_axes @ (hips_world_delta + Vector((0, 0, dz)))
        self.apply(local, loc)
        return {g: (local[g].copy(), (loc.copy() if g == "hips" else Vector()), Vector((1, 1, 1)))
                for g in self.t.pose}


def bake_action(arm, name, poses, interp="LINEAR"):
    """retarget_mixamo.bake_action: one key per frame from frame 1, sign-continuous quaternions."""
    ad = arm.animation_data or arm.animation_data_create()
    act = bpy.data.actions.new(name + "#v2")  # today's clips (imported) hold the plain names until export
    ad.action = act
    bpy.context.preferences.edit.keyframe_new_interpolation_type = interp
    previous = {}
    for frame, pose in enumerate(poses, 1):
        for pb in arm.pose.bones:
            rotation, location, scale = pose[pb.name]
            if pb.name in previous and rotation.dot(previous[pb.name]) < 0.0:
                rotation = -rotation
            previous[pb.name] = rotation
            pb.rotation_mode = "QUATERNION"
            pb.rotation_quaternion = rotation
            pb.location = location
            pb.scale = scale
            for path in ("rotation_quaternion", "location", "scale"):
                pb.keyframe_insert(path, frame=frame, group=pb.name)
    act.use_fake_user = True
    track = ad.nla_tracks.new()
    track.name = name
    track.strips.new(name, 1, act)
    track.mute = True
    ad.action = None
    return act


def old_frames(old, name):
    act = bpy.data.actions[name]
    s, e = act.frame_range
    return int(round(e - s)) + 1


def bake_all(target, old, mixamo_dir):
    al_old = alignment(target, old)
    bk = Baker(target, old)
    old_rest_low = old.rest_low
    old_hips = old.head("hips")
    made = {}

    def from_old(name):
        n = old_frames(old, name)
        out = []
        for motion, hips, low in read_old(old, name, n):
            local = transfer(target, al_old, motion)
            out.append((local, (hips - old_hips) * bk.hip_ratio, low - old_rest_low))
        return out

    # Today's hand-authored clips, transferred as they are.
    for name in ("idle", "walk", "reach", "duck", "still"):
        frames = from_old(name)
        poses = [bk.plant(*f) for f in frames]
        made[name] = bake_action(target.obj, name, poses, "CONSTANT" if name in ("walk", "reach", "duck", "still") else "LINEAR")
        log(f"clip {name}: {len(poses)} frames from today's hand-made clip")

    # The idle, walk and reach the view plays: today's approved blends of the hand-made clips with the Mixamo
    # takes (retarget_mixamo.py), transferred bone by bone like the hand-made ones. Blending the takes afresh
    # in each bone's own space does not carry over: the Meshy rest stands straight where today's rest stoops,
    # so a quarter of the take straightened the stoop (the walk stood 5.6 cm taller, the back 6 to 9 degrees
    # off today's), and the doorway rules are measured on today's height.
    for name in ("mixamo_idle", "mixamo_walk", "mixamo_reach"):
        poses = [bk.plant(*f) for f in from_old(name)]
        bake_action(target.obj, name, poses)
        log(f"clip {name}: {len(poses)} frames from today's blend with {SOURCES[name[7:]]}")

    if not mixamo_dir:
        log("no --mixamo-dir: transferring today's roar and dance instead of the takes")
        for name in ("mixamo_roar", "bellydance"):
            bake_action(target.obj, name, [{g: (local[g].copy(), Vector(), Vector((1, 1, 1))) for g in target.pose}
                                           for local, _, _ in from_old(name)])
        return

    # The roar and the dance: the Mixamo takes themselves, retargeted by bone name as retarget_mixamo.py does.
    takes = {}
    for name, size, portion in (("roar", 20, 0.54), ("bellydance", None, 1.0)):
        samples, rig, src, acts = read_mixamo(os.path.join(mixamo_dir, SOURCES[name]), size, portion)
        if not takes:
            for b, g in sorted(rig.names.items()):
                log(f"take bone {b:28s} -> {g}")
        al = alignment(target, rig)
        takes[name] = [transfer(target, al, m, MIX_BONES) for m, _ in samples], [h for _, h in samples]
        bpy.data.objects.remove(src, do_unlink=True)
        for a in acts:
            bpy.data.actions.remove(a)
        log(f"take {SOURCES[name]}: {len(samples)} samples")

    neutral = {g: (Quaternion(), Vector(), Vector((1, 1, 1))) for g in target.pose}
    first = takes["roar"][0][0]
    poses = []
    for local in takes["roar"][0]:
        pose = dict(neutral)
        for bone in ("spine", "spine1", "spine2", "neck", "head"):
            pose[bone] = (first[bone].inverted() @ local[bone], Vector(), Vector((1, 1, 1)))
        poses.append(pose)
    bake_action(target.obj, "mixamo_roar", poses)
    log(f"clip mixamo_roar: {len(poses)} frames, head and spine of {SOURCES['roar']}")

    poses = []
    zero = takes["bellydance"][1][0]
    for local, hips in zip(*takes["bellydance"]):
        pose = dict(neutral)
        for bone in MIX_BONES:
            rotation = Quaternion().slerp(local[bone], 0.86) if bone.startswith(ARMS) else local[bone]
            pose[bone] = (rotation, Vector(), Vector((1, 1, 1)))
        travel = hips - zero
        shift = Vector(tuple(max(-0.12, min(0.12, v * 0.55)) for v in travel))
        pose["hips"] = (local["hips"], bk.hips_axes @ shift, Vector((1, 1, 1)))
        poses.append(pose)
    bake_action(target.obj, "bellydance", poses)
    log(f"clip bellydance: {len(poses)} frames from {SOURCES['bellydance']}")


def directions(rig, action, frame):
    set_action(rig.obj, action)
    bpy.context.scene.frame_set(frame)
    out = {}
    for g in ("spine2", "upperarm.L", "forearm.L", "upperarm.R", "forearm.R", "thigh.L", "shin.L", "thigh.R", "shin.R"):
        c = AIM_CHILD[g]
        out[g] = (rig.pose[c].head - rig.pose[g].head).normalized()
    for g in SKIRT:  # the cloth bones: their turn from rest, applied to straight down
        out[g] = (wq(rig.obj, rig.pose[g].matrix) @ rig.rest[g].inverted()) @ Vector((0, 0, -1))
    set_action(rig.obj, None)
    return out


def leg_report(rig, action, frames, offset):
    """The legs on the bare skeleton: each thigh's swing (degrees, + = forward), each knee's bend (degrees,
    + = the shin folds back behind the thigh, as a knee does), and the feet under the hips."""
    for f in frames:
        set_action(rig.obj, action)
        bpy.context.scene.frame_set(f + offset)
        hips = rig.pose["hips"].head
        parts = []
        for s in (".L", ".R"):
            hip, knee, ankle = (rig.pose[b + s].head for b in ("thigh", "shin", "foot"))
            th, sh = (knee - hip).normalized(), (ankle - knee).normalized()
            swing = math.degrees(math.atan2(-th.y, -th.z))  # the figure faces -y in Blender
            bend = math.degrees(math.atan2(-(sh.y * th.z - sh.z * th.y), sh.dot(th)))
            parts.append(f"{s[1]}: thigh {swing:+5.1f} knee {bend:+5.1f} foot x {ankle.x:+.2f} y {ankle.y - hips.y:+.2f}")
        log(f"legs {action.name.split('#')[0]} frame {f}: " + "; ".join(parts))
    set_action(rig.obj, None)


def check_clips(target, old):
    for f, rig in ((0, old), (1, target)):
        leg_report(rig, bpy.data.actions["mixamo_walk" + ("#v2" if rig is target else "")], (0, 12, 24, 36), f)
    """Every transferred clip points the spine, arms and legs where today's does (degrees off, worst)."""
    for name in ("idle", "walk", "reach", "duck", "still", "mixamo_idle", "mixamo_walk", "mixamo_reach"):
        worst, at = 0.0, ""
        for f in range(0, old_frames(old, name), 4):
            a = directions(old, bpy.data.actions[name], f)
            b = directions(target, bpy.data.actions[name + "#v2"], f + 1)
            for g in a:
                d = math.degrees(a[g].angle(b[g]))
                if d > worst:
                    worst, at = d, f"{g} frame {f}"
        log(f"check {name}: worst {worst:.1f} degrees from today's ({at})")
        if os.environ.get("V2_DEBUG"):
            a = directions(old, bpy.data.actions[name], 24)
            b = directions(target, bpy.data.actions[name + "#v2"], 25)
            for g in ("thigh.L", "skirt.F.L", "skirt.B.R"):
                log(f"  {name} {g} today's {tuple(round(v, 2) for v in a[g])} new {tuple(round(v, 2) for v in b[g])}")


# --- texture --------------------------------------------------------------------------------------------
def texture(mesh):
    mat = mesh.data.materials[0]
    mat.name = "Orderly_v2_mat"
    img = None
    for n in mat.node_tree.nodes:
        if n.type == "TEX_IMAGE":
            n.interpolation = "Closest"
            img = n.image
    img.name = "Orderly_v2_albedo"
    return mat, img


# --- review renders ----------------------------------------------------------------------------------------
def render(arm, mesh, out):
    os.makedirs(out, exist_ok=True)
    scn = bpy.context.scene
    scn.render.engine = "BLENDER_WORKBENCH"
    scn.display.shading.light = "STUDIO"
    scn.display.shading.color_type = "TEXTURE"
    scn.render.resolution_x, scn.render.resolution_y = 720, 960
    scn.render.film_transparent = False
    world = bpy.data.worlds.new("w") if not scn.world else scn.world
    scn.world = world
    world.color = (0.214, 0.214, 0.214)  # mid grey
    cd = bpy.data.cameras.new("cam")
    cd.type = "ORTHO"
    cd.ortho_scale = 3.3
    cam = bpy.data.objects.new("cam", cd)
    scn.collection.objects.link(cam)
    scn.camera = cam

    def shot(fname, action, frame, side):
        set_action(arm, bpy.data.actions[action] if action else None)
        if action is None:
            reset_pose(arm)
        scn.frame_set(frame)
        if side:
            cam.location = (-6.0, 0.0, 1.4)
            cam.rotation_euler = (math.radians(90), 0, math.radians(-90))
        else:
            cam.location = (0.0, -6.0, 1.4)
            cam.rotation_euler = (math.radians(90), 0, 0)
        scn.render.filepath = os.path.join(out, fname)
        bpy.ops.render.render(write_still=True)
        log("render", scn.render.filepath)

    shot("orderly-front.png", "mixamo_idle", 1, False)
    shot("orderly-side.png", "mixamo_idle", 1, True)
    shot("orderly-rest-front.png", None, 1, False)
    for i, frame in enumerate((1, 13, 25, 37)):  # the walk at four phases (49 frames a stride)
        shot(f"orderly-walk-{i + 1}-side.png", "mixamo_walk", frame, True)
        shot(f"orderly-walk-{i + 1}-front.png", "mixamo_walk", frame, False)
    shot("orderly-reach.png", "mixamo_reach", 17, True)
    shot("orderly-reach-end.png", "mixamo_reach", 34, True)
    shot("orderly-duck.png", "duck", 25, True)
    set_action(arm, None)
    reset_pose(arm)
    bpy.data.objects.remove(cam, do_unlink=True)


# --- main ------------------------------------------------------------------------------------------------
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(ROOT, "assets_src", "meshy", "orderly", "orderly_meshy_rigged.glb"))
    ap.add_argument("--old", default=os.path.join(ROOT, "godot", "assets", "entities", "orderly.glb"))
    ap.add_argument("--out", default=os.path.join(ROOT, "godot", "assets", "entities", "orderly_v2.glb"))
    ap.add_argument("--mixamo-dir", default="")
    ap.add_argument("--render", default="")
    args = ap.parse_args(argv)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.fps = FPS

    # Today's model: the measure and the source of the hand-made clips.
    old_arm, old_mesh = import_glb(args.old)
    old = Rig(old_arm, mesh=old_mesh)
    set_action(old_arm, bpy.data.actions["mixamo_idle"])
    scn.frame_set(0)
    old_idle_top, old_idle_low = mesh_top(old_mesh)
    set_action(old_arm, None)
    reset_pose(old_arm)
    bpy.context.view_layer.update()
    old_rest_top, old_rest_low = mesh_top(old_mesh)
    old.rest_low = old_rest_low
    old_ankle_y = 0.5 * (old.head("foot.L").y + old.head("foot.R").y)
    log(f"today's model: rest top {old_rest_top:.3f} low {old_rest_low:.4f}; idle top {old_idle_top:.3f} "
        f"low {old_idle_low:.4f}; ankle y {old_ankle_y:.3f}")
    old_mesh.hide_render = True

    arm, mesh = import_glb(args.src)
    mesh_mat, img = texture(mesh)
    prepare(arm, mesh)
    top, _ = mesh_top(mesh)
    place(arm, mesh, old_rest_top / top, old_ankle_y)
    arm_share = sum((old.head("forearm" + s) - old.head("upperarm" + s)).length +
                    (old.head("hand" + s) - old.head("forearm" + s)).length for s in (".L", ".R")) / 2 / old_rest_top
    stretch = lengthen_arms(arm, mesh, arm_share, mesh_top(mesh)[0])
    place(arm, mesh, 1.0, old_ankle_y)

    # A first size from today's idle pose alone (the pose rules start from).
    for attempt in range(3):
        target = Rig(arm, mesh=mesh)
        bk = Baker(target, old)
        al = alignment(target, old)
        (motion, hips, low), = read_old(old, "mixamo_idle", 1)
        bk.plant(transfer(target, al, motion), (hips - old.head("hips")) * bk.hip_ratio, low - old.rest_low)
        bpy.context.view_layer.update()
        idle_top, idle_low = mesh_top(mesh)
        reset_pose(arm)
        k = old_idle_top / idle_top
        log(f"idle top {idle_top:.4f} (today's {old_idle_top:.4f}) -> scale {k:.4f}")
        if abs(k - 1.0) < 0.001:
            break
        place(arm, mesh, k, old_ankle_y)

    add_skirt(arm, mesh, img)
    if img.size[0] > TEX:
        img.scale(TEX, TEX)
    # Then the size that makes the idle the view plays exactly as tall as today's (the walk is printed to check
    # it: test_orderly_v2 holds both within 2 cm of today's as drawn in the game).
    set_action(old_arm, bpy.data.actions["mixamo_walk"])
    scn.frame_set(0)
    old_walk_top = mesh_top(old_mesh)[0]
    set_action(old_arm, None)
    for attempt in range(3):
        target = Rig(arm, mesh=mesh)
        bake_all(target, old, args.mixamo_dir)
        tops = []
        for clip in ("mixamo_idle#v2", "mixamo_walk#v2"):
            set_action(arm, bpy.data.actions[clip])
            scn.frame_set(1)
            tops.append(mesh_top(mesh)[0])
        set_action(arm, None)
        reset_pose(arm)
        k = old_idle_top / tops[0]
        log(f"baked: idle top {tops[0]:.4f} (today's {old_idle_top:.4f}), walk top {tops[1]:.4f} "
            f"(today's {old_walk_top:.4f}) -> scale {k:.4f}")
        if abs(k - 1.0) < 0.0008:
            break
        for a in [a for a in bpy.data.actions if a.name.endswith("#v2")]:
            bpy.data.actions.remove(a)
        for tr in list(arm.animation_data.nla_tracks):
            arm.animation_data.nla_tracks.remove(tr)
        place(arm, mesh, k, old_ankle_y)
    check_clips(target, old)

    # Only the new figure and its clips are exported.
    for o in (old_arm, old_mesh):
        bpy.data.objects.remove(o, do_unlink=True)
    ours = {"idle", "walk", "reach", "duck", "still", "mixamo_idle", "mixamo_walk", "mixamo_reach",
            "mixamo_roar", "bellydance"}
    for a in list(bpy.data.actions):
        if not a.name.endswith("#v2") or a.name[:-3] not in ours:
            bpy.data.actions.remove(a)
    for a in list(bpy.data.actions):
        a.name = a.name[:-3]
    assert {a.name for a in bpy.data.actions} == ours, [a.name for a in bpy.data.actions]
    for o in list(bpy.data.objects):
        if o not in (arm, mesh):
            bpy.data.objects.remove(o, do_unlink=True)
    for ob, name in ((arm, "Orderly_Rig"), (mesh, "Orderly")):  # today's objects held these names until now
        ob.name = ob.data.name = name
    reset_pose(arm)
    bpy.context.view_layer.update()
    top, low = mesh_top(mesh)
    tris = sum(len(p.vertices) - 2 for p in mesh.data.polygons)
    log(f"verts={len(mesh.data.vertices)} tris={tris} bones={len(arm.data.bones)} rest top {top:.3f} low {low:.4f} "
        f"arm stretch {stretch:.3f} texture {tuple(img.size)}")
    scn.frame_start, scn.frame_end = 1, 97
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.abspath(args.out), export_format="GLB", export_animations=True,
                              export_animation_mode="ACTIONS", export_skins=True, export_yup=True,
                              export_apply=False, export_force_sampling=True, export_anim_slide_to_zero=True,
                              export_image_format="WEBP")  # Godot 4.7 failed to read the JPEG Blender wrote
    log("exported", args.out, os.path.getsize(args.out), "bytes")
    if args.render:
        render(arm, mesh, args.render)


if __name__ == "__main__":
    main()
